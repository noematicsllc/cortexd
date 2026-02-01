import Config

# Default configuration
config :cortex,
  socket_path: System.get_env("CORTEX_SOCKET", "/run/cortex/cortex.sock"),
  data_dir: System.get_env("CORTEX_DATA_DIR", "/var/lib/cortex/mnesia")

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
