use clap::{Parser, Subcommand};
use rmpv::Value;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, ExitCode};
use std::sync::atomic::{AtomicU32, Ordering};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_SOCKET: &str = "/run/cortex/cortex.sock";

static MSG_ID: AtomicU32 = AtomicU32::new(1);

#[derive(Parser)]
#[command(name = "cortex")]
#[command(about = "CLI for Cortex storage daemon")]
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

    /// Mesh networking commands
    Mesh {
        #[command(subcommand)]
        command: MeshCommands,
    },

    /// Federated identity commands
    Identity {
        #[command(subcommand)]
        command: IdentityCommands,
    },

    /// Get or set table node scope
    Scope {
        /// Table name
        table: String,
        /// New scope (local, all, or comma-separated node names). Omit to read current scope.
        scope: Option<String>,
    },

    /// Show table metadata
    Info {
        /// Table name
        table: String,
    },

    /// Data sync commands
    Sync {
        #[command(subcommand)]
        command: SyncCommands,
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

#[derive(Subcommand)]
enum MeshCommands {
    /// Initialize a new mesh Certificate Authority
    InitCa {
        /// Directory for CA files (default: ~/.cortex/mesh)
        #[arg(long)]
        dir: Option<String>,

        /// Overwrite existing CA
        #[arg(long)]
        force: bool,
    },

    /// Add a node to the mesh (generate node certificate)
    AddNode {
        /// Node name (alphanumeric, hyphens, underscores)
        name: String,
        /// Node host (IP address or hostname)
        host: String,

        /// CA directory (default: ~/.cortex/mesh)
        #[arg(long)]
        dir: Option<String>,
    },

    /// List configured mesh nodes
    ListNodes,

    /// Show mesh connectivity status
    Status,
}

#[derive(Subcommand)]
enum IdentityCommands {
    /// Register a new federated identity
    Register {
        /// Identity name
        name: String,
    },

    /// Claim a federated identity using a token
    Claim {
        /// Claim token from the registering node
        token: String,
    },

    /// List all federated identities
    List,

    /// Revoke a federated identity
    Revoke {
        /// Identity name
        name: String,
        /// Specific node to revoke from (optional — revokes entirely if omitted)
        node: Option<String>,
    },
}

#[derive(Subcommand)]
enum SyncCommands {
    /// Show replication status
    Status {
        /// Specific table (omit for overview)
        table: Option<String>,
    },

    /// Repair table replication
    Repair {
        /// Table to repair
        table: String,
    },
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
        Some(Commands::Mesh { command }) => match command {
            MeshCommands::InitCa { dir, force } => {
                return mesh_init_ca(dir.as_deref(), *force);
            }
            MeshCommands::AddNode { name, host, dir } => {
                return mesh_add_node(name, host, dir.as_deref());
            }
            MeshCommands::ListNodes => call(&cli.socket, "mesh_list_nodes", vec![]),
            MeshCommands::Status => call(&cli.socket, "mesh_status", vec![]),
        },
        Some(Commands::Identity { command }) => match command {
            IdentityCommands::Register { name } => call(
                &cli.socket,
                "identity_register",
                vec![Value::String(name.clone().into())],
            ),
            IdentityCommands::Claim { token } => call(
                &cli.socket,
                "identity_claim",
                vec![Value::String(token.clone().into())],
            ),
            IdentityCommands::List => call(&cli.socket, "identity_list", vec![]),
            IdentityCommands::Revoke { name, node } => {
                let mut params = vec![Value::String(name.clone().into())];
                if let Some(n) = node {
                    params.push(Value::String(n.clone().into()));
                }
                call(&cli.socket, "identity_revoke", params)
            }
        },
        Some(Commands::Scope { table, scope }) => match scope {
            None => call(
                &cli.socket,
                "get_scope",
                vec![Value::String(table.clone().into())],
            ),
            Some(s) => call(
                &cli.socket,
                "set_scope",
                vec![
                    Value::String(table.clone().into()),
                    Value::String(s.clone().into()),
                ],
            ),
        },
        Some(Commands::Info { table }) => call(
            &cli.socket,
            "table_info",
            vec![Value::String(table.clone().into())],
        ),
        Some(Commands::Sync { command }) => match command {
            SyncCommands::Status { table } => match table {
                None => call(&cli.socket, "sync_status", vec![]),
                Some(t) => call(
                    &cli.socket,
                    "sync_status_table",
                    vec![Value::String(t.clone().into())],
                ),
            },
            SyncCommands::Repair { table } => call(
                &cli.socket,
                "sync_repair",
                vec![Value::String(table.clone().into())],
            ),
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

// --- Mesh certificate generation (local, no daemon needed) ---

fn default_mesh_dir() -> String {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".to_string());
    format!("{}/.cortex/mesh", home)
}

fn run_openssl(args: &[&str]) -> Result<(), String> {
    let output = Command::new("openssl").args(args).output().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "openssl is required for certificate generation".to_string()
        } else {
            format!("failed to run openssl: {}", e)
        }
    })?;

    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        Err(format!("openssl failed: {}", stderr.trim()))
    }
}

fn mesh_init_ca(dir: Option<&str>, force: bool) -> ExitCode {
    let mesh_dir = dir.map(String::from).unwrap_or_else(default_mesh_dir);
    let ca_key = format!("{}/ca.key", mesh_dir);
    let ca_cert = format!("{}/ca.crt", mesh_dir);

    if std::path::Path::new(&ca_key).exists() && !force {
        eprintln!(
            "error: CA already exists at {}. Use --force to overwrite.",
            mesh_dir
        );
        return ExitCode::FAILURE;
    }

    if let Err(e) = fs::create_dir_all(&mesh_dir) {
        eprintln!("error: cannot create directory {}: {}", mesh_dir, e);
        return ExitCode::FAILURE;
    }

    if let Err(e) = run_openssl(&["genrsa", "-out", &ca_key, "4096"]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    // Set key permissions to 0600
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&ca_key, fs::Permissions::from_mode(0o600));
    }

    if let Err(e) = run_openssl(&[
        "req",
        "-new",
        "-x509",
        "-key",
        &ca_key,
        "-out",
        &ca_cert,
        "-days",
        "3650",
        "-subj",
        "/CN=Cortex Mesh CA",
    ]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    println!("CA created at {}", mesh_dir);
    println!("  Key:  {}", ca_key);
    println!("  Cert: {}", ca_cert);
    ExitCode::SUCCESS
}

fn mesh_add_node(name: &str, host: &str, dir: Option<&str>) -> ExitCode {
    // Validate node name
    if !name
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        || name.is_empty()
    {
        eprintln!("error: invalid node name: must be alphanumeric with hyphens/underscores");
        return ExitCode::FAILURE;
    }

    let mesh_dir = dir.map(String::from).unwrap_or_else(default_mesh_dir);
    let ca_key = format!("{}/ca.key", mesh_dir);
    let ca_cert = format!("{}/ca.crt", mesh_dir);
    let nodes_dir = format!("{}/nodes", mesh_dir);

    if !std::path::Path::new(&ca_key).exists() {
        eprintln!(
            "error: CA not found at {}. Run 'cortex mesh init-ca' first.",
            mesh_dir
        );
        return ExitCode::FAILURE;
    }

    if let Err(e) = fs::create_dir_all(&nodes_dir) {
        eprintln!("error: cannot create directory {}: {}", nodes_dir, e);
        return ExitCode::FAILURE;
    }

    let node_key = format!("{}/{}.key", nodes_dir, name);
    let node_csr = format!("{}/{}.csr", nodes_dir, name);
    let node_cert = format!("{}/{}.crt", nodes_dir, name);
    let ext_file = format!("{}/{}.ext", nodes_dir, name);

    // Build SAN entries
    let san = if host.parse::<std::net::IpAddr>().is_ok() {
        format!("DNS:{},IP:{}", name, host)
    } else {
        format!("DNS:{},DNS:{}", name, host)
    };

    let ext_content = format!(
        "subjectAltName={}\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n",
        san
    );

    // Generate node key
    if let Err(e) = run_openssl(&["genrsa", "-out", &node_key, "2048"]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&node_key, fs::Permissions::from_mode(0o600));
    }

    // Generate CSR
    if let Err(e) = run_openssl(&[
        "req",
        "-new",
        "-key",
        &node_key,
        "-out",
        &node_csr,
        "-subj",
        &format!("/CN={}", name),
    ]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    // Write extension file
    if let Err(e) = fs::write(&ext_file, &ext_content) {
        eprintln!("error: cannot write extension file: {}", e);
        return ExitCode::FAILURE;
    }

    // Sign with CA
    if let Err(e) = run_openssl(&[
        "x509",
        "-req",
        "-in",
        &node_csr,
        "-CA",
        &ca_cert,
        "-CAkey",
        &ca_key,
        "-CAcreateserial",
        "-out",
        &node_cert,
        "-days",
        "365",
        "-extfile",
        &ext_file,
    ]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    // Clean up temp files
    let _ = fs::remove_file(&node_csr);
    let _ = fs::remove_file(&ext_file);

    println!("Node '{}' added", name);
    println!("  Key:  {}", node_key);
    println!("  Cert: {}", node_cert);
    ExitCode::SUCCESS
}

// --- RPC communication ---

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

// --- Value conversion ---

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

// --- Help text ---

fn print_help() {
    println!(
        r#"cortex - Storage daemon CLI

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

  mesh init-ca                  Initialize mesh Certificate Authority
  mesh add-node NAME HOST       Generate node certificate
  mesh list-nodes               List configured mesh nodes
  mesh status                   Show mesh connectivity

  identity register NAME        Register a federated identity
  identity claim TOKEN          Claim identity on this node
  identity list                 List federated identities
  identity revoke NAME [NODE]   Revoke a federated identity

  scope TABLE [SCOPE]           Get or set table node scope
  info TABLE                    Show table metadata
  sync status [TABLE]           Show replication status
  sync repair TABLE             Repair table replication

OPTIONS:
  --pretty                      Pretty-print JSON output
  --socket PATH                 Socket path (default: /run/cortex/cortex.sock)
  --version                     Show version
  --help                        Show this help

EXAMPLES:
  cortex create-table users id,name,email
  cortex put users '{{"id":"u1","name":"alice","email":"a@b.com"}}'
  cortex get users u1
  cortex mesh init-ca
  cortex mesh add-node my-node 192.168.1.10
  cortex identity register alice"#
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

EXAMPLES:
  cortex status
  cortex status --pretty"#
        ),
        Some("tables") => println!(
            r#"cortex tables - List your tables

USAGE:
  cortex tables [--pretty]

DESCRIPTION:
  Lists all tables owned by the current user (based on UID).

EXAMPLES:
  cortex tables
  cortex tables --pretty"#
        ),
        Some("create-table") => println!(
            r#"cortex create-table - Create a new table

USAGE:
  cortex create-table NAME ATTRS

ARGUMENTS:
  NAME    Table name (namespaced to your UID automatically)
  ATTRS   Comma-separated attribute names; first is the primary key

EXAMPLES:
  cortex create-table users id,name,email
  cortex create-table sessions session_id,user_id,expires"#
        ),
        Some("drop-table") => println!(
            r#"cortex drop-table - Drop a table

USAGE:
  cortex drop-table NAME

WARNING: This operation cannot be undone.

EXAMPLES:
  cortex drop-table old_sessions"#
        ),
        Some("get") => println!(
            r#"cortex get - Get a record by key

USAGE:
  cortex get TABLE KEY [--pretty]

EXAMPLES:
  cortex get users u1
  cortex get config database_url --pretty"#
        ),
        Some("put") => println!(
            r#"cortex put - Insert or update a record

USAGE:
  cortex put TABLE JSON

EXAMPLES:
  cortex put users '{{"id":"u1","name":"alice","email":"a@b.com"}}'
  cortex put config '{{"key":"theme","value":"dark"}}'"#
        ),
        Some("delete") => println!(
            r#"cortex delete - Delete a record

USAGE:
  cortex delete TABLE KEY

EXAMPLES:
  cortex delete users u1"#
        ),
        Some("query") => println!(
            r#"cortex query - Query records by pattern

USAGE:
  cortex query TABLE PATTERN [--pretty]

DESCRIPTION:
  Finds all records matching the given JSON pattern.

EXAMPLES:
  cortex query users '{{"name":"alice"}}' --pretty"#
        ),
        Some("all") => println!(
            r#"cortex all - List all records in a table

USAGE:
  cortex all TABLE [--pretty]

EXAMPLES:
  cortex all users --pretty"#
        ),
        Some("keys") => println!(
            r#"cortex keys - List all keys in a table

USAGE:
  cortex keys TABLE [--pretty]

EXAMPLES:
  cortex keys users"#
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
  cortex acl list --pretty"#
        ),
        Some("mesh") => println!(
            r#"cortex mesh - Mesh networking commands

USAGE:
  cortex mesh <subcommand> [args]

SUBCOMMANDS:
  init-ca                       Initialize mesh Certificate Authority
  add-node NAME HOST            Generate certificate for a node
  list-nodes                    List configured mesh nodes
  status                        Show mesh connectivity status

QUICK START:
  1. cortex mesh init-ca
  2. cortex mesh add-node my-node 192.168.1.10
  3. Copy certs to node, configure mesh in config.exs
  4. cortex mesh status

OPTIONS:
  --dir PATH    CA directory (default: ~/.cortex/mesh)
  --force       Overwrite existing CA (init-ca only)

EXAMPLES:
  cortex mesh init-ca
  cortex mesh init-ca --dir /etc/cortex/mesh
  cortex mesh add-node node-a 10.0.0.1
  cortex mesh list-nodes --pretty
  cortex mesh status --pretty"#
        ),
        Some("identity") => println!(
            r#"cortex identity - Federated identity commands

USAGE:
  cortex identity <subcommand> [args]

SUBCOMMANDS:
  register NAME         Register a new federated identity
  claim TOKEN           Claim an identity on this node using a token
  list                  List all federated identities
  revoke NAME [NODE]    Revoke an identity (optionally from specific node)

DESCRIPTION:
  Federated identities link a user across multiple mesh nodes. Register
  on your primary node, then claim on other nodes using the token.

  Tables prefixed with @ use federated identity namespacing:
    cortex create-table @memories id,content
    → creates @alice:memories (if your federated identity is "alice")

EXAMPLES:
  cortex identity register alice
  cortex identity claim <token-from-register>
  cortex identity list --pretty
  cortex identity revoke alice"#
        ),
        Some("scope") => println!(
            r#"cortex scope - Get or set table node scope

USAGE:
  cortex scope TABLE              Get current scope
  cortex scope TABLE SCOPE        Set scope

SCOPE VALUES:
  local                   Only accessible on this node (default)
  all                     Accessible from all mesh nodes
  node-a,node-b           Accessible from listed nodes only

EXAMPLES:
  cortex scope users
  cortex scope users all
  cortex scope users node-a,node-b"#
        ),
        Some("info") => println!(
            r#"cortex info - Show table metadata

USAGE:
  cortex info TABLE [--pretty]

DESCRIPTION:
  Displays table owner, attributes, key field, node scope, and ACLs.

EXAMPLES:
  cortex info users --pretty"#
        ),
        Some("sync") => println!(
            r#"cortex sync - Data replication commands

USAGE:
  cortex sync <subcommand> [args]

SUBCOMMANDS:
  status [TABLE]        Show replication status (all tables or specific)
  repair TABLE          Repair table replication

EXAMPLES:
  cortex sync status --pretty
  cortex sync status users
  cortex sync repair users"#
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
            eprintln!("  get, put, delete, query, all, keys, acl,");
            eprintln!("  mesh, identity, scope, info, sync");
            eprintln!();
            eprintln!("Available patterns:");
            eprintln!("  patterns, memories, statemachine, identities");
        }
    }
}
