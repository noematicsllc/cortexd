defmodule Cortex do
  @moduledoc """
  Cortex - Local storage daemon with embedded Mnesia database.

  Provides table operations with UID-based namespacing and access control.
  """

  # Default ports derived from TA2 (Terminologia Anatomica) term numbers
  # for subdivisions of the cerebral cortex:
  #
  #   5528  Cortex cerebri    — Mesh TLS (main inter-node traffic)
  #   5529  Allocortex        — Pairing (simpler handshake for new nodes)
  #   5530  Archicortex       — (reserved: replication/sync)
  #   5531  Paleocortex       — (reserved: discovery/monitoring)
  #   5532  Neocortex         — (reserved: compute/orchestration)
  #   5533  Juxtallocortex    — (reserved: gateway/proxy)
  #   5534  Isocortex         — (reserved: admin/management)

  @default_tls_port 5528
  @pairing_port_offset 1

  @doc "Default TLS port for mesh traffic (TA2 5528: cortex cerebri)."
  def default_tls_port, do: @default_tls_port

  @doc "Pairing port offset from TLS port (TA2 5529: allocortex)."
  def pairing_port_offset, do: @pairing_port_offset

  @doc """
  Returns the socket path for the Cortex daemon.
  """
  def socket_path do
    Application.get_env(:cortex, :socket_path, "/run/cortex/cortex.sock")
  end

  @doc """
  Returns the Mnesia data directory.
  """
  def data_dir do
    Application.get_env(:cortex, :data_dir, "/var/lib/cortex/mnesia")
  end

  @doc """
  Returns the mesh configuration, or nil if mesh networking is not configured.
  """
  def mesh_config do
    Application.get_env(:cortex, :mesh)
  end
end
