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

        {:ok, %{node_name: node_name, peers: nodes, config: config}}
    end
  end

  @impl true
  def handle_info(:connect_peers, state) do
    for {name, host, _port} <- state.peers do
      erlang_node = String.to_atom("cortex@#{host}")

      case Node.connect(erlang_node) do
        true ->
          Logger.info("Connected to mesh peer: #{name} (#{erlang_node})")

        false ->
          Logger.warning("Could not connect to mesh peer: #{name} (#{erlang_node})")

        :ignored ->
          Logger.debug("Connection to #{name} ignored (not distributed)")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Mesh node joined: #{node}")
    Cortex.Sync.on_node_join(node)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Mesh node left: #{node}")
    Cortex.Sync.on_node_leave(node)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :net_kernel.monitor_nodes(false)
    :ok
  end
end
