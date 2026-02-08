defmodule Cortex.Mesh.Pairing do
  @moduledoc """
  Pairing endpoint for mesh join protocol.

  Manages one-time secrets and runs a TLS listener on `tls_port + 1`
  that accepts join requests without client certificates. Only the
  `mesh.pair` RPC method is accepted on this listener.
  """

  use GenServer
  require Logger

  alias Cortex.Mesh.{JoinToken, Certs}
  alias Cortex.Protocol

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  @doc """
  Generate and store a new one-time pairing secret.
  Returns `{:ok, secret_hex}`.
  """
  def add_secret do
    GenServer.call(__MODULE__, :add_secret)
  end

  @doc """
  Validate and consume a one-time secret.
  Returns `{:ok, :valid}` or `{:error, reason}`.
  """
  def validate_secret(secret) do
    GenServer.call(__MODULE__, {:validate_secret, secret})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    case Cortex.mesh_config() do
      nil ->
        :ignore

      config ->
        tls_port = Keyword.get(config, :tls_port, Cortex.default_tls_port())
        pairing_port = tls_port + Cortex.pairing_port_offset()
        node_cert = Keyword.fetch!(config, :node_cert)
        node_key = Keyword.fetch!(config, :node_key)
        ca_cert = Keyword.fetch!(config, :ca_cert)

        ssl_opts = [
          {:certfile, node_cert},
          {:keyfile, node_key},
          {:cacertfile, ca_cert},
          {:verify, :verify_none},
          {:fail_if_no_peer_cert, false},
          {:versions, [:"tlsv1.3", :"tlsv1.2"]},
          {:mode, :binary},
          {:active, false},
          {:reuseaddr, true}
        ]

        case :ssl.listen(pairing_port, ssl_opts) do
          {:ok, listen_socket} ->
            Logger.info("Pairing listener on port #{pairing_port}")
            send(self(), :accept)

            ca_dir = Path.dirname(ca_cert)

            {:ok,
             %{
               socket: listen_socket,
               port: pairing_port,
               secrets: %{},
               config: config,
               ca_dir: ca_dir
             }}

          {:error, reason} ->
            Logger.error("Pairing listen failed on port #{pairing_port}: #{inspect(reason)}")
            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(:add_secret, _from, state) do
    secret = JoinToken.generate_secret()
    secrets = Map.put(state.secrets, secret, %{created_at: System.system_time(:second)})
    {:reply, {:ok, secret}, %{state | secrets: secrets}}
  end

  @impl true
  def handle_call({:validate_secret, secret}, _from, state) do
    if Map.has_key?(state.secrets, secret) do
      secrets = Map.delete(state.secrets, secret)
      {:reply, {:ok, :valid}, %{state | secrets: secrets}}
    else
      {:reply, {:error, "invalid or expired secret"}, state}
    end
  end

  @impl true
  def handle_cast({:add_peer, node_name, peer_host}, state) do
    tls_port = Keyword.get(state.config, :tls_port, Cortex.default_tls_port())
    existing_nodes = Keyword.get(state.config, :nodes, [])

    if Enum.any?(existing_nodes, fn {name, _, _} -> name == node_name end) do
      {:noreply, state}
    else
      updated_nodes = existing_nodes ++ [{node_name, peer_host, tls_port}]
      updated_config = Keyword.put(state.config, :nodes, updated_nodes)
      Application.put_env(:cortex, :mesh, updated_config)
      persist_mesh_env(updated_config)
      {:noreply, %{state | config: updated_config}}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :ssl.transport_accept(state.socket, 100) do
      {:ok, transport_socket} ->
        handler_ctx = Map.take(state, [:config, :ca_dir])
        spawn(fn -> complete_pairing_handshake(transport_socket, handler_ctx) end)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Pairing accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :ssl.close(state.socket)
    :ok
  end

  # --- Pairing connection handling ---

  defp complete_pairing_handshake(transport_socket, state) do
    case :ssl.handshake(transport_socket, 5_000) do
      {:ok, ssl_socket} ->
        handle_pairing_connection(ssl_socket, state)

      {:error, reason} ->
        Logger.warning("Pairing TLS handshake failed: #{inspect(reason)}")
        :ssl.close(transport_socket)
    end
  end

  defp handle_pairing_connection(ssl_socket, state) do
    case :ssl.recv(ssl_socket, 0, 10_000) do
      {:ok, data} ->
        case Protocol.decode_request(data) do
          {:ok, %{msgid: msgid, method: "mesh.pair", params: [secret, csr_pem, node_name]}} ->
            handle_pair_request(ssl_socket, msgid, secret, csr_pem, node_name, state)

          {:ok, %{msgid: msgid, method: method}} ->
            response =
              Protocol.encode_error(msgid, "method not available on pairing endpoint: #{method}")

            :ssl.send(ssl_socket, response)
            :ssl.close(ssl_socket)

          {:error, _reason} ->
            :ssl.close(ssl_socket)
        end

      {:error, _reason} ->
        :ssl.close(ssl_socket)
    end
  end

  defp handle_pair_request(ssl_socket, msgid, secret, csr_pem, node_name, state) do
    case validate_secret(secret) do
      {:ok, :valid} ->
        case Certs.sign_csr(csr_pem, state.ca_dir, node_name: node_name) do
          {:ok, cert_pem} ->
            ca_cert_pem = File.read!(Keyword.fetch!(state.config, :ca_cert))
            peers = build_peer_list(state.config)

            result = %{
              "cert" => cert_pem,
              "ca_cert" => ca_cert_pem,
              "peers" => peers
            }

            peer_host = peer_host_from_socket(ssl_socket)
            response = Protocol.encode_response(msgid, result)
            :ssl.send(ssl_socket, response)
            :ssl.close(ssl_socket)

            # Add the new node to the seed's mesh peer list and connect
            tls_port = Keyword.get(state.config, :tls_port, Cortex.default_tls_port())
            GenServer.cast(__MODULE__, {:add_peer, node_name, peer_host})
            Cortex.Mesh.Manager.add_peer(node_name, peer_host, tls_port)

            Logger.info("Paired node: #{node_name}")

          {:error, reason} ->
            response = Protocol.encode_error(msgid, "CSR signing failed: #{inspect(reason)}")
            :ssl.send(ssl_socket, response)
            :ssl.close(ssl_socket)
        end

      {:error, reason} ->
        response = Protocol.encode_error(msgid, reason)
        :ssl.send(ssl_socket, response)
        :ssl.close(ssl_socket)
    end
  end

  defp build_peer_list(config) do
    node_name = Keyword.fetch!(config, :node_name)
    tls_port = Keyword.get(config, :tls_port, Cortex.default_tls_port())
    nodes = Keyword.get(config, :nodes, [])

    # Include self + known peers
    self_entry = [node_name, node_host(config), tls_port]

    peer_entries =
      Enum.map(nodes, fn {name, host, port} -> [name, host, port] end)

    [self_entry | peer_entries]
  end

  defp node_host(config) do
    Keyword.get(config, :host, "127.0.0.1")
  end

  defp peer_host_from_socket(ssl_socket) do
    case :ssl.peername(ssl_socket) do
      {:ok, {ip, _port}} -> :inet.ntoa(ip) |> to_string()
      _ -> "unknown"
    end
  end

  defp persist_mesh_env(config) do
    env_path = "/etc/cortex/mesh.env"

    peers_str =
      config
      |> Keyword.get(:nodes, [])
      |> Enum.map(fn {name, host, port} -> "#{name}:#{host}:#{port}" end)
      |> Enum.join(",")

    content =
      [
        "CORTEX_MESH_NODE_NAME=#{Keyword.get(config, :node_name)}",
        "CORTEX_MESH_TLS_PORT=#{Keyword.get(config, :tls_port, 5528)}",
        "CORTEX_MESH_CA_CERT=#{Keyword.get(config, :ca_cert)}",
        "CORTEX_MESH_NODE_CERT=#{Keyword.get(config, :node_cert)}",
        "CORTEX_MESH_NODE_KEY=#{Keyword.get(config, :node_key)}",
        "CORTEX_MESH_NODES=#{peers_str}",
        "CORTEX_MESH_HOST=#{Keyword.get(config, :host, "127.0.0.1")}"
      ]
      |> Enum.join("\n")

    case File.write(env_path, content <> "\n") do
      :ok -> Logger.info("Updated #{env_path} with #{length(Keyword.get(config, :nodes, []))} peers")
      {:error, reason} -> Logger.warning("Could not update #{env_path}: #{inspect(reason)}")
    end
  end
end
