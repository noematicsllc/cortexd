defmodule Cortex.CLI do
  @moduledoc """
  Command-line interface for Cortex.
  """

  alias Cortex.Client

  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args, switches: [pretty: :boolean, help: :boolean, version: :boolean])

    cond do
      # Version flag
      opts[:version] == true ->
        IO.puts("cortex #{Cortex.Version.version()}")

      # Global help
      opts[:help] == true and args == [] ->
        print_help()

      # Per-command help: cortex <command> --help
      opts[:help] == true ->
        print_command_help(args)

      # Help command: cortex help [topic]
      match?(["help" | _], args) ->
        print_command_help(tl(args))

      # Normal execution
      true ->
        result = run(args)
        output(result, opts[:pretty] || false)
    end
  end

  # ============================================================================
  # Command Execution
  # ============================================================================

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

  # ============================================================================
  # Per-Command Help
  # ============================================================================

  defp print_command_help([]) do
    print_help()
  end

  defp print_command_help(["ping"]) do
    IO.puts("""
    cortex ping - Health check

    USAGE:
      cortex ping

    DESCRIPTION:
      Tests connectivity to the Cortex daemon. Returns "pong" if the daemon
      is running and responsive.

    EXAMPLES:
      cortex ping
      # Output: "pong"

    SEE ALSO:
      cortex status --help
    """)
  end

  defp print_command_help(["status"]) do
    IO.puts("""
    cortex status - Daemon status

    USAGE:
      cortex status [--pretty]

    DESCRIPTION:
      Returns detailed status information about the Cortex daemon including
      version, uptime, and Mnesia database state.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    EXAMPLES:
      cortex status
      cortex status --pretty

    SEE ALSO:
      cortex ping --help
    """)
  end

  defp print_command_help(["tables"]) do
    IO.puts("""
    cortex tables - List your tables

    USAGE:
      cortex tables [--pretty]

    DESCRIPTION:
      Lists all tables owned by the current user (based on UID). Tables are
      automatically namespaced by your UID internally.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    EXAMPLES:
      cortex tables
      cortex tables --pretty
      # Output: ["users", "sessions", "config"]

    SEE ALSO:
      cortex create_table --help
      cortex drop_table --help
    """)
  end

  defp print_command_help(["create_table"]) do
    IO.puts("""
    cortex create_table - Create a new table

    USAGE:
      cortex create_table NAME ATTRS

    ARGUMENTS:
      NAME    Table name (will be namespaced to your UID automatically)
      ATTRS   Comma-separated attribute names; first attribute is the primary key

    DESCRIPTION:
      Creates a new Mnesia table owned by you. The first attribute becomes
      the primary key for get/delete operations. Other attributes are for
      documentation only - Cortex stores arbitrary JSON in each record.

      Tables are automatically prefixed with your UID (e.g., "users" becomes
      "1000:users" internally) to prevent naming conflicts between users.

    EXAMPLES:
      cortex create_table users id,name,email
      cortex create_table sessions session_id,user_id,expires
      cortex create_table config key,value

    SEE ALSO:
      cortex drop_table --help
      cortex put --help
      cortex help patterns
    """)
  end

  defp print_command_help(["drop_table"]) do
    IO.puts("""
    cortex drop_table - Drop a table

    USAGE:
      cortex drop_table NAME

    ARGUMENTS:
      NAME    Table name to drop

    DESCRIPTION:
      Permanently deletes a table and all its data. You must have admin
      permission on the table (owner has this by default).

      WARNING: This operation cannot be undone.

    EXAMPLES:
      cortex drop_table old_sessions
      cortex drop_table temp_data

    SEE ALSO:
      cortex create_table --help
      cortex tables --help
    """)
  end

  defp print_command_help(["get"]) do
    IO.puts("""
    cortex get - Get a record by key

    USAGE:
      cortex get TABLE KEY [--pretty]

    ARGUMENTS:
      TABLE   Table name
      KEY     Primary key value

    DESCRIPTION:
      Retrieves a single record by its primary key. Returns the full JSON
      record if found, or null if not found.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    EXAMPLES:
      cortex get users u1
      cortex get config database_url --pretty

    SEE ALSO:
      cortex put --help
      cortex query --help
      cortex all --help
    """)
  end

  defp print_command_help(["put"]) do
    IO.puts("""
    cortex put - Insert or update a record

    USAGE:
      cortex put TABLE JSON

    ARGUMENTS:
      TABLE   Table name
      JSON    Record as JSON object (must include the primary key field)

    DESCRIPTION:
      Inserts a new record or updates an existing one. The JSON must contain
      the primary key field defined when the table was created. If a record
      with that key exists, it will be completely replaced.

    EXAMPLES:
      cortex put users '{"id":"u1","name":"alice","email":"a@example.com"}'
      cortex put config '{"key":"theme","value":"dark"}'

      # Update existing record (replaces entirely)
      cortex put users '{"id":"u1","name":"alice","email":"new@example.com"}'

    SEE ALSO:
      cortex get --help
      cortex delete --help
      cortex create_table --help
    """)
  end

  defp print_command_help(["delete"]) do
    IO.puts("""
    cortex delete - Delete a record

    USAGE:
      cortex delete TABLE KEY

    ARGUMENTS:
      TABLE   Table name
      KEY     Primary key of record to delete

    DESCRIPTION:
      Permanently deletes a single record by its primary key. Returns "ok"
      whether or not the record existed.

    EXAMPLES:
      cortex delete users u1
      cortex delete sessions expired_session_123

    SEE ALSO:
      cortex get --help
      cortex put --help
      cortex drop_table --help
    """)
  end

  defp print_command_help(["query"]) do
    IO.puts("""
    cortex query - Query records by pattern

    USAGE:
      cortex query TABLE PATTERN [--pretty]

    ARGUMENTS:
      TABLE     Table name
      PATTERN   JSON object with fields to match

    DESCRIPTION:
      Finds all records matching the given pattern. The pattern is a JSON
      object where each field must match exactly. Records may have additional
      fields not in the pattern.

      Note: Queries scan the entire table (no secondary indexes in v1).
      For large tables, consider using get with known keys when possible.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    EXAMPLES:
      # Find all users named "alice"
      cortex query users '{"name":"alice"}' --pretty

      # Find all sessions for a user
      cortex query sessions '{"user_id":"u1"}'

      # Match multiple fields
      cortex query users '{"role":"admin","active":true}'

    SEE ALSO:
      cortex get --help
      cortex all --help
    """)
  end

  defp print_command_help(["all"]) do
    IO.puts("""
    cortex all - List all records in a table

    USAGE:
      cortex all TABLE [--pretty]

    ARGUMENTS:
      TABLE   Table name

    DESCRIPTION:
      Returns all records in a table as a JSON array. Use with caution on
      large tables.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    EXAMPLES:
      cortex all users --pretty
      cortex all config

    SEE ALSO:
      cortex query --help
      cortex get --help
      cortex tables --help
    """)
  end

  defp print_command_help(["acl"]) do
    IO.puts("""
    cortex acl - Access control commands

    USAGE:
      cortex acl <subcommand> [args]

    SUBCOMMANDS:
      grant IDENTITY TABLE PERMS    Grant permissions
      revoke IDENTITY TABLE PERMS   Revoke permissions
      list                          List ACLs for your tables

    DESCRIPTION:
      Manage access control lists for your tables. By default, only you (the
      table owner) have access. Use ACLs to share tables with other users.

    IDENTITIES:
      uid:1001    Specific user by UID
      *           World (any authenticated user)

    PERMISSIONS:
      read        Can get, query, all
      write       Can put, delete
      admin       Can grant/revoke ACLs, drop table

    EXAMPLES:
      cortex acl grant 'uid:1001' users read
      cortex acl grant '*' public_data read
      cortex acl revoke 'uid:1001' users write
      cortex acl list --pretty

    SEE ALSO:
      cortex acl grant --help
      cortex acl revoke --help
      cortex help identities
    """)
  end

  defp print_command_help(["acl", "grant"]) do
    IO.puts("""
    cortex acl grant - Grant permissions

    USAGE:
      cortex acl grant IDENTITY TABLE PERMS

    ARGUMENTS:
      IDENTITY    Who to grant access to (uid:NUMBER or * for world)
      TABLE       Table name
      PERMS       Comma-separated permissions: read,write,admin

    DESCRIPTION:
      Grants permissions on a table to another identity. You must have admin
      permission on the table (owners have this by default).

    IDENTITIES:
      uid:1001    Grant to specific user by UID
      *           Grant to world (any authenticated local user)

    PERMISSIONS:
      read        Can get, query, all
      write       Can put, delete (implies read)
      admin       Can grant/revoke ACLs, drop table (implies read,write)

    EXAMPLES:
      # Let user 1001 read your users table
      cortex acl grant 'uid:1001' users read

      # Make a table world-readable
      cortex acl grant '*' public_data read

      # Give full access to another user
      cortex acl grant 'uid:1001' shared_project read,write

    SEE ALSO:
      cortex acl revoke --help
      cortex acl list --help
      cortex help identities
    """)
  end

  defp print_command_help(["acl", "revoke"]) do
    IO.puts("""
    cortex acl revoke - Revoke permissions

    USAGE:
      cortex acl revoke IDENTITY TABLE PERMS

    ARGUMENTS:
      IDENTITY    Who to revoke access from
      TABLE       Table name
      PERMS       Comma-separated permissions to revoke

    DESCRIPTION:
      Removes previously granted permissions. You must have admin permission
      on the table.

    EXAMPLES:
      cortex acl revoke 'uid:1001' users write
      cortex acl revoke '*' public_data read

    SEE ALSO:
      cortex acl grant --help
      cortex acl list --help
    """)
  end

  defp print_command_help(["acl", "list"]) do
    IO.puts("""
    cortex acl list - List ACLs

    USAGE:
      cortex acl list [--pretty]

    DESCRIPTION:
      Lists all access control entries for tables you own. Shows which
      identities have which permissions on each table.

    OPTIONS:
      --pretty    Pretty-print the JSON output

    OUTPUT FORMAT:
      [
        {"table": "1000:users", "identity": "uid:1001", "permissions": ["read"]},
        {"table": "1000:public", "identity": "*", "permissions": ["read"]}
      ]

    EXAMPLES:
      cortex acl list
      cortex acl list --pretty

    SEE ALSO:
      cortex acl grant --help
      cortex acl revoke --help
    """)
  end

  # ============================================================================
  # Pattern Help (Usage Patterns)
  # ============================================================================

  defp print_command_help(["patterns"]) do
    IO.puts("""
    Cortex Usage Patterns

    Cortex is a generic storage layer - it has no opinions about how you
    structure your data. Here are common patterns that work well:

    AVAILABLE PATTERNS:
      cortex help memories       Public/private agent memories
      cortex help statemachine   Workflow state machines
      cortex help identities     Agent identity via Unix users

    Run 'cortex help <pattern>' for detailed documentation.
    """)
  end

  defp print_command_help(["memories"]) do
    IO.puts("""
    Pattern: Public/Private Agent Memories

    OVERVIEW:
      AI agents often need both private working memory and shared knowledge.
      Use separate tables with different ACLs to implement this pattern.

    SETUP:
      # Create private memory (only you can access)
      cortex create_table private_memories id,content,timestamp,tags

      # Create public memory (world-readable)
      cortex create_table public_memories id,content,timestamp,tags
      cortex acl grant '*' public_memories read

    PRIVATE MEMORIES:
      Store internal state, reasoning traces, sensitive data:

      cortex put private_memories '{
        "id": "thought-001",
        "content": "User seems frustrated, should be more concise",
        "timestamp": "2026-02-01T10:30:00Z",
        "tags": ["meta", "interaction"]
      }'

    PUBLIC MEMORIES:
      Share knowledge with other agents or users:

      cortex put public_memories '{
        "id": "fact-001",
        "content": "The API rate limit is 100 requests/minute",
        "timestamp": "2026-02-01T09:00:00Z",
        "tags": ["api", "limits"]
      }'

    QUERYING:
      # Find memories by tag
      cortex query public_memories '{"tags":["api"]}' --pretty

      # All private thoughts
      cortex all private_memories --pretty

    MULTI-AGENT SETUP:
      Each agent runs as a separate Unix user with its own UID:

      sudo useradd -r -s /usr/sbin/nologin agent-researcher
      sudo useradd -r -s /usr/sbin/nologin agent-coder

      Each agent's tables are isolated. They can only read each other's
      public_memories tables (if world-readable ACL is set).

    SEE ALSO:
      cortex help identities
      cortex help statemachine
    """)
  end

  defp print_command_help(["statemachine"]) do
    IO.puts("""
    Pattern: Workflow State Machines

    OVERVIEW:
      Track multi-step workflows with explicit states and transitions.
      Useful for task management, approval flows, or any process with
      defined stages.

    SETUP:
      # Table for state machine definitions (schemas)
      cortex create_table sm_definitions id,name,states,transitions

      # Table for workflow instances
      cortex create_table sm_instances id,definition,state,data,created,updated

    DEFINE A WORKFLOW:
      cortex put sm_definitions '{
        "id": "task-workflow",
        "name": "Task Workflow",
        "states": ["todo", "in_progress", "review", "done"],
        "transitions": {
          "todo": ["in_progress"],
          "in_progress": ["review", "todo"],
          "review": ["done", "in_progress"],
          "done": []
        }
      }'

    CREATE INSTANCES:
      cortex put sm_instances '{
        "id": "task-001",
        "definition": "task-workflow",
        "state": "todo",
        "data": {"title": "Implement feature X", "assignee": "alice"},
        "created": "2026-02-01",
        "updated": "2026-02-01"
      }'

    TRANSITION STATE:
      # Move to in_progress (update the record)
      cortex put sm_instances '{
        "id": "task-001",
        "definition": "task-workflow",
        "state": "in_progress",
        "data": {"title": "Implement feature X", "assignee": "alice"},
        "created": "2026-02-01",
        "updated": "2026-02-01"
      }'

    QUERY BY STATE:
      # Find all tasks in review
      cortex query sm_instances '{"state":"review"}' --pretty

      # Find all tasks for a specific workflow
      cortex query sm_instances '{"definition":"task-workflow"}' --pretty

    VALIDATION:
      Cortex doesn't enforce transitions - your application code should
      validate that transitions are allowed based on the definition.

    SEE ALSO:
      cortex help memories
      cortex help identities
    """)
  end

  defp print_command_help(["identities"]) do
    IO.puts("""
    Pattern: Agent Identities

    OVERVIEW:
      Cortex identifies users by their Unix UID, extracted from the socket
      connection via SO_PEERCRED. This provides kernel-enforced identity
      that cannot be spoofed by local processes.

    HOW IT WORKS:
      1. Client connects to Unix socket at /run/cortex/cortex.sock
      2. Cortex extracts UID via getpeereid/SO_PEERCRED (kernel-enforced)
      3. All operations are scoped to that UID
      4. Tables are namespaced: "users" becomes "1000:users" internally

    CREATING AGENT USERS:
      Each AI agent should run as a dedicated system user:

      # Create agent user (no login shell, no home needed)
      sudo useradd -r -s /usr/sbin/nologin agent-coder

      # Run agent as that user
      sudo -u agent-coder some-agent-command

      # Or in a service file
      [Service]
      User=agent-coder
      ExecStart=/usr/bin/agent-coder

    BENEFITS:
      - Automatic isolation: agents can't access each other's private data
      - No tokens/passwords: identity is kernel-enforced
      - Audit trail: Unix user = Cortex identity
      - Standard tooling: useradd, sudo, systemd all work naturally

    FINDING YOUR UID:
      id -u                    # Your current UID
      id -u agent-coder        # Another user's UID

    SHARING DATA:
      Use ACLs to share between agents:

      # Agent A makes data readable by Agent B (uid 1002)
      cortex acl grant 'uid:1002' shared_data read

      # Or world-readable for all local agents
      cortex acl grant '*' public_knowledge read

    SECURITY MODEL:
      - Local only (Unix socket, no network in v1)
      - Any local user can connect (socket mode 0666)
      - But they can only access their own tables + ACL grants
      - Root (uid 0) has no special privileges in Cortex

    SEE ALSO:
      cortex help memories
      cortex acl grant --help
    """)
  end

  defp print_command_help(unknown) do
    cmd = Enum.join(unknown, " ")

    IO.puts("""
    Unknown help topic: #{cmd}

    Available commands:
      ping, status, tables, create_table, drop_table,
      get, put, delete, query, all,
      acl, acl grant, acl revoke, acl list

    Available patterns:
      patterns, memories, statemachine, identities

    Run 'cortex --help' for general usage.
    """)
  end

  # ============================================================================
  # General Help
  # ============================================================================

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
      --version                     Show version
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
