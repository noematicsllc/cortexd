defmodule Cortex.Store do
  @moduledoc """
  Mnesia storage operations.

  Tables are namespaced by owner UID. Records are stored as {table, key, data} tuples.
  """

  use GenServer
  require Logger

  @acl_table :cortex_acls
  @meta_table :cortex_meta
  @identities_table :cortex_identities

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    setup_mnesia()
    {:ok, %{}}
  end

  defp setup_mnesia do
    # Ensure Mnesia application is loaded (but don't start it yet)
    case Application.load(:mnesia) do
      :ok -> :ok
      {:error, {:already_loaded, :mnesia}} -> :ok
    end

    # Configure directory before starting
    data_dir = Cortex.data_dir() |> String.to_charlist()
    Application.put_env(:mnesia, :dir, data_dir)

    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, reason} -> Logger.warning("Schema creation: #{inspect(reason)}")
    end

    case :mnesia.start() do
      :ok -> :ok
      {:error, {:already_started, :mnesia}} -> :ok
    end

    # System tables
    create_system_table(@acl_table, [:identity_table, :permissions])
    create_system_table(@meta_table, [:table_name, :owner, :key_field, :attributes, :node_scope])
    create_system_table(@identities_table, [:fed_id, :mappings, :metadata])

    Logger.info("Mnesia started, data dir: #{data_dir}")
  end

  defp create_system_table(name, attributes) do
    opts = [{:attributes, attributes}, {storage_type(), [node()]}]

    case :mnesia.create_table(name, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
      # Table exists with different storage type - that's fine, use it as-is
      {:aborted, {:bad_type, ^name, _type, _node}} -> :ok
      {:aborted, reason} -> Logger.error("Failed to create #{name}: #{inspect(reason)}")
    end
  end

  defp storage_type do
    # Use disc_copies only on named nodes; ram_copies for local dev/test
    if node() == :nonode@nohost do
      :ram_copies
    else
      :disc_copies
    end
  end

  # Public API

  def create_table(owner_uid, name, attributes, opts \\ [])
      when is_list(attributes) and length(attributes) > 0 do
    result =
      if String.starts_with?(name, "@") do
        # Federated table — resolve the @ namespace
        short = name |> String.trim_leading("@") |> String.split(":") |> List.last()
        fed_part = name |> String.trim_leading("@")

        if String.contains?(fed_part, ":") do
          # Fully-qualified: verify the caller owns this fed_id
          [claimed_fed_id | _] = String.split(fed_part, ":")

          case resolve_caller_fed_id(owner_uid, Keyword.get(opts, :node_name)) do
            {:ok, ^claimed_fed_id} ->
              {:ok, {String.to_atom("@#{fed_part}"), :all}}

            {:ok, _other} ->
              {:error, :unauthorized}

            :error ->
              {:error, :federated_identity_required}
          end
        else
          case resolve_caller_fed_id(owner_uid, Keyword.get(opts, :node_name)) do
            {:ok, fed_id} ->
              {:ok, {String.to_atom("@#{fed_id}:#{short}"), :all}}

            :error ->
              {:error, :federated_identity_required}
          end
        end
      else
        {:ok, {namespaced_table(owner_uid, name), :local}}
      end

    case result do
      {:error, reason} ->
        {:error, reason}

      {:ok, {table_name, default_scope}} ->

    key_field = hd(attributes)
    node_scope = Keyword.get(opts, :node_scope, default_scope)

    mnesia_opts = [{:attributes, [:key, :data]}, {storage_type(), [node()]}]

    case :mnesia.create_table(table_name, mnesia_opts) do
      {:atomic, :ok} ->
        # Store metadata (6-element record with node_scope)
        :mnesia.transaction(fn ->
          :mnesia.write({@meta_table, table_name, owner_uid, key_field, attributes, node_scope})
          # Owner gets full access
          :mnesia.write(
            {@acl_table, {uid_identity(owner_uid), table_name}, [:read, :write, :admin]}
          )
        end)

        {:ok, table_name}

      {:aborted, {:already_exists, ^table_name}} ->
        {:error, :already_exists}

      {:aborted, reason} ->
        {:error, reason}
    end
    end
  end

  def drop_table(owner_uid, name) do
    table_name = namespaced_table(owner_uid, name)

    # Clean up metadata and ACLs BEFORE deleting table to avoid race conditions.
    # This ensures no orphaned ACLs can persist if a grant happens mid-deletion.
    :mnesia.transaction(fn ->
      :mnesia.delete({@meta_table, table_name})

      :mnesia.match_object({@acl_table, {:_, table_name}, :_})
      |> Enum.each(fn {_, key, _} -> :mnesia.delete({@acl_table, key}) end)
    end)

    case :mnesia.delete_table(table_name) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:no_exists, ^table_name}} ->
        {:error, :not_found}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  def put(table_name, record) when is_map(record) do
    case get_table_meta(table_name) do
      {:ok, meta} ->
        key_field = Atom.to_string(meta.key_field)

        case Map.get(record, key_field) || Map.get(record, String.to_atom(key_field)) do
          nil ->
            {:error, :missing_key}

          key ->
            key_str = stringify(key)

            :mnesia.transaction(fn ->
              :mnesia.write({table_name, key_str, record})
            end)
            |> transaction_result()
        end

      error ->
        error
    end
  end

  def get(table_name, key) do
    key_str = stringify(key)

    case :mnesia.transaction(fn -> :mnesia.read({table_name, key_str}) end) do
      {:atomic, [{^table_name, ^key_str, data}]} -> {:ok, data}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  def delete(table_name, key) do
    key_str = stringify(key)

    :mnesia.transaction(fn ->
      :mnesia.delete({table_name, key_str})
    end)
    |> transaction_result()
  end

  def match(table_name, pattern) when is_map(pattern) do
    :mnesia.transaction(fn ->
      :mnesia.match_object({table_name, :_, :_})
      |> Enum.filter(fn {_, _, data} -> map_matches?(data, pattern) end)
      |> Enum.map(fn {_, _, data} -> data end)
    end)
    |> transaction_result()
  end

  def all(table_name) do
    :mnesia.transaction(fn ->
      :mnesia.match_object({table_name, :_, :_})
      |> Enum.map(fn {_, _, data} -> data end)
    end)
    |> transaction_result()
  end

  def keys(table_name) do
    :mnesia.transaction(fn ->
      :mnesia.all_keys(table_name)
    end)
    |> transaction_result()
  end

  def tables(owner_uid) do
    uid_prefix = "#{owner_uid}:"

    local_tables =
      :mnesia.system_info(:tables)
      |> Enum.filter(fn table ->
        name = Atom.to_string(table)
        String.starts_with?(name, uid_prefix)
      end)
      |> Enum.map(fn table ->
        name = Atom.to_string(table)
        String.replace_prefix(name, uid_prefix, "")
      end)

    # Also include federated tables owned by this user's federated identity
    fed_tables =
      case resolve_caller_fed_id(owner_uid, nil) do
        {:ok, fed_id} ->
          fed_prefix = "@#{fed_id}:"

          :mnesia.system_info(:tables)
          |> Enum.filter(fn table ->
            Atom.to_string(table) |> String.starts_with?(fed_prefix)
          end)
          |> Enum.map(fn table ->
            Atom.to_string(table)
          end)

        :error ->
          []
      end

    local_tables ++ fed_tables
  end

  def tables_accessible_by(uid) do
    identity = uid_identity(uid)

    # Get tables owned by this UID
    owned = tables(uid) |> Enum.map(&{&1, uid})

    # Get tables granted via ACL
    granted =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@acl_table, {identity, :_}, :_})
        |> Enum.map(fn {_, {_, table_name}, _perms} ->
          case get_table_meta(table_name) do
            {:ok, meta} ->
              short_name = table_name |> Atom.to_string() |> String.replace(~r/^\d+:/, "")
              {short_name, meta.owner}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> transaction_result()
      |> case do
        {:ok, list} -> list
        _ -> []
      end

    # Get world-readable tables
    world =
      :mnesia.transaction(fn ->
        :mnesia.match_object({@acl_table, {"*", :_}, :_})
        |> Enum.map(fn {_, {_, table_name}, _perms} ->
          case get_table_meta(table_name) do
            {:ok, meta} ->
              short_name = table_name |> Atom.to_string() |> String.replace(~r/^\d+:/, "")
              {short_name, meta.owner}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)
      |> transaction_result()
      |> case do
        {:ok, list} -> list
        _ -> []
      end

    (owned ++ granted ++ world) |> Enum.uniq()
  end

  # ACL operations

  def acl_grant(identity, table_name, permissions) when is_list(permissions) do
    :mnesia.transaction(fn ->
      key = {identity, table_name}

      existing =
        case :mnesia.read({@acl_table, key}) do
          [{@acl_table, ^key, perms}] -> perms
          [] -> []
        end

      merged = Enum.uniq(existing ++ permissions)
      :mnesia.write({@acl_table, key, merged})
    end)
    |> transaction_result()
  end

  def acl_revoke(identity, table_name, permissions) when is_list(permissions) do
    :mnesia.transaction(fn ->
      key = {identity, table_name}

      case :mnesia.read({@acl_table, key}) do
        [{@acl_table, ^key, existing}] ->
          remaining = existing -- permissions

          if remaining == [] do
            :mnesia.delete({@acl_table, key})
          else
            :mnesia.write({@acl_table, key, remaining})
          end

        [] ->
          :ok
      end
    end)
    |> transaction_result()
  end

  def acl_check(identity, table_name, permission) do
    :mnesia.transaction(fn ->
      # Check specific identity
      case :mnesia.read({@acl_table, {identity, table_name}}) do
        [{@acl_table, _, perms}] when is_list(perms) ->
          permission in perms

        [] ->
          # Check world access
          case :mnesia.read({@acl_table, {"*", table_name}}) do
            [{@acl_table, _, perms}] when is_list(perms) ->
              permission in perms

            [] ->
              false
          end
      end
    end)
    |> transaction_result()
  end

  def acl_list(owner_uid) do
    :mnesia.transaction(fn ->
      # Get ACLs for tables owned by this user
      :mnesia.foldl(
        fn {_, {id, table}, perms}, acc ->
          case get_table_meta(table) do
            {:ok, %{owner: ^owner_uid}} ->
              [{id, Atom.to_string(table), perms} | acc]

            _ ->
              acc
          end
        end,
        [],
        @acl_table
      )
    end)
    |> transaction_result()
  end

  # Node scope operations

  def set_node_scope(table_name, node_scope) when is_atom(table_name) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read({@meta_table, table_name}) do
          [{@meta_table, ^table_name, owner, key_field, attributes, _old_scope}] ->
            :mnesia.write({@meta_table, table_name, owner, key_field, attributes, node_scope})

          # Backward compat: 5-element record
          [{@meta_table, ^table_name, owner, key_field, attributes}] ->
            :mnesia.write({@meta_table, table_name, owner, key_field, attributes, node_scope})

          [] ->
            :mnesia.abort(:not_found)
        end
      end)
      |> transaction_result()

    # Trigger replication changes
    case result do
      {:ok, :ok} ->
        case Cortex.Sync.apply_node_scope(table_name) do
          :ok -> result
          {:error, reason} ->
            Logger.warning("Scope updated but replication failed: #{inspect(reason)}")
            {:error, {:replication_failed, reason}}
        end

      _ ->
        result
    end
  end

  # Federated identity operations

  def register_identity(fed_id, node_name, uid) do
    :mnesia.transaction(fn ->
      case :mnesia.read({@identities_table, fed_id}) do
        [] ->
          mappings = %{node_name => uid}
          metadata = %{created_at: DateTime.utc_now() |> DateTime.to_iso8601(), created_by: node_name}
          :mnesia.write({@identities_table, fed_id, mappings, metadata})

        _ ->
          :mnesia.abort(:already_exists)
      end
    end)
    |> transaction_result()
  end

  def claim_identity(fed_id, node_name, uid) do
    :mnesia.transaction(fn ->
      case :mnesia.read({@identities_table, fed_id}) do
        [{@identities_table, ^fed_id, mappings, metadata}] ->
          updated_mappings = Map.put(mappings, node_name, uid)
          :mnesia.write({@identities_table, fed_id, updated_mappings, metadata})

        [] ->
          :mnesia.abort(:not_found)
      end
    end)
    |> transaction_result()
  end

  def lookup_federated(fed_id) do
    case :mnesia.transaction(fn -> :mnesia.read({@identities_table, fed_id}) end) do
      {:atomic, [{@identities_table, ^fed_id, mappings, metadata}]} ->
        {:ok, %{fed_id: fed_id, mappings: mappings, metadata: metadata}}

      {:atomic, []} ->
        {:error, :not_found}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  def lookup_federated_by_local(node_name, uid) do
    :mnesia.transaction(fn ->
      :mnesia.foldl(
        fn {_, fed_id, mappings, _}, acc ->
          if Map.get(mappings, node_name) == uid do
            [fed_id | acc]
          else
            acc
          end
        end,
        [],
        @identities_table
      )
    end)
    |> case do
      {:atomic, [fed_id | _]} -> {:ok, fed_id}
      {:atomic, []} -> {:error, :not_found}
      {:aborted, reason} -> {:error, reason}
    end
  end

  def list_identities do
    :mnesia.transaction(fn ->
      :mnesia.foldl(
        fn {_, fed_id, mappings, metadata}, acc ->
          [%{fed_id: fed_id, mappings: mappings, metadata: metadata} | acc]
        end,
        [],
        @identities_table
      )
    end)
    |> transaction_result()
  end

  def revoke_identity(fed_id, node_name \\ nil) do
    :mnesia.transaction(fn ->
      case :mnesia.read({@identities_table, fed_id}) do
        [{@identities_table, ^fed_id, mappings, metadata}] ->
          if node_name do
            updated = Map.delete(mappings, node_name)

            if map_size(updated) == 0 do
              :mnesia.delete({@identities_table, fed_id})
            else
              :mnesia.write({@identities_table, fed_id, updated, metadata})
            end
          else
            :mnesia.delete({@identities_table, fed_id})
          end

        [] ->
          :mnesia.abort(:not_found)
      end
    end)
    |> transaction_result()
  end

  # Helpers

  def resolve_table(uid, name, opts \\ []) do
    node_name = Keyword.get(opts, :node_name)

    table_str =
      cond do
        # Fully qualified federated name (e.g., "@alice:memories")
        String.starts_with?(name, "@") and String.contains?(name, ":") ->
          name

        # Short federated name (e.g., "@memories") — resolve to caller's federated identity
        String.starts_with?(name, "@") ->
          short = String.trim_leading(name, "@")

          case resolve_caller_fed_id(uid, node_name) do
            {:ok, fed_id} -> "@#{fed_id}:#{short}"
            :error -> name
          end

        # Fully qualified local name (e.g., "1000:users")
        String.contains?(name, ":") ->
          name

        # Short local name — use caller's UID namespace
        true ->
          "#{uid}:#{name}"
      end

    # Use existing atom to prevent atom exhaustion from probing non-existent tables
    try do
      String.to_existing_atom(table_str)
    rescue
      ArgumentError -> :table_does_not_exist
    end
  end

  defp resolve_caller_fed_id(uid, node_name) do
    if node_name do
      case lookup_federated_by_local(node_name, uid) do
        {:ok, fed_id} -> {:ok, fed_id}
        _ -> :error
      end
    else
      # Local connection — check if this UID has a federated identity on this node
      this_node = node_name_from_config()

      if this_node do
        case lookup_federated_by_local(this_node, uid) do
          {:ok, fed_id} -> {:ok, fed_id}
          _ -> :error
        end
      else
        :error
      end
    end
  end

  defp node_name_from_config do
    case Cortex.mesh_config() do
      nil -> nil
      config -> Keyword.get(config, :node_name)
    end
  end

  def get_table_meta(table_name) when is_atom(table_name) do
    case :mnesia.transaction(fn -> :mnesia.read({@meta_table, table_name}) end) do
      # 6-element record (with node_scope)
      {:atomic, [{@meta_table, ^table_name, owner, key_field, attributes, node_scope}]} ->
        {:ok, %{owner: owner, key_field: key_field, attributes: attributes, node_scope: node_scope}}

      # 5-element record (pre-mesh, backward compatible — treat as :local)
      {:atomic, [{@meta_table, ^table_name, owner, key_field, attributes}]} ->
        {:ok, %{owner: owner, key_field: key_field, attributes: attributes, node_scope: :local}}

      {:atomic, []} ->
        {:error, :not_found}

      {:aborted, reason} ->
        {:error, reason}
    end
  end

  defp namespaced_table(uid, name) do
    String.to_atom("#{uid}:#{name}")
  end

  defp uid_identity(uid), do: "uid:#{uid}"

  defp transaction_result({:atomic, result}), do: {:ok, result}
  defp transaction_result({:aborted, reason}), do: {:error, reason}

  defp map_matches?(data, pattern) when is_map(data) and is_map(pattern) do
    Enum.all?(pattern, fn {key, value} ->
      data_value = Map.get(data, key) || Map.get(data, stringify(key))
      value_matches?(data_value, value)
    end)
  end

  # Exact match
  defp value_matches?(data_value, pattern_value) when data_value == pattern_value, do: true
  # Array containment: if data is a list and pattern is scalar, check membership
  defp value_matches?(data_value, pattern_value)
       when is_list(data_value) and not is_list(pattern_value) do
    Enum.member?(data_value, pattern_value)
  end

  defp value_matches?(_, _), do: false

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value), do: "#{value}"
end
