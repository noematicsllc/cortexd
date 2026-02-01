defmodule Cortex.Store do
  @moduledoc """
  Mnesia storage operations.

  Tables are namespaced by owner UID. Records are stored as {table, key, data} tuples.
  """

  use GenServer
  require Logger

  @acl_table :cortex_acls
  @meta_table :cortex_meta

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

    :ok = :mnesia.start()

    # System tables
    create_system_table(@acl_table, [:identity_table, :permissions])
    create_system_table(@meta_table, [:table_name, :owner, :key_field, :attributes])

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

  def create_table(owner_uid, name, attributes)
      when is_list(attributes) and length(attributes) > 0 do
    table_name = namespaced_table(owner_uid, name)
    key_field = hd(attributes)

    opts = [{:attributes, [:key, :data]}, {storage_type(), [node()]}]

    case :mnesia.create_table(table_name, opts) do
      {:atomic, :ok} ->
        # Store metadata
        :mnesia.transaction(fn ->
          :mnesia.write({@meta_table, table_name, owner_uid, key_field, attributes})
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

  def drop_table(owner_uid, name) do
    table_name = namespaced_table(owner_uid, name)

    case :mnesia.delete_table(table_name) do
      {:atomic, :ok} ->
        # Clean up metadata and ACLs
        :mnesia.transaction(fn ->
          :mnesia.delete({@meta_table, table_name})
          # Delete all ACLs for this table
          :mnesia.match_object({@acl_table, {:_, table_name}, :_})
          |> Enum.each(fn {_, key, _} -> :mnesia.delete({@acl_table, key}) end)
        end)

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

  def tables(owner_uid) do
    prefix = "#{owner_uid}:"

    :mnesia.system_info(:tables)
    |> Enum.filter(fn table ->
      name = Atom.to_string(table)
      String.starts_with?(name, prefix)
    end)
    |> Enum.map(fn table ->
      name = Atom.to_string(table)
      String.replace_prefix(name, prefix, "")
    end)
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

  # Helpers

  def resolve_table(uid, name) do
    cond do
      # Fully qualified name (e.g., "1000:users")
      String.contains?(name, ":") ->
        String.to_atom(name)

      # Short name - use caller's namespace
      true ->
        namespaced_table(uid, name)
    end
  end

  def get_table_meta(table_name) when is_atom(table_name) do
    case :mnesia.transaction(fn -> :mnesia.read({@meta_table, table_name}) end) do
      {:atomic, [{@meta_table, ^table_name, owner, key_field, attributes}]} ->
        {:ok, %{owner: owner, key_field: key_field, attributes: attributes}}

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
      data_value == value
    end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value), do: "#{value}"
end
