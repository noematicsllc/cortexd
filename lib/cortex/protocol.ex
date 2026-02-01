defmodule Cortex.Protocol do
  @moduledoc """
  MessagePack-RPC protocol handler.

  Request:  [0, msgid, method, params]
  Response: [1, msgid, error, result]
  """

  @request_type 0
  @response_type 1

  @doc """
  Decode a MessagePack-RPC request.
  """
  def decode_request(data) do
    case Msgpax.unpack(data) do
      {:ok, [@request_type, msgid, method, params]} when is_binary(method) ->
        {:ok, %{msgid: msgid, method: method, params: params}}

      {:ok, [@request_type, msgid, method, params]} when is_atom(method) ->
        {:ok, %{msgid: msgid, method: Atom.to_string(method), params: params}}

      {:ok, _other} ->
        {:error, :invalid_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Encode a success response.
  """
  def encode_response(msgid, result) do
    Msgpax.pack!([@response_type, msgid, nil, encode_value(result)])
  end

  @doc """
  Encode an error response.
  """
  def encode_error(msgid, error) do
    error_str = format_error(error)
    Msgpax.pack!([@response_type, msgid, error_str, nil])
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error(error), do: inspect(error)

  # Ensure values are MessagePack-compatible
  defp encode_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {encode_key(k), encode_value(v)} end)
    |> Map.new()
  end

  defp encode_value(value) when is_list(value) do
    Enum.map(value, &encode_value/1)
  end

  defp encode_value(value) when is_tuple(value) do
    value |> Tuple.to_list() |> encode_value()
  end

  defp encode_value(value) when is_atom(value) and value not in [nil, true, false] do
    Atom.to_string(value)
  end

  defp encode_value(value), do: value

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: key
end
