defmodule Cortex.Mesh.DistConfig do
  @moduledoc """
  Generates Erlang distribution TLS configuration for mesh networking.

  When mesh config is present, call `setup/0` before starting the node
  to configure Erlang distribution to use TLS with the same certificates
  as the mTLS RPC listener.
  """

  @doc """
  Generate the inet_tls.conf content for Erlang distribution over TLS.
  """
  def generate_config(mesh_config) do
    ca_cert = Keyword.fetch!(mesh_config, :ca_cert) |> escape_path()
    node_cert = Keyword.fetch!(mesh_config, :node_cert) |> escape_path()
    node_key = Keyword.fetch!(mesh_config, :node_key) |> escape_path()

    """
    [{server, [
      {certfile, "#{node_cert}"},
      {keyfile, "#{node_key}"},
      {cacertfile, "#{ca_cert}"},
      {verify, verify_peer},
      {fail_if_no_peer_cert, true},
      {secure_renegotiate, true}
    ]},
    {client, [
      {certfile, "#{node_cert}"},
      {keyfile, "#{node_key}"},
      {cacertfile, "#{ca_cert}"},
      {verify, verify_peer},
      {secure_renegotiate, true}
    ]}].
    """
  end

  defp escape_path(path) do
    path
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  @doc """
  Write the TLS config file and return the path.
  """
  def write_config(mesh_config, output_dir \\ nil) do
    dir = output_dir || Cortex.data_dir()
    path = Path.join(dir, "inet_tls.conf")
    File.mkdir_p!(dir)
    File.write!(path, generate_config(mesh_config))
    path
  end
end
