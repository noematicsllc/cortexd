defmodule Cortex.Mesh.DistActivationTest do
  use ExUnit.Case

  alias Cortex.Mesh.DistConfig
  alias Cortex.TestHelpers.Mesh, as: MH

  @moduletag :mesh

  # Task 9.3: TLS distribution activation tests

  setup do
    dir = Path.join(System.tmp_dir!(), "cortex_dist_test_#{:erlang.unique_integer([:positive])}")
    certs = MH.generate_test_certs(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, certs: certs}
  end

  describe "DistConfig.write_config/2" do
    test "generates parseable Erlang term file", %{dir: dir, certs: certs} do
      mesh_config = MH.mesh_config_for(certs, :node_a, "node-a", 5528, [])

      output_dir = Path.join(dir, "dist_output")
      path = DistConfig.write_config(mesh_config, output_dir)

      assert File.exists?(path)

      # The generated file must be parseable by :file.consult
      {:ok, terms} = :file.consult(String.to_charlist(path))
      assert is_list(terms)
      assert length(terms) == 1

      # :file.consult returns [keyword_list] where keyword_list has :server and :client
      [config] = terms
      assert is_list(config)
      assert Keyword.has_key?(config, :server)
      assert Keyword.has_key?(config, :client)
    end

    test "has correct [{server, _}, {client, _}] structure", %{dir: dir, certs: certs} do
      mesh_config = MH.mesh_config_for(certs, :node_a, "node-a", 5528, [])

      output_dir = Path.join(dir, "dist_output2")
      path = DistConfig.write_config(mesh_config, output_dir)

      {:ok, [config]} = :file.consult(String.to_charlist(path))

      # Should have server and client sections
      server_opts = Keyword.fetch!(config, :server)
      client_opts = Keyword.fetch!(config, :client)

      # Server should have certfile, keyfile, cacertfile, verify, fail_if_no_peer_cert
      assert List.keyfind(server_opts, :certfile, 0) != nil
      assert List.keyfind(server_opts, :keyfile, 0) != nil
      assert List.keyfind(server_opts, :cacertfile, 0) != nil
      assert {:verify, :verify_peer} = List.keyfind(server_opts, :verify, 0)
      assert {:fail_if_no_peer_cert, true} = List.keyfind(server_opts, :fail_if_no_peer_cert, 0)

      # Client should have certfile, keyfile, cacertfile, verify
      assert List.keyfind(client_opts, :certfile, 0) != nil
      assert List.keyfind(client_opts, :keyfile, 0) != nil
      assert List.keyfind(client_opts, :cacertfile, 0) != nil
      assert {:verify, :verify_peer} = List.keyfind(client_opts, :verify, 0)
    end

    test "uses correct cert paths from config", %{dir: dir, certs: certs} do
      mesh_config = MH.mesh_config_for(certs, :node_a, "node-a", 5528, [])

      output_dir = Path.join(dir, "dist_output3")
      path = DistConfig.write_config(mesh_config, output_dir)

      {:ok, [config]} = :file.consult(String.to_charlist(path))

      server_opts = Keyword.fetch!(config, :server)

      {:certfile, certfile} = List.keyfind(server_opts, :certfile, 0)
      {:keyfile, keyfile} = List.keyfind(server_opts, :keyfile, 0)
      {:cacertfile, cacertfile} = List.keyfind(server_opts, :cacertfile, 0)

      assert to_string(certfile) == certs.node_a.cert
      assert to_string(keyfile) == certs.node_a.key
      assert to_string(cacertfile) == certs.ca_cert
    end
  end

  describe "rel/env.sh.eex" do
    test "template file exists" do
      template_path = Path.join([File.cwd!(), "rel", "env.sh.eex"])
      assert File.exists?(template_path)
    end

    test "template contains required patterns" do
      template_path = Path.join([File.cwd!(), "rel", "env.sh.eex"])
      {:ok, content} = File.read(template_path)

      # Must check for CORTEX_MESH_NODE_NAME
      assert content =~ "CORTEX_MESH_NODE_NAME"
      # Must set RELEASE_DISTRIBUTION
      assert content =~ "RELEASE_DISTRIBUTION=name"
      # Must set RELEASE_NODE
      assert content =~ "RELEASE_NODE="
      # Must use inet_tls proto_dist
      assert content =~ "-proto_dist inet_tls"
      # Must reference ssl_dist_optfile
      assert content =~ "-ssl_dist_optfile"
      # Must reference required env vars
      assert content =~ "CORTEX_MESH_HOST"
      assert content =~ "CORTEX_MESH_CA_CERT"
      assert content =~ "CORTEX_MESH_NODE_CERT"
      assert content =~ "CORTEX_MESH_NODE_KEY"
    end

    test "template generates inet_tls.conf inline" do
      template_path = Path.join([File.cwd!(), "rel", "env.sh.eex"])
      {:ok, content} = File.read(template_path)

      # Must generate the TLS config inline
      assert content =~ "inet_tls.conf"
      assert content =~ "verify_peer"
      assert content =~ "fail_if_no_peer_cert"
    end
  end
end
