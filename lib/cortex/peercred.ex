defmodule Cortex.Peercred do
  @moduledoc """
  NIF for getting SO_PEERCRED from Unix domain sockets.
  """

  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:cortex), ~c"peercred_nif")
    :erlang.load_nif(path, 0)
  end

  @doc """
  Get peer credentials from a socket file descriptor.

  Returns {:ok, {pid, uid, gid}} or {:error, reason}.
  """
  def get_peercred(_fd) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
