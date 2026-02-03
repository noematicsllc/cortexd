use clap::{Parser, Subcommand};
use rmpv::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::sync::atomic::{AtomicU32, Ordering};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_SOCKET: &str = "/run/cortex/cortex.sock";

static MSG_ID: AtomicU32 = AtomicU32::new(1);

#[derive(Parser)]
#[command(name = "cortex")]
#[command(about = "CLI for Cortex local storage daemon")]
#[command(version = VERSION)]
#[command(disable_help_subcommand = true)]
#[command(after_help = "Run 'cortex help <command>' for more information on a command.")]
struct Cli {
    /// Pretty-print JSON output
    #[arg(long, global = true)]
    pretty: bool,

    /// Socket path
    #[arg(long, global = true, default_value = DEFAULT_SOCKET)]
    socket: String,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Health check
    Ping,

    /// Daemon status
    Status,

    /// List your tables
    Tables,

    /// Create a new table
    #[command(visible_alias = "create_table")]
    CreateTable {
        /// Table name
        name: String,
        /// Comma-separated attributes (first is primary key)
        attrs: String,
    },

    /// Drop a table
    #[command(visible_alias = "drop_table")]
    DropTable {
        /// Table name
        name: String,
    },

    /// Get a record by key
    Get {
        /// Table name
        table: String,
        /// Primary key
        key: String,
    },

    /// Insert or update a record
    Put {
        /// Table name
        table: String,
        /// Record as JSON
        json: String,
    },

    /// Delete a record
    Delete {
        /// Table name
        table: String,
        /// Primary key
        key: String,
    },

    /// Query records by pattern
    Query {
        /// Table name
        table: String,
        /// Pattern as JSON
        pattern: String,
    },

    /// List all records in a table
    All {
        /// Table name
        table: String,
    },

    /// List all keys in a table
    Keys {
        /// Table name
        table: String,
    },

    /// Access control commands
    Acl {
        #[command(subcommand)]
        command: AclCommands,
    },

    /// Show help for a topic (e.g., cortex help memories)
    #[command(name = "help")]
    HelpTopic {
        /// Topic (command name or pattern)
        topic: Option<String>,
    },
}

#[derive(Subcommand)]
enum AclCommands {
    /// Grant permissions
    Grant {
        /// Identity (uid:NUMBER or * for world)
        identity: String,
        /// Table name
        table: String,
        /// Permissions (comma-separated: read,write,admin)
        perms: String,
    },

    /// Revoke permissions
    Revoke {
        /// Identity
        identity: String,
        /// Table name
        table: String,
        /// Permissions to revoke
        perms: String,
    },

    /// List ACLs for your tables
    List,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    let result = match &cli.command {
        None => {
            print_help();
            Ok(None)
        }
        Some(Commands::Ping) => call(&cli.socket, "ping", vec![]),
        Some(Commands::Status) => call(&cli.socket, "status", vec![]),
        Some(Commands::Tables) => call(&cli.socket, "tables", vec![]),
        Some(Commands::CreateTable { name, attrs }) => {
            let attributes: Vec<Value> = attrs
                .split(',')
                .map(|s| Value::String(s.trim().into()))
                .collect();
            call(
                &cli.socket,
                "create_table",
                vec![Value::String(name.clone().into()), Value::Array(attributes)],
            )
        }
        Some(Commands::DropTable { name }) => call(
            &cli.socket,
            "drop_table",
            vec![Value::String(name.clone().into())],
        ),
        Some(Commands::Get { table, key }) => call(
            &cli.socket,
            "get",
            vec![
                Value::String(table.clone().into()),
                Value::String(key.clone().into()),
            ],
        ),
        Some(Commands::Put { table, json }) => {
            let record: serde_json::Value = match serde_json::from_str(json) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("error: invalid JSON: {}", e);
                    return ExitCode::FAILURE;
                }
            };
            let record_msgpack = json_to_msgpack(&record);
            call(
                &cli.socket,
                "put",
                vec![Value::String(table.clone().into()), record_msgpack],
            )
        }
        Some(Commands::Delete { table, key }) => call(
            &cli.socket,
            "delete",
            vec![
                Value::String(table.clone().into()),
                Value::String(key.clone().into()),
            ],
        ),
        Some(Commands::Query { table, pattern }) => {
            let pat: serde_json::Value = match serde_json::from_str(pattern) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("error: invalid JSON pattern: {}", e);
                    return ExitCode::FAILURE;
                }
            };
            let pat_msgpack = json_to_msgpack(&pat);
            call(
                &cli.socket,
                "match",
                vec![Value::String(table.clone().into()), pat_msgpack],
            )
        }
        Some(Commands::All { table }) => call(
            &cli.socket,
            "all",
            vec![Value::String(table.clone().into())],
        ),
        Some(Commands::Keys { table }) => call(
            &cli.socket,
            "keys",
            vec![Value::String(table.clone().into())],
        ),
        Some(Commands::Acl { command }) => match command {
            AclCommands::Grant {
                identity,
                table,
                perms,
            } => call(
                &cli.socket,
                "acl_grant",
                vec![
                    Value::String(identity.clone().into()),
                    Value::String(table.clone().into()),
                    Value::String(perms.clone().into()),
                ],
            ),
            AclCommands::Revoke {
                identity,
                table,
                perms,
            } => call(
                &cli.socket,
                "acl_revoke",
                vec![
                    Value::String(identity.clone().into()),
                    Value::String(table.clone().into()),
                    Value::String(perms.clone().into()),
                ],
            ),
            AclCommands::List => call(&cli.socket, "acl_list", vec![]),
        },
        Some(Commands::HelpTopic { topic }) => {
            print_topic_help(topic.as_deref());
            Ok(None)
        }
    };

    match result {
        Ok(Some(value)) => {
            let json = msgpack_to_json(&value);
            if cli.pretty {
                println!("{}", serde_json::to_string_pretty(&json).unwrap());
            } else {
                println!("{}", serde_json::to_string(&json).unwrap());
            }
            ExitCode::SUCCESS
        }
        Ok(None) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {}", e);
            ExitCode::FAILURE
        }
    }
}

fn call(socket_path: &str, method: &str, params: Vec<Value>) -> Result<Option<Value>, String> {
    let mut stream = UnixStream::connect(socket_path)
        .map_err(|e| format!("cannot connect to {}: {}", socket_path, e))?;

    let msgid = MSG_ID.fetch_add(1, Ordering::SeqCst);
    let request = Value::Array(vec![
        Value::Integer(0.into()),
        Value::Integer(msgid.into()),
        Value::String(method.into()),
        Value::Array(params),
    ]);

    let mut buf = Vec::new();
    rmpv::encode::write_value(&mut buf, &request).map_err(|e| format!("encode error: {}", e))?;

    stream
        .write_all(&buf)
        .map_err(|e| format!("write error: {}", e))?;

    let mut response_buf = vec![0u8; 65536];
    let n = stream
        .read(&mut response_buf)
        .map_err(|e| format!("read error: {}", e))?;

    let response = rmpv::decode::read_value(&mut &response_buf[..n])
        .map_err(|e| format!("decode error: {}", e))?;

    match response {
        Value::Array(parts) if parts.len() == 4 => {
            let error = &parts[2];
            let result = &parts[3];

            if *error != Value::Nil {
                let err_str = match error {
                    Value::String(s) => s.as_str().unwrap_or("unknown error").to_string(),
                    _ => format!("{}", error),
                };
                Err(err_str)
            } else {
                Ok(Some(result.clone()))
            }
        }
        _ => Err("invalid response format".to_string()),
    }
}

fn json_to_msgpack(value: &serde_json::Value) -> Value {
    match value {
        serde_json::Value::Null => Value::Nil,
        serde_json::Value::Bool(b) => Value::Boolean(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Integer(i.into())
            } else if let Some(f) = n.as_f64() {
                Value::F64(f)
            } else {
                Value::Nil
            }
        }
        serde_json::Value::String(s) => Value::String(s.clone().into()),
        serde_json::Value::Array(arr) => Value::Array(arr.iter().map(json_to_msgpack).collect()),
        serde_json::Value::Object(obj) => Value::Map(
            obj.iter()
                .map(|(k, v)| (Value::String(k.clone().into()), json_to_msgpack(v)))
                .collect(),
        ),
    }
}

fn msgpack_to_json(value: &Value) -> serde_json::Value {
    match value {
        Value::Nil => serde_json::Value::Null,
        Value::Boolean(b) => serde_json::Value::Bool(*b),
        Value::Integer(i) => {
            if let Some(n) = i.as_i64() {
                serde_json::Value::Number(n.into())
            } else if let Some(n) = i.as_u64() {
                serde_json::Value::Number(n.into())
            } else {
                serde_json::Value::Null
            }
        }
        Value::F32(f) => serde_json::Value::Number(
            serde_json::Number::from_f64(*f as f64).unwrap_or(serde_json::Number::from(0)),
        ),
        Value::F64(f) => serde_json::Value::Number(
            serde_json::Number::from_f64(*f).unwrap_or(serde_json::Number::from(0)),
        ),
        Value::String(s) => serde_json::Value::String(s.as_str().unwrap_or_default().to_string()),
        Value::Binary(b) => serde_json::Value::String(String::from_utf8_lossy(b).to_string()),
        Value::Array(arr) => serde_json::Value::Array(arr.iter().map(msgpack_to_json).collect()),
        Value::Map(map) => {
            let obj: serde_json::Map<String, serde_json::Value> = map
                .iter()
                .filter_map(|(k, v)| {
                    let key = match k {
                        Value::String(s) => s.as_str().map(|s| s.to_string()),
                        _ => Some(format!("{}", k)),
                    };
                    key.map(|k| (k, msgpack_to_json(v)))
                })
                .collect();
            serde_json::Value::Object(obj)
        }
        Value::Ext(_, _) => serde_json::Value::Null,
    }
}

fn print_help() {
    println!(
        r#"cortex - Local storage daemon CLI

USAGE:
  cortex <command> [args] [--pretty]

COMMANDS:
  ping                          Health check
  status                        Daemon status
  tables                        List your tables

  create-table NAME ATTRS       Create table (ATTRS: comma-separated, first is key)
  drop-table NAME               Drop a table
  get TABLE KEY                 Get record by key
  put TABLE JSON                Insert/update record
  delete TABLE KEY              Delete record
  query TABLE PATTERN           Query by pattern (JSON)
  all TABLE                     List all records
  keys TABLE                    List all keys in a table

  acl grant IDENTITY TABLE PERMS    Grant permissions
  acl revoke IDENTITY TABLE PERMS   Revoke permissions
  acl list                          List ACLs for your tables

OPTIONS:
  --pretty                      Pretty-print JSON output
  --socket PATH                 Socket path (default: /run/cortex/cortex.sock)
  --version                     Show version
  --help                        Show this help

EXAMPLES:
  cortex create-table users id,name,email
  cortex put users '{{"id":"u1","name":"alice","email":"a@b.com"}}'
  cortex get users u1
  cortex query users '{{"name":"alice"}}'
  cortex acl grant 'uid:1001' users read
  cortex acl grant '*' users read"#
    );
}

fn print_topic_help(topic: Option<&str>) {
    match topic {
        None | Some("") => print_help(),
        Some("ping") => println!(
            r#"cortex ping - Health check

USAGE:
  cortex ping

DESCRIPTION:
  Tests connectivity to the Cortex daemon. Returns "pong" if the daemon
  is running and responsive.

EXAMPLES:
  cortex ping
  # Output: "pong""#
        ),
        Some("status") => println!(
            r#"cortex status - Daemon status

USAGE:
  cortex status [--pretty]

DESCRIPTION:
  Returns detailed status information about the Cortex daemon including
  version, uptime, and Mnesia database state.

OPTIONS:
  --pretty    Pretty-print the JSON output

EXAMPLES:
  cortex status
  cortex status --pretty"#
        ),
        Some("tables") => println!(
            r#"cortex tables - List your tables

USAGE:
  cortex tables [--pretty]

DESCRIPTION:
  Lists all tables owned by the current user (based on UID). Tables are
  automatically namespaced by your UID internally.

EXAMPLES:
  cortex tables
  cortex tables --pretty"#
        ),
        Some("create-table") => println!(
            r#"cortex create-table - Create a new table

USAGE:
  cortex create-table NAME ATTRS

ARGUMENTS:
  NAME    Table name (will be namespaced to your UID automatically)
  ATTRS   Comma-separated attribute names; first attribute is the primary key

DESCRIPTION:
  Creates a new Mnesia table owned by you. The first attribute becomes
  the primary key for get/delete operations.

EXAMPLES:
  cortex create-table users id,name,email
  cortex create-table sessions session_id,user_id,expires"#
        ),
        Some("drop-table") => println!(
            r#"cortex drop-table - Drop a table

USAGE:
  cortex drop-table NAME

DESCRIPTION:
  Permanently deletes a table and all its data.
  WARNING: This operation cannot be undone.

EXAMPLES:
  cortex drop-table old_sessions"#
        ),
        Some("get") => println!(
            r#"cortex get - Get a record by key

USAGE:
  cortex get TABLE KEY [--pretty]

DESCRIPTION:
  Retrieves a single record by its primary key.

EXAMPLES:
  cortex get users u1
  cortex get config database_url --pretty"#
        ),
        Some("put") => println!(
            r#"cortex put - Insert or update a record

USAGE:
  cortex put TABLE JSON

DESCRIPTION:
  Inserts a new record or updates an existing one. The JSON must contain
  the primary key field defined when the table was created.

EXAMPLES:
  cortex put users '{{"id":"u1","name":"alice","email":"a@b.com"}}'
  cortex put config '{{"key":"theme","value":"dark"}}'"#
        ),
        Some("delete") => println!(
            r#"cortex delete - Delete a record

USAGE:
  cortex delete TABLE KEY

DESCRIPTION:
  Permanently deletes a single record by its primary key.

EXAMPLES:
  cortex delete users u1
  cortex delete sessions expired_session_123"#
        ),
        Some("query") => println!(
            r#"cortex query - Query records by pattern

USAGE:
  cortex query TABLE PATTERN [--pretty]

DESCRIPTION:
  Finds all records matching the given pattern. The pattern is a JSON
  object where each field must match exactly.

EXAMPLES:
  cortex query users '{{"name":"alice"}}' --pretty
  cortex query sessions '{{"user_id":"u1"}}'"#
        ),
        Some("all") => println!(
            r#"cortex all - List all records in a table

USAGE:
  cortex all TABLE [--pretty]

DESCRIPTION:
  Returns all records in a table as a JSON array.

EXAMPLES:
  cortex all users --pretty
  cortex all config"#
        ),
        Some("keys") => println!(
            r#"cortex keys - List all keys in a table

USAGE:
  cortex keys TABLE [--pretty]

DESCRIPTION:
  Returns all primary keys in a table as a JSON array. Useful for
  debugging or iterating over records without fetching full data.

EXAMPLES:
  cortex keys users
  cortex keys sessions --pretty"#
        ),
        Some("acl") => println!(
            r#"cortex acl - Access control commands

USAGE:
  cortex acl <subcommand> [args]

SUBCOMMANDS:
  grant IDENTITY TABLE PERMS    Grant permissions
  revoke IDENTITY TABLE PERMS   Revoke permissions
  list                          List ACLs for your tables

IDENTITIES:
  uid:1001    Specific user by UID
  *           World (any authenticated user)

PERMISSIONS:
  read        Can get, query, all
  write       Can put, delete
  admin       Can grant/revoke ACLs, drop table

EXAMPLES:
  cortex acl grant 'uid:1001' users read
  cortex acl grant '*' public_data read
  cortex acl revoke 'uid:1001' users write
  cortex acl list --pretty"#
        ),
        Some("patterns") => println!(
            r#"Cortex Usage Patterns

Cortex is a generic storage layer - it has no opinions about how you
structure your data. Here are common patterns that work well:

AVAILABLE PATTERNS:
  cortex help memories       Public/private agent memories
  cortex help statemachine   Workflow state machines
  cortex help identities     Agent identity via Unix users

Run 'cortex help <pattern>' for detailed documentation."#
        ),
        Some("memories") => println!(
            r#"Pattern: Public/Private Agent Memories

OVERVIEW:
  AI agents often need both private working memory and shared knowledge.
  Use separate tables with different ACLs to implement this pattern.

SETUP:
  # Create private memory (only you can access)
  cortex create-table private_memories id,content,timestamp,tags

  # Create public memory (world-readable)
  cortex create-table public_memories id,content,timestamp,tags
  cortex acl grant '*' public_memories read

MULTI-AGENT SETUP:
  Each agent runs as a separate Unix user with its own UID:

  sudo useradd -r -s /usr/sbin/nologin agent-researcher
  sudo useradd -r -s /usr/sbin/nologin agent-coder

  Each agent's tables are isolated. They can only read each other's
  public_memories tables (if world-readable ACL is set)."#
        ),
        Some("statemachine") => println!(
            r#"Pattern: Workflow State Machines

OVERVIEW:
  Track multi-step workflows with explicit states and transitions.

SETUP:
  cortex create-table sm_definitions id,name,states,transitions
  cortex create-table sm_instances id,definition,state,data,created,updated

DEFINE A WORKFLOW:
  cortex put sm_definitions '{{
    "id": "task-workflow",
    "name": "Task Workflow",
    "states": ["todo", "in_progress", "review", "done"]
  }}'

QUERY BY STATE:
  cortex query sm_instances '{{"state":"review"}}' --pretty"#
        ),
        Some("identities") => println!(
            r#"Pattern: Agent Identities

OVERVIEW:
  Cortex identifies users by their Unix UID, extracted from the socket
  connection via SO_PEERCRED. This provides kernel-enforced identity.

HOW IT WORKS:
  1. Client connects to Unix socket
  2. Cortex extracts UID via getpeereid/SO_PEERCRED (kernel-enforced)
  3. All operations are scoped to that UID
  4. Tables are namespaced: "users" becomes "1000:users" internally

CREATING AGENT USERS:
  sudo useradd -r -s /usr/sbin/nologin agent-coder
  sudo -u agent-coder cortex put memories '{{...}}'

FINDING YOUR UID:
  id -u                    # Your current UID
  id -u agent-coder        # Another user's UID"#
        ),
        Some(other) => {
            eprintln!("Unknown help topic: {}", other);
            eprintln!();
            eprintln!("Available commands:");
            eprintln!("  ping, status, tables, create-table, drop-table,");
            eprintln!("  get, put, delete, query, all, keys, acl");
            eprintln!();
            eprintln!("Available patterns:");
            eprintln!("  patterns, memories, statemachine, identities");
        }
    }
}
