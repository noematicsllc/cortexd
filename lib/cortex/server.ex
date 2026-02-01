defmodule Cortex.Server do
  @moduledoc """
  Unix socket server using gen_tcp with local address family.

  Accepts connections and spawns handler processes via DynamicSupervisor.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    socket_path = Cortex.socket_path()

    # Ensure socket directory exists
    socket_dir = Path.dirname(socket_path)
    File.mkdir_p!(socket_dir)

    # Remove stale socket
    File.rm(socket_path)

    # Create Unix domain socket using gen_tcp
    opts = [
      {:ifaddr, {:local, socket_path}},
      :binary,
      {:active, false},
      {:packet, :raw},
      {:reuseaddr, true}
    ]

    case :gen_tcp.listen(0, opts) do
      {:ok, listen_socket} ->
        # Set socket permissions (0660)
        File.chmod!(socket_path, 0o660)

        Logger.info("Listening on #{socket_path}")

        # Start accepting
        send(self(), :accept)

        {:ok, %{socket: listen_socket, path: socket_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.socket, 100) do
      {:ok, client_socket} ->
        {:ok, pid} = DynamicSupervisor.start_child(
          Cortex.HandlerSupervisor,
          {Cortex.Handler, client_socket}
        )
        :gen_tcp.controlling_process(client_socket, pid)
        send(pid, :start)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    File.rm(state.path)
    :ok
  end
end
