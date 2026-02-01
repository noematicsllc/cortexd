defmodule Cortex.ACL do
  @moduledoc """
  Access control layer.

  Checks permissions before allowing operations on tables.
  """

  alias Cortex.Store
  alias Cortex.Identity

  @doc """
  Check if the given UID can perform an operation on a table.

  Operations:
  - :read - get, match, all
  - :write - put, delete
  - :admin - acl_grant, acl_revoke, drop_table
  """
  def authorize(uid, table_name, operation) do
    # Root (UID 0) bypasses all ACL checks. This enables:
    # - Admin backup/recovery of all data
    # - Auditing agent activity across all tables
    # - Emergency data access without per-table grants
    if uid == 0 do
      :ok
    else
      authorize_non_root(uid, table_name, operation)
    end
  end

  defp authorize_non_root(uid, table_name, operation) do
    identity = Identity.uid_to_identity(uid)

    # Check ownership first
    case Store.get_table_meta(table_name) do
      {:ok, %{owner: ^uid}} ->
        # Owner has full access
        :ok

      {:ok, _meta} ->
        # Not owner, check ACLs
        permission = operation_to_permission(operation)

        case Store.acl_check(identity, table_name, permission) do
          {:ok, true} -> :ok
          # Uniform error prevents table existence probing
          {:ok, false} -> {:error, :access_denied}
          error -> error
        end

      {:error, :not_found} ->
        # Same error as unauthorized - prevents probing for table existence
        {:error, :access_denied}

      error ->
        error
    end
  end

  @doc """
  Check if the given UID can create tables.
  Currently all users can create tables in their own namespace.
  """
  def can_create_table?(_uid), do: true

  @doc """
  Parse permission strings into atoms.
  """
  def parse_permissions(perms) when is_binary(perms) do
    perms
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
    |> validate_permissions()
  end

  def parse_permissions(perms) when is_list(perms) do
    perms
    |> Enum.map(fn
      p when is_binary(p) -> String.to_atom(p)
      p when is_atom(p) -> p
    end)
    |> validate_permissions()
  end

  defp validate_permissions(perms) do
    valid = [:read, :write, :admin]

    if Enum.all?(perms, &(&1 in valid)) do
      {:ok, perms}
    else
      {:error, :invalid_permissions}
    end
  end

  defp operation_to_permission(op) when op in [:get, :match, :all], do: :read
  defp operation_to_permission(op) when op in [:put, :delete], do: :write
  defp operation_to_permission(op) when op in [:acl_grant, :acl_revoke, :drop_table], do: :admin
  defp operation_to_permission(_), do: :read
end
