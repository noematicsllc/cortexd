defmodule Cortex.Handler do
  @moduledoc """
  Handles individual client connections.

  Each connection is a separate process managed by DynamicSupervisor.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Cortex.{Protocol, Store, ACL, Identity}

  # Max buffer size to prevent memory exhaustion (1MB)
  @max_buffer_size 1_048_576

  # Valid pattern for table/attribute names (alphanumeric + underscore, starts with letter/underscore)
  @valid_name_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  defstruct [:socket, :uid, :buffer]

  def start_link(socket) do
    GenServer.start_link(__MODULE__, socket)
  end

  @impl true
  def init(socket) do
    {:ok, %__MODULE__{socket: socket, uid: nil, buffer: <<>>}}
  end

  @impl true
  def handle_info(:start, state) do
    case Identity.get_uid(state.socket) do
      {:ok, uid} ->
        :inet.setopts(state.socket, [{:active, :once}])
        {:noreply, %{state | uid: uid}}

      {:error, reason} ->
        Logger.warning("Failed to get peer credentials: #{inspect(reason)}")
        {:stop, :no_credentials, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    # Check size before concatenating to avoid allocating oversized buffer
    next_size = byte_size(state.buffer) + byte_size(data)

    if next_size > @max_buffer_size do
      Logger.warning("Buffer overflow, disconnecting client")
      {:stop, :buffer_overflow, state}
    else
      buffer = state.buffer <> data

      case process_buffer(buffer, state.uid) do
        {:ok, response, rest} ->
          :gen_tcp.send(socket, response)
          :inet.setopts(socket, [{:active, :once}])
          {:noreply, %{state | buffer: rest}}

        {:incomplete, buffer} ->
          :inet.setopts(socket, [{:active, :once}])
          {:noreply, %{state | buffer: buffer}}

        {:error, reason} ->
          Logger.warning("Protocol error: #{inspect(reason)}")
          {:stop, :protocol_error, state}
      end
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("Socket error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  defp process_buffer(buffer, uid) do
    case Msgpax.unpack_slice(buffer) do
      {:ok, message, rest} ->
        response = handle_message(message, uid)
        {:ok, response, rest}

      {:error, %Msgpax.UnpackError{reason: :incomplete}} ->
        {:incomplete, buffer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_message([0, msgid, method, params], uid) do
    result = dispatch(method, params, uid)

    case result do
      {:ok, value} -> Protocol.encode_response(msgid, value)
      {:error, reason} -> Protocol.encode_error(msgid, reason)
      :ok -> Protocol.encode_response(msgid, "ok")
    end
  end

  defp handle_message(_invalid, _uid) do
    Protocol.encode_error(0, :invalid_request)
  end

  # Dispatch methods

  defp dispatch("ping", _params, _uid) do
    {:ok, "pong"}
  end

  defp dispatch("status", _params, _uid) do
    {:ok,
     %{
       version: Cortex.Version.version(),
       status: "running",
       node: node(),
       tables: :mnesia.system_info(:tables) |> length()
     }}
  end

  defp dispatch("tables", _params, uid) do
    tables = Store.tables(uid)
    {:ok, tables}
  end

  defp dispatch("create_table", [name, attributes], uid)
       when is_binary(name) and is_list(attributes) do
    # Validate table name format
    if not valid_name?(name) do
      {:error, "invalid table name: must be alphanumeric with underscores"}
    else
      # Validate and convert attribute names (prevents atom exhaustion)
      case validate_and_convert_attrs(attributes) do
        {:ok, attrs} ->
          case Store.create_table(uid, name, attrs) do
            {:ok, _table_name} -> {:ok, "created"}
            error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp dispatch("create_table", _params, _uid) do
    {:error, "invalid params: expected [name, [attributes]]"}
  end

  defp dispatch("drop_table", [name], uid) when is_binary(name) do
    table = Store.resolve_table(uid, name)

    with :ok <- ACL.authorize(uid, table, :drop_table),
         :ok <- Store.drop_table(uid, name) do
      {:ok, "dropped"}
    end
  end

  defp dispatch("put", [table_name, record], uid) when is_binary(table_name) and is_map(record) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :put),
         {:ok, :ok} <- Store.put(table, record) do
      {:ok, "ok"}
    end
  end

  defp dispatch("put", _params, _uid) do
    {:error, "invalid params: expected [table, record]"}
  end

  defp dispatch("get", [table_name, key], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :get) do
      Store.get(table, key)
    end
  end

  defp dispatch("delete", [table_name, key], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :delete),
         {:ok, :ok} <- Store.delete(table, key) do
      {:ok, "ok"}
    end
  end

  defp dispatch("match", [table_name, pattern], uid)
       when is_binary(table_name) and is_map(pattern) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :match) do
      Store.match(table, pattern)
    end
  end

  defp dispatch("all", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :all) do
      Store.all(table)
    end
  end

  defp dispatch("keys", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :all) do
      Store.keys(table)
    end
  end

  defp dispatch("acl_grant", [identity, table_name, perms], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :acl_grant),
         {:ok, perm_list} <- ACL.parse_permissions(perms),
         {:ok, :ok} <- Store.acl_grant(identity, table, perm_list) do
      {:ok, "granted"}
    end
  end

  defp dispatch("acl_revoke", [identity, table_name, perms], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :acl_revoke),
         {:ok, perm_list} <- ACL.parse_permissions(perms),
         {:ok, :ok} <- Store.acl_revoke(identity, table, perm_list) do
      {:ok, "revoked"}
    end
  end

  defp dispatch("acl_list", _params, uid) do
    case Store.acl_list(uid) do
      {:ok, acls} ->
        formatted =
          Enum.map(acls, fn {identity, table, perms} ->
            %{identity: identity, table: table, permissions: perms}
          end)

        {:ok, formatted}

      error ->
        error
    end
  end

  defp dispatch(method, _params, _uid) do
    {:error, "unknown method: #{method}"}
  end

  # Validate name format (alphanumeric + underscore, starts with letter/underscore)
  defp valid_name?(name) when is_binary(name) do
    Regex.match?(@valid_name_pattern, name)
  end

  # Validate and convert attribute names to atoms (prevents atom exhaustion)
  defp validate_and_convert_attrs(attributes) do
    result =
      Enum.reduce_while(attributes, [], fn attr, acc ->
        name =
          case attr do
            a when is_binary(a) -> a
            a when is_atom(a) -> Atom.to_string(a)
            _ -> nil
          end

        cond do
          name == nil ->
            {:halt, {:error, "invalid attribute type"}}

          not valid_name?(name) ->
            {:halt, {:error, "invalid attribute name: #{name}"}}

          true ->
            {:cont, [String.to_atom(name) | acc]}
        end
      end)

    case result do
      {:error, _} = error -> error
      attrs -> {:ok, Enum.reverse(attrs)}
    end
  end
end
