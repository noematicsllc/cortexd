defmodule Cortex.Client do
  @moduledoc """
  Client for connecting to the Cortex daemon.

  Used by the CLI to communicate with the daemon over Unix socket.
  """

  @doc """
  Call an RPC method on the daemon.
  """
  def call(method, params \\ []) do
    socket_path = Cortex.socket_path()

    opts = [:binary, {:active, false}, {:packet, :raw}]

    case :gen_tcp.connect({:local, socket_path}, 0, opts, 5000) do
      {:ok, socket} ->
        result = send_request(socket, method, params)
        :gen_tcp.close(socket)
        result

      {:error, :enoent} ->
        {:error, "daemon not running (socket not found)"}

      {:error, :econnrefused} ->
        {:error, "daemon not running (connection refused)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_request(socket, method, params) do
    msgid = :erlang.unique_integer([:positive]) |> rem(1_000_000)
    request = Msgpax.pack!([0, msgid, method, params])

    case :gen_tcp.send(socket, request) do
      :ok ->
        receive_response(socket)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        case Msgpax.unpack(data) do
          {:ok, [1, _msgid, nil, result]} ->
            {:ok, result}

          {:ok, [1, _msgid, error, _result]} ->
            {:error, error}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
