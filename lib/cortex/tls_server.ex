defmodule Cortex.TLSServer do
  @moduledoc """
  TLS server for mesh networking.

  Accepts mTLS connections from peer nodes and spawns handler processes
  via the shared HandlerSupervisor. Only starts when mesh config is present.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    case Cortex.mesh_config() do
      nil ->
        :ignore

      mesh_config ->
        port = Keyword.get(mesh_config, :tls_port, 5528)
        ca_cert = Keyword.fetch!(mesh_config, :ca_cert)
        node_cert = Keyword.fetch!(mesh_config, :node_cert)
        node_key = Keyword.fetch!(mesh_config, :node_key)

        ssl_opts = [
          {:certfile, node_cert},
          {:keyfile, node_key},
          {:cacertfile, ca_cert},
          {:verify, :verify_peer},
          {:fail_if_no_peer_cert, true},
          {:versions, [:"tlsv1.3", :"tlsv1.2"]},
          {:mode, :binary},
          {:active, false},
          {:reuseaddr, true}
        ]

        case :ssl.listen(port, ssl_opts) do
          {:ok, listen_socket} ->
            Logger.info("TLS listener on port #{port}")
            send(self(), :accept)
            {:ok, %{socket: listen_socket, port: port}}

          {:error, reason} ->
            Logger.error("TLS listen failed: #{inspect(reason)}")
            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :ssl.transport_accept(state.socket, 100) do
      {:ok, transport_socket} ->
        # Handshake in a spawned task to avoid blocking the accept loop
        spawn(fn -> complete_handshake(transport_socket) end)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("TLS accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  defp complete_handshake(transport_socket) do
    case :ssl.handshake(transport_socket, 5_000) do
      {:ok, ssl_socket} ->
        case DynamicSupervisor.start_child(
               Cortex.HandlerSupervisor,
               {Cortex.Handler, {ssl_socket, :tls}}
             ) do
          {:ok, pid} ->
            case :ssl.controlling_process(ssl_socket, pid) do
              :ok ->
                send(pid, :start)

              {:error, reason} ->
                Logger.error("TLS controlling_process failed: #{inspect(reason)}")
                :ssl.close(ssl_socket)
            end

          {:error, reason} ->
            Logger.error("Failed to start TLS handler: #{inspect(reason)}")
            :ssl.close(ssl_socket)
        end

      {:error, reason} ->
        Logger.warning("TLS handshake failed: #{inspect(reason)}")
        :ssl.close(transport_socket)
    end
  end

  @impl true
  def terminate(_reason, state) do
    :ssl.close(state.socket)
    :ok
  end
end
