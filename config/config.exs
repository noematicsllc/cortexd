import Config

# Default configuration
config :cortex,
  socket_path: System.get_env("CORTEX_SOCKET", "/run/cortex/cortex.sock"),
  data_dir: System.get_env("CORTEX_DATA_DIR", "/var/lib/cortex/mnesia")

# Mesh networking (optional — omit to run in single-node mode)
# config :cortex, :mesh,
#   node_name: "my-node",
#   tls_port: 4711,
#   ca_cert: "/etc/cortex/ca.crt",
#   node_cert: "/etc/cortex/node.crt",
#   node_key: "/etc/cortex/node.key",
#   nodes: [
#     {"peer-node", "192.168.1.10", 4711}
#   ]

# Development overrides
if config_env() == :dev do
  config :cortex,
    socket_path: Path.expand("../tmp/cortex.sock", __DIR__),
    data_dir: Path.expand("../tmp/mnesia", __DIR__)
end

if config_env() == :test do
  config :cortex,
    socket_path: Path.expand("../tmp/test_cortex.sock", __DIR__),
    data_dir: Path.expand("../tmp/test_mnesia", __DIR__)
end
