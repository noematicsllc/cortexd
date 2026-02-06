defmodule Cortex.Mesh.DistConfigTest do
  use ExUnit.Case, async: true

  @moduletag :mesh

  describe "generate_config/1" do
    test "produces valid Erlang term syntax" do
      config = [
        ca_cert: "/etc/cortex/ca.crt",
        node_cert: "/etc/cortex/node.crt",
        node_key: "/etc/cortex/node.key"
      ]

      result = Cortex.Mesh.DistConfig.generate_config(config)

      assert result =~ "server"
      assert result =~ "client"
      assert result =~ "/etc/cortex/ca.crt"
      assert result =~ "/etc/cortex/node.crt"
      assert result =~ "/etc/cortex/node.key"
      assert result =~ "verify_peer"
      assert result =~ "fail_if_no_peer_cert"
    end

    test "includes all required TLS options for server" do
      config = [ca_cert: "/ca.crt", node_cert: "/node.crt", node_key: "/node.key"]
      result = Cortex.Mesh.DistConfig.generate_config(config)

      assert result =~ "{certfile,"
      assert result =~ "{keyfile,"
      assert result =~ "{cacertfile,"
      assert result =~ "{verify, verify_peer}"
      assert result =~ "{fail_if_no_peer_cert, true}"
      assert result =~ "{secure_renegotiate, true}"
    end

    test "includes all required TLS options for client" do
      config = [ca_cert: "/ca.crt", node_cert: "/node.crt", node_key: "/node.key"]
      result = Cortex.Mesh.DistConfig.generate_config(config)

      # Client section should have verify_peer but NOT fail_if_no_peer_cert
      # Split into server and client sections
      [_before, client_section] = String.split(result, "{client,", parts: 2)
      assert client_section =~ "{verify, verify_peer}"
      assert client_section =~ "{secure_renegotiate, true}"
      refute client_section =~ "fail_if_no_peer_cert"
    end
  end

  describe "write_config/2" do
    test "writes config file to specified directory" do
      dir = Path.join(System.tmp_dir!(), "cortex_dist_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      config = [ca_cert: "/ca.crt", node_cert: "/node.crt", node_key: "/node.key"]
      path = Cortex.Mesh.DistConfig.write_config(config, dir)

      assert path == Path.join(dir, "inet_tls.conf")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "server"
      assert content =~ "client"
    end
  end
end
