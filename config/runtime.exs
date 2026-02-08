import Config

# Mesh networking configuration from environment variables.
# Written by `cortex mesh init` or `cortex mesh join` to /etc/cortex/mesh.env,
# sourced by rel/env.sh.eex before the application starts.

if node_name = System.get_env("CORTEX_MESH_NODE_NAME") do
  tls_port =
    System.get_env("CORTEX_MESH_TLS_PORT", "5528")
    |> String.to_integer()

  ca_cert = System.get_env("CORTEX_MESH_CA_CERT", "/etc/cortex/mesh/ca.crt")
  node_cert = System.get_env("CORTEX_MESH_NODE_CERT")
  node_key = System.get_env("CORTEX_MESH_NODE_KEY")
  host = System.get_env("CORTEX_MESH_HOST", "127.0.0.1")

  # Parse CORTEX_MESH_NODES: "name1:host1:port1,name2:host2:port2"
  nodes =
    case System.get_env("CORTEX_MESH_NODES", "") do
      "" ->
        []

      nodes_str ->
        nodes_str
        |> String.split(",", trim: true)
        |> Enum.map(fn entry ->
          case String.split(entry, ":") do
            [name, host, port] -> {name, host, String.to_integer(port)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
    end

  config :cortex, :mesh,
    node_name: node_name,
    tls_port: tls_port,
    ca_cert: ca_cert,
    node_cert: node_cert,
    node_key: node_key,
    host: host,
    nodes: nodes
end
