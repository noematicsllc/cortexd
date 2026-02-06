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

  defstruct [:socket, :uid, :transport, :node_id, :buffer]

  def start_link({socket, :tls}) do
    GenServer.start_link(__MODULE__, {socket, :tls})
  end

  def start_link(socket) do
    GenServer.start_link(__MODULE__, {socket, :unix})
  end

  @impl true
  def init({socket, transport}) do
    {:ok, %__MODULE__{socket: socket, uid: nil, transport: transport, node_id: nil, buffer: <<>>}}
  end

  @impl true
  def handle_info(:start, %{transport: :unix} = state) do
    case Identity.get_uid(state.socket) do
      {:ok, uid} ->
        :inet.setopts(state.socket, [{:active, :once}])
        {:noreply, %{state | uid: uid}}

      {:error, reason} ->
        Logger.warning("Failed to get peer credentials: #{inspect(reason)}")
        {:stop, :no_credentials, state}
    end
  end

  def handle_info(:start, %{transport: :tls} = state) do
    case Identity.get_node_cn(state.socket) do
      {:ok, cn} ->
        :ssl.setopts(state.socket, [{:active, :once}])
        {:noreply, %{state | node_id: cn}}

      {:error, reason} ->
        Logger.warning("Failed to get peer certificate CN: #{inspect(reason)}")
        {:stop, :no_certificate, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket, transport: :unix} = state) do
    handle_data(data, state)
  end

  def handle_info({:ssl, socket, data}, %{socket: socket, transport: :tls} = state) do
    handle_data(data, state)
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:ssl_closed, _socket}, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.warning("Socket error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info({:ssl_error, _socket, reason}, state) do
    Logger.warning("SSL error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  defp handle_data(data, state) do
    next_size = byte_size(state.buffer) + byte_size(data)

    if next_size > @max_buffer_size do
      Logger.warning("Buffer overflow, disconnecting client")
      {:stop, :buffer_overflow, state}
    else
      buffer = state.buffer <> data

      case process_buffer(buffer, state.uid) do
        {:ok, response, rest} ->
          send_data(state, response)
          set_active_once(state)
          {:noreply, %{state | buffer: rest}}

        {:incomplete, buffer} ->
          set_active_once(state)
          {:noreply, %{state | buffer: buffer}}

        {:error, reason} ->
          Logger.warning("Protocol error: #{inspect(reason)}")
          {:stop, :protocol_error, state}
      end
    end
  end

  defp send_data(%{transport: :unix, socket: socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data(%{transport: :tls, socket: socket}, data), do: :ssl.send(socket, data)

  defp set_active_once(%{transport: :unix, socket: socket}),
    do: :inet.setopts(socket, [{:active, :once}])

  defp set_active_once(%{transport: :tls, socket: socket}),
    do: :ssl.setopts(socket, [{:active, :once}])

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
    do_create_table(name, attributes, nil, uid)
  end

  defp dispatch("create_table", [name, attributes, scope], uid)
       when is_binary(name) and is_list(attributes) and is_binary(scope) do
    do_create_table(name, attributes, scope, uid)
  end

  defp dispatch("create_table", _params, _uid) do
    {:error, "invalid params: expected [name, [attributes]] or [name, [attributes], scope]"}
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

  # Scope methods

  defp dispatch("get_scope", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    case Store.get_table_meta(table) do
      {:ok, meta} -> {:ok, %{table: table_name, node_scope: meta.node_scope}}
      error -> error
    end
  end

  defp dispatch("set_scope", [table_name, scope_str], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :drop_table) do
      node_scope = parse_scope(scope_str)

      case Store.set_node_scope(table, node_scope) do
        {:ok, :ok} -> {:ok, "scope updated"}
        error -> error
      end
    end
  end

  defp dispatch("table_info", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :get) do
      case Store.get_table_meta(table) do
        {:ok, meta} ->
          {:ok,
           %{
             table: table_name,
             owner: meta.owner,
             key_field: meta.key_field,
             attributes: meta.attributes,
             node_scope: meta.node_scope
           }}

        error ->
          error
      end
    end
  end

  # Identity methods

  defp dispatch("identity_register", [name], uid) when is_binary(name) do
    mesh_config = Cortex.mesh_config()

    if mesh_config == nil do
      {:error, "mesh networking not configured"}
    else
      node_name = Keyword.fetch!(mesh_config, :node_name)

      case Store.register_identity(name, node_name, uid) do
        {:ok, :ok} ->
          case Cortex.Mesh.Token.generate(name, node_name, uid) do
            {:ok, token} -> {:ok, %{name: name, token: token}}
            error -> error
          end

        {:error, :already_exists} ->
          {:error, "identity '#{name}' already exists"}

        error ->
          error
      end
    end
  end

  defp dispatch("identity_claim", [token], uid) when is_binary(token) do
    mesh_config = Cortex.mesh_config()

    if mesh_config == nil do
      {:error, "mesh networking not configured"}
    else
      node_name = Keyword.fetch!(mesh_config, :node_name)

      case Cortex.Mesh.Token.verify(token) do
        {:ok, %{"fed_id" => fed_id}} ->
          case Store.claim_identity(fed_id, node_name, uid) do
            {:ok, :ok} -> {:ok, "claimed identity '#{fed_id}'"}
            {:error, :not_found} -> {:error, "identity '#{fed_id}' not found"}
            error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp dispatch("identity_list", _params, _uid) do
    Store.list_identities()
  end

  defp dispatch("identity_revoke", [name], uid) when is_binary(name) do
    with :ok <- authorize_identity_revoke(name, uid) do
      case Store.revoke_identity(name) do
        {:ok, :ok} -> {:ok, "revoked"}
        error -> error
      end
    end
  end

  defp dispatch("identity_revoke", [name, node_name], uid)
       when is_binary(name) and is_binary(node_name) do
    with :ok <- authorize_identity_revoke(name, uid) do
      case Store.revoke_identity(name, node_name) do
        {:ok, :ok} -> {:ok, "revoked"}
        error -> error
      end
    end
  end

  # Mesh info methods

  defp dispatch("mesh_list_nodes", _params, _uid) do
    case Cortex.mesh_config() do
      nil ->
        {:error, "mesh networking not configured"}

      config ->
        nodes = Keyword.get(config, :nodes, [])

        formatted =
          Enum.map(nodes, fn {name, host, port} ->
            %{name: name, host: host, port: port}
          end)

        {:ok, formatted}
    end
  end

  defp dispatch("mesh_status", _params, _uid) do
    case Cortex.mesh_config() do
      nil ->
        {:error, "mesh networking not configured"}

      config ->
        node_name = Keyword.get(config, :node_name, "unknown")
        nodes = Keyword.get(config, :nodes, [])
        connected = Node.list()

        status =
          Enum.map(nodes, fn {name, host, port} ->
            # Check if the Erlang node is connected
            erlang_node = String.to_atom("cortex@#{host}")
            connected? = erlang_node in connected

            %{name: name, host: host, port: port, connected: connected?}
          end)

        {:ok, %{node: node_name, peers: status}}
    end
  end

  # Sync methods

  defp dispatch("sync_status", _params, _uid) do
    {:ok, Cortex.Sync.status()}
  end

  defp dispatch("sync_status_table", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)
    {:ok, Cortex.Sync.status(table)}
  end

  defp dispatch("sync_repair", [table_name], uid) when is_binary(table_name) do
    table = Store.resolve_table(uid, table_name)

    with :ok <- ACL.authorize(uid, table, :drop_table) do
      Cortex.Sync.repair(table)
      {:ok, "repair initiated"}
    end
  end

  defp dispatch(method, _params, _uid) do
    {:error, "unknown method: #{method}"}
  end

  defp do_create_table(name, attributes, scope_str, uid) do
    if not valid_name?(name) do
      {:error, "invalid table name: must be alphanumeric with underscores"}
    else
      case validate_and_convert_attrs(attributes) do
        {:ok, attrs} ->
          opts = if scope_str, do: [node_scope: parse_scope(scope_str)], else: []

          case Store.create_table(uid, name, attrs, opts) do
            {:ok, _table_name} -> {:ok, "created"}
            error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_scope("local"), do: :local
  defp parse_scope("all"), do: :all
  defp parse_scope(nodes_str), do: String.split(nodes_str, ",") |> Enum.map(&String.trim/1)

  defp authorize_identity_revoke(_name, 0), do: :ok

  defp authorize_identity_revoke(name, uid) do
    mesh_config = Cortex.mesh_config()
    node_name = if mesh_config, do: Keyword.get(mesh_config, :node_name)

    case Store.lookup_federated(name) do
      {:ok, %{mappings: mappings}} ->
        if node_name && Map.get(mappings, node_name) == uid do
          :ok
        else
          {:error, "unauthorized: you do not own this identity"}
        end

      {:error, :not_found} ->
        {:error, "identity '#{name}' not found"}

      error ->
        error
    end
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
