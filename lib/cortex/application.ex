defmodule Cortex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Mesh networking (only when configured)
    children =
      [
        # Initialize Mnesia
        Cortex.Store,
        # DynamicSupervisor for connection handlers (max 1000 concurrent connections)
        {DynamicSupervisor,
         name: Cortex.HandlerSupervisor, strategy: :one_for_one, max_children: 1000},
        # Unix socket accept loop
        Cortex.Server
      ] ++
        if(Cortex.mesh_config(),
          do: [Cortex.Mesh.Manager, Cortex.TLSServer],
          else: []
        )

    opts = [strategy: :one_for_one, name: Cortex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
