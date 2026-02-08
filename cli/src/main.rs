use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use clap::{Parser, Subcommand};
use rmpv::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, ExitCode};
use std::sync::atomic::{AtomicU32, Ordering};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const DEFAULT_SOCKET: &str = "/run/cortex/cortex.sock";

// Default ports derived from TA2 (Terminologia Anatomica) term numbers
// for subdivisions of the cerebral cortex:
//
//   5528  Cortex cerebri    — Mesh TLS (main inter-node traffic)
//   5529  Allocortex        — Pairing (simpler handshake for new nodes)
//   5530  Archicortex       — (reserved: replication/sync)
//   5531  Paleocortex       — (reserved: discovery/monitoring)
//   5532  Neocortex         — (reserved: compute/orchestration)
//   5533  Juxtallocortex    — (reserved: gateway/proxy)
//   5534  Isocortex         — (reserved: admin/management)
const DEFAULT_TLS_PORT: u16 = 5528;
const PAIRING_PORT_OFFSET: u16 = 1;

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
    /// Initialize a new mesh (generate CA, certs, config, and print join token)
    Init {
        /// Host IP or hostname for this node (auto-detected if omitted)
        #[arg(long)]
        host: Option<String>,

        /// Node name (default: hostname with random suffix)
        #[arg(long)]
        name: Option<String>,

        /// TLS port (TA2 5528: cortex cerebri)
        #[arg(long, default_value_t = DEFAULT_TLS_PORT)]
        port: u16,

        /// Overwrite existing mesh config
        #[arg(long)]
        force: bool,

        /// Certificate directory (default: /etc/cortex/mesh)
        #[arg(long)]
        dir: Option<String>,
    },

    /// Join an existing mesh using a join token
    Join {
        /// Join token (cxm_...)
        token: String,

        /// Node name (default: hostname with random suffix)
        #[arg(long)]
        name: Option<String>,

        /// Overwrite existing mesh config
        #[arg(long)]
        force: bool,

        /// Certificate directory (default: /etc/cortex/mesh)
        #[arg(long)]
        dir: Option<String>,
    },

    /// Generate a join token for a new node to join the mesh
    Invite,

    /// Initialize a new mesh Certificate Authority (manual workflow)
    InitCa {
        /// Directory for CA files (default: ~/.cortex/mesh)
        #[arg(long)]
        dir: Option<String>,

        /// Overwrite existing CA
        #[arg(long)]
        force: bool,
    },

    /// Add a node to the mesh (manual workflow)
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
            MeshCommands::Init { host, name, port, force, dir } => {
                return mesh_init(&cli.socket, host.as_deref(), name.as_deref(), *port, *force, dir.as_deref());
            }
            MeshCommands::Join { token, name, force, dir } => {
                return mesh_join(&cli.socket, token, name.as_deref(), *force, dir.as_deref());
            }
            MeshCommands::Invite => call(&cli.socket, "mesh_invite", vec![]),
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

// --- Mesh init/join/invite ---

const DEFAULT_MESH_CERT_DIR: &str = "/etc/cortex/mesh";
const DEFAULT_MESH_ENV: &str = "/etc/cortex/mesh.env";

fn default_node_name() -> String {
    let hostname = hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "node".to_string());
    // Trim to first component, add random suffix
    let base = hostname.split('.').next().unwrap_or("node");
    let suffix: String = (0..4)
        .map(|_| format!("{:02x}", rand::random::<u8>()))
        .collect();
    format!("{}-{}", base, suffix)
}

fn detect_host_ip() -> Result<String, String> {
    // Try to detect primary IP by connecting to a public address
    // (doesn't actually send data, just determines the local interface)
    match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(socket) => {
            // Connect to a public DNS — this picks the default route interface
            match socket.connect("8.8.8.8:80") {
                Ok(_) => match socket.local_addr() {
                    Ok(addr) => Ok(addr.ip().to_string()),
                    Err(_) => Ok("127.0.0.1".to_string()),
                },
                Err(_) => Ok("127.0.0.1".to_string()),
            }
        }
        Err(_) => Ok("127.0.0.1".to_string()),
    }
}

fn write_mesh_env(
    node_name: &str,
    tls_port: u16,
    ca_cert: &str,
    node_cert: &str,
    node_key: &str,
    peers: &str,
    env_path: &str,
) -> Result<(), String> {
    let content = format!(
        "CORTEX_MESH_NODE_NAME={}\nCORTEX_MESH_TLS_PORT={}\nCORTEX_MESH_CA_CERT={}\nCORTEX_MESH_NODE_CERT={}\nCORTEX_MESH_NODE_KEY={}\nCORTEX_MESH_NODES={}\nCORTEX_MESH_HOST={}\n",
        node_name, tls_port, ca_cert, node_cert, node_key, peers, ""
    );

    fs::write(env_path, &content).map_err(|e| format!("cannot write {}: {}", env_path, e))
}

fn restart_daemon_and_wait(socket_path: &str) -> Result<(), String> {
    let output = Command::new("systemctl")
        .args(["restart", "cortexd"])
        .output()
        .map_err(|e| format!("failed to run systemctl: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "systemctl restart failed: {}\nCheck: journalctl -u cortexd",
            stderr.trim()
        ));
    }

    // Poll for health
    for _ in 0..20 {
        std::thread::sleep(std::time::Duration::from_millis(500));
        if call(socket_path, "ping", vec![]).is_ok() {
            return Ok(());
        }
    }

    Err("daemon did not become healthy within 10 seconds.\nCheck: journalctl -u cortexd".to_string())
}

fn mesh_init(
    socket_path: &str,
    host: Option<&str>,
    name: Option<&str>,
    port: u16,
    force: bool,
    dir: Option<&str>,
) -> ExitCode {
    let mesh_dir = dir.map(String::from).unwrap_or_else(|| DEFAULT_MESH_CERT_DIR.to_string());
    let ca_key = format!("{}/ca.key", mesh_dir);

    // Check if already exists
    if std::path::Path::new(&ca_key).exists() && !force {
        eprintln!(
            "error: mesh already initialized at {}. Use --force to overwrite.",
            mesh_dir
        );
        return ExitCode::FAILURE;
    }

    let node_name = name
        .map(String::from)
        .unwrap_or_else(default_node_name);

    let host_str = match host {
        Some(h) => h.to_string(),
        None => match detect_host_ip() {
            Ok(ip) => ip,
            Err(e) => {
                eprintln!("error: {}", e);
                return ExitCode::FAILURE;
            }
        },
    };

    // Validate node name
    if !node_name
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        || node_name.is_empty()
    {
        eprintln!("error: invalid node name: must be alphanumeric with hyphens/underscores");
        return ExitCode::FAILURE;
    }

    eprintln!("Initializing mesh...");
    eprintln!("  Node name: {}", node_name);
    eprintln!("  Host: {}", host_str);
    eprintln!("  TLS port: {}", port);
    eprintln!("  Cert dir: {}", mesh_dir);

    // Step 1: Generate CA
    if let ExitCode::FAILURE = mesh_init_ca(Some(&mesh_dir), force) {
        return ExitCode::FAILURE;
    }

    // Step 2: Generate node cert
    if let ExitCode::FAILURE = mesh_add_node(&node_name, &host_str, Some(&mesh_dir)) {
        return ExitCode::FAILURE;
    }

    let ca_cert = format!("{}/ca.crt", mesh_dir);
    let node_cert = format!("{}/nodes/{}.crt", mesh_dir, node_name);
    let node_key = format!("{}/nodes/{}.key", mesh_dir, node_name);

    // Step 3: Write mesh.env
    let env_path = DEFAULT_MESH_ENV;
    if let Err(e) = write_mesh_env(&node_name, port, &ca_cert, &node_cert, &node_key, "", env_path) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }
    eprintln!("  Mesh config: {}", env_path);

    // Step 4: Restart daemon
    eprintln!("Restarting cortexd...");
    if let Err(e) = restart_daemon_and_wait(socket_path) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    // Step 5: Get join token
    match call(socket_path, "mesh_invite", vec![]) {
        Ok(Some(Value::String(token))) => {
            let token_str = token.as_str().unwrap_or_default();
            println!();
            println!("Mesh initialized on {}:{}", host_str, port);
            println!("Join token: {}", token_str);
            println!();
            println!("Share this token with other nodes to join the mesh.");
            ExitCode::SUCCESS
        }
        Ok(_) => {
            eprintln!("error: unexpected response from mesh_invite");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("error: failed to generate join token: {}", e);
            ExitCode::FAILURE
        }
    }
}

fn decode_join_token(token: &str) -> Result<(String, u16, String, String), String> {
    let payload_b64 = token
        .strip_prefix("cxm_")
        .ok_or_else(|| "invalid join token: must start with cxm_".to_string())?;

    let payload_bytes = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .map_err(|e| format!("invalid join token encoding: {}", e))?;

    let payload = String::from_utf8(payload_bytes)
        .map_err(|_| "invalid join token: not valid UTF-8".to_string())?;

    let parts: Vec<&str> = payload.split(':').collect();
    if parts.len() != 4 {
        return Err("invalid join token: expected 4 colon-delimited fields".to_string());
    }

    let host = parts[0].to_string();
    let port: u16 = parts[1]
        .parse()
        .map_err(|_| "invalid join token: bad port".to_string())?;
    let secret = parts[2].to_string();
    let cert_fingerprint = parts[3].to_string();

    Ok((host, port, secret, cert_fingerprint))
}

fn mesh_join(
    socket_path: &str,
    token: &str,
    name: Option<&str>,
    force: bool,
    dir: Option<&str>,
) -> ExitCode {
    let mesh_dir = dir.map(String::from).unwrap_or_else(|| DEFAULT_MESH_CERT_DIR.to_string());
    let ca_cert_path = format!("{}/ca.crt", mesh_dir);

    // Check if already exists
    if std::path::Path::new(&ca_cert_path).exists() && !force {
        eprintln!(
            "error: mesh already configured at {}. Use --force to overwrite.",
            mesh_dir
        );
        return ExitCode::FAILURE;
    }

    // Step 1: Decode token
    let (host, tls_port, secret, cert_fingerprint) = match decode_join_token(token) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("error: {}", e);
            return ExitCode::FAILURE;
        }
    };
    let pairing_port = tls_port + PAIRING_PORT_OFFSET;

    let node_name = name
        .map(String::from)
        .unwrap_or_else(default_node_name);

    eprintln!("Joining mesh...");
    eprintln!("  Seed: {}:{}", host, tls_port);
    eprintln!("  Node name: {}", node_name);

    // Step 2: Generate local keypair + CSR
    if let Err(e) = fs::create_dir_all(&mesh_dir) {
        eprintln!("error: cannot create directory {}: {}", mesh_dir, e);
        return ExitCode::FAILURE;
    }

    let node_key = format!("{}/{}.key", mesh_dir, node_name);
    let node_csr = format!("{}/{}.csr", mesh_dir, node_name);

    if let Err(e) = run_openssl(&["genrsa", "-out", &node_key, "2048"]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&node_key, fs::Permissions::from_mode(0o600));
    }

    if let Err(e) = run_openssl(&[
        "req", "-new", "-key", &node_key, "-out", &node_csr, "-subj",
        &format!("/CN={}", node_name),
    ]) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    let csr_pem = match fs::read_to_string(&node_csr) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot read CSR: {}", e);
            return ExitCode::FAILURE;
        }
    };
    let _ = fs::remove_file(&node_csr);

    // Step 3: Connect to seed's pairing port over TLS
    eprintln!("  Connecting to {}:{}...", host, pairing_port);

    let connector = match native_tls::TlsConnector::builder()
        .danger_accept_invalid_certs(true) // We verify via fingerprint instead
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: TLS setup failed: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let tcp_stream = match std::net::TcpStream::connect(format!("{}:{}", host, pairing_port)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: cannot connect to {}:{}: {}", host, pairing_port, e);
            return ExitCode::FAILURE;
        }
    };

    let tls_stream = match connector.connect(&host, tcp_stream) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("error: TLS handshake failed: {}", e);
            return ExitCode::FAILURE;
        }
    };

    // Step 4: Verify CA fingerprint
    let peer_cert = match tls_stream.peer_certificate() {
        Ok(Some(cert)) => cert,
        _ => {
            eprintln!("error: no peer certificate from seed node");
            return ExitCode::FAILURE;
        }
    };

    let cert_der = peer_cert.to_der().unwrap_or_default();
    let fingerprint = format!("{:x}", Sha256::digest(&cert_der));

    if fingerprint != cert_fingerprint {
        eprintln!("error: CA fingerprint mismatch!");
        eprintln!("  Expected: {}", cert_fingerprint);
        eprintln!("  Got:      {}", fingerprint);
        eprintln!("  This may indicate a man-in-the-middle attack.");
        return ExitCode::FAILURE;
    }

    eprintln!("  CA fingerprint verified.");

    // Step 5: Send mesh.pair RPC
    let mut tls_stream = tls_stream;
    let msgid = MSG_ID.fetch_add(1, Ordering::SeqCst);
    let request = Value::Array(vec![
        Value::Integer(0.into()),
        Value::Integer(msgid.into()),
        Value::String("mesh.pair".into()),
        Value::Array(vec![
            Value::String(secret.into()),
            Value::String(csr_pem.into()),
            Value::String(node_name.clone().into()),
        ]),
    ]);

    let mut buf = Vec::new();
    if let Err(e) = rmpv::encode::write_value(&mut buf, &request) {
        eprintln!("error: encode failed: {}", e);
        return ExitCode::FAILURE;
    }

    if let Err(e) = tls_stream.write_all(&buf) {
        eprintln!("error: failed to send pairing request: {}", e);
        return ExitCode::FAILURE;
    }

    // Step 6: Read response
    let mut response_buf = vec![0u8; 65536];
    let n = match tls_stream.read(&mut response_buf) {
        Ok(n) => n,
        Err(e) => {
            eprintln!("error: failed to read pairing response: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let response = match rmpv::decode::read_value(&mut &response_buf[..n]) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error: failed to decode response: {}", e);
            return ExitCode::FAILURE;
        }
    };

    // Parse response: [1, msgid, error, result]
    let result_map = match &response {
        Value::Array(parts) if parts.len() == 4 => {
            if parts[2] != Value::Nil {
                let err_str = match &parts[2] {
                    Value::String(s) => s.as_str().unwrap_or("unknown error").to_string(),
                    _ => format!("{}", parts[2]),
                };
                eprintln!("error: pairing failed: {}", err_str);
                return ExitCode::FAILURE;
            }
            match &parts[3] {
                Value::Map(m) => m.clone(),
                _ => {
                    eprintln!("error: unexpected pairing response format");
                    return ExitCode::FAILURE;
                }
            }
        }
        _ => {
            eprintln!("error: invalid pairing response");
            return ExitCode::FAILURE;
        }
    };

    // Extract cert, ca_cert, peers from the map
    let get_str = |key: &str| -> Option<String> {
        result_map.iter().find_map(|(k, v)| {
            if let (Value::String(ks), Value::String(vs)) = (k, v) {
                if ks.as_str() == Some(key) {
                    return vs.as_str().map(|s| s.to_string());
                }
            }
            None
        })
    };

    let signed_cert = match get_str("cert") {
        Some(c) => c,
        None => {
            eprintln!("error: pairing response missing 'cert'");
            return ExitCode::FAILURE;
        }
    };

    let ca_cert_pem = match get_str("ca_cert") {
        Some(c) => c,
        None => {
            eprintln!("error: pairing response missing 'ca_cert'");
            return ExitCode::FAILURE;
        }
    };

    // Parse peers list
    let peers_value = result_map.iter().find_map(|(k, v)| {
        if let Value::String(ks) = k {
            if ks.as_str() == Some("peers") {
                return Some(v.clone());
            }
        }
        None
    });

    let peers_str = match peers_value {
        Some(Value::Array(arr)) => {
            let entries: Vec<String> = arr.iter().filter_map(|entry| {
                if let Value::Array(parts) = entry {
                    if parts.len() >= 3 {
                        let name = match &parts[0] { Value::String(s) => s.as_str().unwrap_or("").to_string(), _ => return None };
                        let host = match &parts[1] { Value::String(s) => s.as_str().unwrap_or("").to_string(), _ => return None };
                        let port = match &parts[2] { Value::Integer(i) => i.as_u64().unwrap_or(DEFAULT_TLS_PORT as u64).to_string(), _ => return None };
                        return Some(format!("{}:{}:{}", name, host, port));
                    }
                }
                None
            }).collect();
            entries.join(",")
        }
        _ => String::new(),
    };

    // Step 7: Write certs
    let node_cert_path = format!("{}/{}.crt", mesh_dir, node_name);

    if let Err(e) = fs::write(&ca_cert_path, &ca_cert_pem) {
        eprintln!("error: cannot write CA cert: {}", e);
        return ExitCode::FAILURE;
    }
    if let Err(e) = fs::write(&node_cert_path, &signed_cert) {
        eprintln!("error: cannot write node cert: {}", e);
        return ExitCode::FAILURE;
    }

    eprintln!("  Certificate signed by mesh CA.");

    // Determine TLS port from peers (first peer's port)
    let tls_port: u16 = peers_str
        .split(',')
        .next()
        .and_then(|p| p.split(':').nth(2))
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_TLS_PORT);

    // Step 8: Write mesh.env
    let env_path = DEFAULT_MESH_ENV;
    if let Err(e) = write_mesh_env(&node_name, tls_port, &ca_cert_path, &node_cert_path, &node_key, &peers_str, env_path) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    // Step 9: Restart daemon
    eprintln!("Restarting cortexd...");
    if let Err(e) = restart_daemon_and_wait(socket_path) {
        eprintln!("error: {}", e);
        return ExitCode::FAILURE;
    }

    eprintln!("  Mesh configured. Node name: {}", node_name);
    println!("Joined mesh. Connected peers: {}", peers_str);
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

  mesh init                     Initialize a new mesh and print join token
  mesh join TOKEN               Join an existing mesh with a token
  mesh invite                   Generate a join token for new nodes
  mesh init-ca                  Initialize mesh CA (manual workflow)
  mesh add-node NAME HOST       Generate node cert (manual workflow)
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
  init                          Initialize a new mesh and print join token
  join TOKEN                    Join an existing mesh with a token
  invite                        Generate a join token for new nodes
  init-ca                       Initialize mesh CA (manual workflow)
  add-node NAME HOST            Generate certificate for a node (manual)
  list-nodes                    List configured mesh nodes
  status                        Show mesh connectivity status

QUICK START (token-based):
  # On first node:
  sudo cortex mesh init
  # → prints a join token: cxm_...

  # On each additional node (copy-paste the token):
  sudo cortex mesh join cxm_...

  # To add more nodes later, from any mesh node:
  cortex mesh invite

MANUAL WORKFLOW:
  1. cortex mesh init-ca
  2. cortex mesh add-node my-node 192.168.1.10
  3. Copy certs to node, configure mesh in config.exs
  4. cortex mesh status

OPTIONS:
  --host HOST   Host IP/hostname (init/join, auto-detected if omitted)
  --name NAME   Node name (init/join, auto-generated if omitted)
  --port PORT   TLS port (init, default: 5528)
  --dir PATH    Cert directory (default: /etc/cortex/mesh)
  --force       Overwrite existing config

EXAMPLES:
  sudo cortex mesh init --host 10.0.0.1
  sudo cortex mesh join cxm_MTU4LjY5Li...
  cortex mesh invite
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
