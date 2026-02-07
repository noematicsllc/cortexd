defmodule Cortex.TestHelpers.Mesh do
  @moduledoc false

  @doc """
  Generate a full set of test certificates (CA + two nodes) in the given directory.
  Returns a map with paths to all cert/key files.
  """
  def generate_test_certs(dir) do
    File.mkdir_p!(dir)

    {:ok, _} = Cortex.Mesh.Certs.init_ca(dir, force: true)
    {:ok, _} = Cortex.Mesh.Certs.add_node(dir, "node-a", "127.0.0.1")
    {:ok, _} = Cortex.Mesh.Certs.add_node(dir, "node-b", "127.0.0.1")

    %{
      ca_cert: Path.join(dir, "ca.crt"),
      node_a: %{
        cert: Path.join([dir, "nodes", "node-a.crt"]),
        key: Path.join([dir, "nodes", "node-a.key"])
      },
      node_b: %{
        cert: Path.join([dir, "nodes", "node-b.crt"]),
        key: Path.join([dir, "nodes", "node-b.key"])
      }
    }
  end

  @doc """
  Generate a separate CA + node cert (for wrong-CA tests).
  """
  def generate_rogue_certs(dir) do
    File.mkdir_p!(dir)

    {:ok, _} = Cortex.Mesh.Certs.init_ca(dir, force: true)
    {:ok, _} = Cortex.Mesh.Certs.add_node(dir, "rogue-node", "127.0.0.1")

    %{
      ca_cert: Path.join(dir, "ca.crt"),
      cert: Path.join([dir, "nodes", "rogue-node.crt"]),
      key: Path.join([dir, "nodes", "rogue-node.key"])
    }
  end

  @doc """
  Build mesh config keyword list for a given node using test certs.
  """
  def mesh_config_for(certs, node_key, node_name, port, peers \\ []) do
    node = Map.fetch!(certs, node_key)

    [
      node_name: node_name,
      tls_port: port,
      ca_cert: certs.ca_cert,
      node_cert: node.cert,
      node_key: node.key,
      nodes: peers
    ]
  end

  @doc """
  Start a raw TLS listener with mTLS enforcement on a random port.
  Returns {:ok, listen_socket, port}.
  """
  def start_tls_listener(certs, node_key) do
    node = Map.fetch!(certs, node_key)

    ssl_opts = [
      certfile: node.cert,
      keyfile: node.key,
      cacertfile: certs.ca_cert,
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      active: false,
      reuseaddr: true
    ]

    {:ok, listen_socket} = :ssl.listen(0, ssl_opts)
    {:ok, {_addr, port}} = :ssl.sockname(listen_socket)
    {:ok, listen_socket, port}
  end

  @doc """
  Connect to a TLS server using the given certs.
  Returns {:ok, ssl_socket} or {:error, reason}.
  """
  def tls_connect(port, certs, node_key) do
    node = Map.fetch!(certs, node_key)

    client_opts = [
      certfile: node.cert,
      keyfile: node.key,
      cacertfile: certs.ca_cert,
      verify: :verify_peer,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      active: false
    ]

    :ssl.connect(~c"127.0.0.1", port, client_opts, 5_000)
  end

  @doc """
  Send a MsgPack-RPC request and receive the response over an SSL socket.
  """
  def rpc_call(ssl_socket, method, params \\ []) do
    msgid = :erlang.unique_integer([:positive])
    request = Msgpax.pack!([0, msgid, method, params])
    :ok = :ssl.send(ssl_socket, request)

    case :ssl.recv(ssl_socket, 0, 5_000) do
      {:ok, data} ->
        {:ok, [1, ^msgid, error, result]} = Msgpax.unpack(data)
        if error, do: {:error, error}, else: {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a 5-element MsgPack-RPC request with metadata and receive the response.
  The metadata map typically contains %{"uid" => remote_uid}.
  """
  def rpc_call_with_metadata(ssl_socket, method, params, metadata) when is_map(metadata) do
    msgid = :erlang.unique_integer([:positive])
    request = Msgpax.pack!([0, msgid, method, params, metadata])
    :ok = :ssl.send(ssl_socket, request)

    case :ssl.recv(ssl_socket, 0, 5_000) do
      {:ok, data} ->
        {:ok, [1, ^msgid, error, result]} = Msgpax.unpack(data)
        if error, do: {:error, error}, else: {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a 5-element MsgPack-RPC request over a Unix gen_tcp socket (for testing rejection).
  """
  def unix_rpc_call_with_metadata(socket, method, params, metadata) when is_map(metadata) do
    msgid = :erlang.unique_integer([:positive])
    request = Msgpax.pack!([0, msgid, method, params, metadata])
    :ok = :gen_tcp.send(socket, request)

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        {:ok, [1, ^msgid, error, result]} = Msgpax.unpack(data)
        if error, do: {:error, error}, else: {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
