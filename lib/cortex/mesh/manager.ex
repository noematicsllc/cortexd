defmodule Cortex.Mesh.Manager do
  @moduledoc """
  Manages mesh connectivity: Erlang distribution setup, node connections,
  and node up/down event handling.

  Only starts when mesh config is present.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a new peer and attempt connection immediately.
  Called by Pairing after a successful join.
  """
  def add_peer(name, host, port) do
    GenServer.cast(__MODULE__, {:add_peer, name, host, port})
  end

  @impl true
  def init(_opts) do
    case Cortex.mesh_config() do
      nil ->
        :ignore

      config ->
        node_name = Keyword.fetch!(config, :node_name)
        nodes = Keyword.get(config, :nodes, [])

        # Monitor node connections
        :net_kernel.monitor_nodes(true)

        # Connect to peer nodes asynchronously
        send(self(), :connect_peers)
        schedule_reconnect()

        {:ok, %{node_name: node_name, peers: nodes, config: config}}
    end
  end

  @impl true
  def handle_info(:connect_peers, state) do
    connected = Node.list()

    for {name, host, _port} <- state.peers do
      erlang_node = String.to_atom("cortex@#{host}")

      unless erlang_node in connected do
        case Node.connect(erlang_node) do
          true ->
            Logger.info("Connected to mesh peer: #{name} (#{erlang_node})")

          false ->
            Logger.warning("Could not connect to mesh peer: #{name} (#{erlang_node})")

          :ignored ->
            Logger.debug("Connection to #{name} ignored (not distributed)")
        end
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    connected = Node.list()

    for {name, host, _port} <- state.peers do
      erlang_node = String.to_atom("cortex@#{host}")

      unless erlang_node in connected do
        case Node.connect(erlang_node) do
          true -> Logger.info("Reconnected to mesh peer: #{name} (#{erlang_node})")
          _ -> :ok
        end
      end
    end

    schedule_reconnect()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Mesh node joined: #{node}")
    Task.start(fn -> Cortex.Sync.on_node_join(node) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Mesh node left: #{node}")
    Cortex.Sync.on_node_leave(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:connect_new_peer, name, host}, state) do
    erlang_node = String.to_atom("cortex@#{host}")

    case Node.connect(erlang_node) do
      true -> Logger.info("Connected to new mesh peer: #{name} (#{erlang_node})")
      false -> Logger.warning("Could not connect to new mesh peer: #{name} (#{erlang_node})")
      :ignored -> Logger.debug("Connection to #{name} ignored (not distributed)")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_peer, name, host, port}, state) do
    if Enum.any?(state.peers, fn {n, _, _} -> n == name end) do
      {:noreply, state}
    else
      peers = state.peers ++ [{name, host, port}]

      # Schedule connection with a short delay — the remote node may still be
      # finishing its pairing/TLS setup when we first learn about it.
      Process.send_after(self(), {:connect_new_peer, name, host}, 2_000)

      {:noreply, %{state | peers: peers}}
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 30_000)
  end

  @impl true
  def terminate(_reason, _state) do
    :net_kernel.monitor_nodes(false)
    :ok
  end
end
