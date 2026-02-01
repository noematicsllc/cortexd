defmodule Cortex.CLI do
  @moduledoc """
  Command-line interface for Cortex.
  """

  alias Cortex.Client

  def main(args) do
    {opts, args, _} = OptionParser.parse(args, switches: [pretty: :boolean, help: :boolean])

    if opts[:help] do
      print_help()
    else
      result = run(args)
      output(result, opts[:pretty] || false)
    end
  end

  defp run(["ping"]) do
    Client.call("ping")
  end

  defp run(["status"]) do
    Client.call("status")
  end

  defp run(["tables"]) do
    Client.call("tables")
  end

  defp run(["create_table", name, attrs]) do
    attributes = String.split(attrs, ",") |> Enum.map(&String.trim/1)
    Client.call("create_table", [name, attributes])
  end

  defp run(["drop_table", name]) do
    Client.call("drop_table", [name])
  end

  defp run(["get", table, key]) do
    Client.call("get", [table, key])
  end

  defp run(["put", table, json]) do
    case Jason.decode(json) do
      {:ok, record} ->
        Client.call("put", [table, record])

      {:error, _} ->
        {:error, "invalid JSON"}
    end
  end

  defp run(["delete", table, key]) do
    Client.call("delete", [table, key])
  end

  defp run(["query", table, pattern_json]) do
    case Jason.decode(pattern_json) do
      {:ok, pattern} ->
        Client.call("match", [table, pattern])

      {:error, _} ->
        {:error, "invalid JSON pattern"}
    end
  end

  defp run(["all", table]) do
    Client.call("all", [table])
  end

  defp run(["acl", "grant", identity, table, perms]) do
    Client.call("acl_grant", [identity, table, perms])
  end

  defp run(["acl", "revoke", identity, table, perms]) do
    Client.call("acl_revoke", [identity, table, perms])
  end

  defp run(["acl", "list"]) do
    Client.call("acl_list", [])
  end

  defp run([]) do
    print_help()
    {:ok, nil}
  end

  defp run(_) do
    {:error, "unknown command, use --help for usage"}
  end

  defp output({:ok, nil}, _pretty), do: :ok

  defp output({:ok, result}, pretty) do
    json_opts = if pretty, do: [pretty: true], else: []
    IO.puts(Jason.encode!(result, json_opts))
  end

  defp output({:error, reason}, _pretty) do
    IO.puts(:stderr, "error: #{format_error(reason)}")
    System.halt(1)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp print_help do
    IO.puts("""
    cortex - Local storage daemon CLI

    USAGE:
      cortex <command> [args] [--pretty]

    COMMANDS:
      ping                          Health check
      status                        Daemon status
      tables                        List your tables

      create_table NAME ATTRS       Create table (ATTRS: comma-separated, first is key)
      drop_table NAME               Drop a table
      get TABLE KEY                 Get record by key
      put TABLE JSON                Insert/update record
      delete TABLE KEY              Delete record
      query TABLE PATTERN           Query by pattern (JSON)
      all TABLE                     List all records

      acl grant IDENTITY TABLE PERMS    Grant permissions
      acl revoke IDENTITY TABLE PERMS   Revoke permissions
      acl list                          List ACLs for your tables

    OPTIONS:
      --pretty                      Pretty-print JSON output
      --help                        Show this help

    EXAMPLES:
      cortex create_table users id,name,email
      cortex put users '{"id":"u1","name":"alice","email":"a@b.com"}'
      cortex get users u1
      cortex query users '{"name":"alice"}'
      cortex acl grant 'uid:1001' users read
      cortex acl grant '*' users read
    """)
  end
end
