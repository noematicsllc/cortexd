defmodule CortexTest do
  use ExUnit.Case

  setup do
    # Use test-specific paths
    test_id = :erlang.unique_integer([:positive])
    socket_path = "/tmp/cortex_test_#{test_id}.sock"
    data_dir = "/tmp/cortex_test_mnesia_#{test_id}"

    Application.put_env(:cortex, :socket_path, socket_path)
    Application.put_env(:cortex, :data_dir, data_dir)

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      File.rm(socket_path)
      File.rm_rf!(data_dir)
    end)

    {:ok, socket_path: socket_path, data_dir: data_dir}
  end

  describe "Protocol" do
    test "encodes and decodes requests" do
      request = Msgpax.pack!([0, 1, "ping", []])
      {:ok, decoded} = Cortex.Protocol.decode_request(request)

      assert decoded.msgid == 1
      assert decoded.method == "ping"
      assert decoded.params == []
    end

    test "encodes responses" do
      response = Cortex.Protocol.encode_response(1, "pong")
      {:ok, [1, 1, nil, "pong"]} = Msgpax.unpack(response)
    end

    test "encodes errors" do
      response = Cortex.Protocol.encode_error(1, :not_found)
      {:ok, [1, 1, "not_found", nil]} = Msgpax.unpack(response)
    end
  end

  describe "Identity" do
    test "formats UID as identity string" do
      assert Cortex.Identity.uid_to_identity(1000) == "uid:1000"
    end

    test "parses identity string" do
      assert Cortex.Identity.parse_identity("uid:1000") == {:ok, 1000}
      assert Cortex.Identity.parse_identity("*") == {:ok, :world}
      assert Cortex.Identity.parse_identity("invalid") == {:error, :invalid_identity}
    end
  end

  describe "ACL" do
    test "parses permission strings" do
      assert Cortex.ACL.parse_permissions("read,write") == {:ok, [:read, :write]}
      assert Cortex.ACL.parse_permissions("read") == {:ok, [:read]}
      assert Cortex.ACL.parse_permissions("invalid") == {:error, :invalid_permissions}
    end

    test "parses permission lists" do
      assert Cortex.ACL.parse_permissions(["read", "write"]) == {:ok, [:read, :write]}
      assert Cortex.ACL.parse_permissions([:read, :admin]) == {:ok, [:read, :admin]}
    end
  end
end
