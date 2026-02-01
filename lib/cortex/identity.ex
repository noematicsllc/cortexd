defmodule Cortex.Identity do
  @moduledoc """
  Extract peer credentials from Unix socket connections.

  Uses SO_PEERCRED via NIF to get the connecting process's UID.
  This is kernel-enforced and cannot be forged.
  """

  alias Cortex.Peercred

  @doc """
  Extract the UID from a connected gen_tcp socket.

  Returns {:ok, uid} or {:error, reason}.
  """
  def get_uid(socket) do
    with {:ok, fd} <- :inet.getfd(socket),
         {:ok, {_pid, uid, _gid}} <- Peercred.get_peercred(fd) do
      {:ok, uid}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Format a UID as an identity string.
  """
  def uid_to_identity(uid), do: "uid:#{uid}"

  @doc """
  Parse an identity string to extract the UID.
  """
  def parse_identity("uid:" <> uid_str) do
    case Integer.parse(uid_str) do
      {uid, ""} -> {:ok, uid}
      _ -> {:error, :invalid_identity}
    end
  end

  def parse_identity("*"), do: {:ok, :world}
  def parse_identity(_), do: {:error, :invalid_identity}
end
