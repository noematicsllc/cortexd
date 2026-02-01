defmodule Cortex do
  @moduledoc """
  Cortex - Local storage daemon with embedded Mnesia database.

  Provides table operations with UID-based namespacing and access control.
  """

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
end
