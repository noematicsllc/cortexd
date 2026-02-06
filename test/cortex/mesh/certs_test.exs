defmodule Cortex.Mesh.CertsTest do
  use ExUnit.Case, async: true
  import Bitwise

  @moduletag :mesh

  setup do
    dir = Path.join(System.tmp_dir!(), "cortex_certs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "init_ca/2" do
    test "generates CA key and self-signed certificate", %{dir: dir} do
      assert {:ok, ca_cert_path} = Cortex.Mesh.Certs.init_ca(dir)

      assert File.exists?(ca_cert_path)
      assert File.exists?(Path.join(dir, "ca.key"))

      # Verify it's a valid certificate
      {output, 0} = System.cmd("openssl", ["x509", "-in", ca_cert_path, "-noout", "-subject"])
      assert output =~ "Cortex Mesh CA"
    end

    test "CA key has restricted permissions", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      key_path = Path.join(dir, "ca.key")

      %{mode: mode} = File.stat!(key_path)
      assert (mode &&& 0o777) == 0o600
    end

    test "refuses to overwrite existing CA without force", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)

      assert {:error, msg} = Cortex.Mesh.Certs.init_ca(dir)
      assert msg =~ "already exists"
    end

    test "overwrites existing CA with force option", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, ca_cert} = Cortex.Mesh.Certs.init_ca(dir, force: true)

      assert File.exists?(ca_cert)
    end
  end

  describe "add_node/4" do
    test "generates node cert signed by CA", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      assert {:ok, cert_path} = Cortex.Mesh.Certs.add_node(dir, "test-node", "192.168.1.10")

      assert File.exists?(cert_path)

      # Verify cert is signed by our CA
      {_output, 0} =
        System.cmd("openssl", [
          "verify",
          "-CAfile",
          Path.join(dir, "ca.crt"),
          cert_path
        ])
    end

    test "sets correct CN", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, cert_path} = Cortex.Mesh.Certs.add_node(dir, "my-node", "10.0.0.1")

      {output, 0} = System.cmd("openssl", ["x509", "-in", cert_path, "-noout", "-subject"])
      assert output =~ "CN = my-node" or output =~ "CN=my-node"
    end

    test "includes IP SAN for IP address hosts", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, cert_path} = Cortex.Mesh.Certs.add_node(dir, "ip-node", "10.0.0.5")

      {output, 0} = System.cmd("openssl", ["x509", "-in", cert_path, "-noout", "-text"])
      assert output =~ "IP Address:10.0.0.5"
    end

    test "includes DNS SAN for hostname hosts", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, cert_path} = Cortex.Mesh.Certs.add_node(dir, "dns-node", "node1.example.com")

      {output, 0} = System.cmd("openssl", ["x509", "-in", cert_path, "-noout", "-text"])
      assert output =~ "DNS:dns-node"
      assert output =~ "DNS:node1.example.com"
    end

    test "node key has restricted permissions", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, _} = Cortex.Mesh.Certs.add_node(dir, "perm-node", "127.0.0.1")

      key_path = Path.join([dir, "nodes", "perm-node.key"])
      %{mode: mode} = File.stat!(key_path)
      assert (mode &&& 0o777) == 0o600
    end

    test "cleans up CSR and extension files", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)
      {:ok, _} = Cortex.Mesh.Certs.add_node(dir, "clean-node", "127.0.0.1")

      nodes_dir = Path.join(dir, "nodes")
      refute File.exists?(Path.join(nodes_dir, "clean-node.csr"))
      refute File.exists?(Path.join(nodes_dir, "clean-node.ext"))
    end

    test "fails without CA", %{dir: dir} do
      assert {:error, msg} = Cortex.Mesh.Certs.add_node(dir, "orphan", "127.0.0.1")
      assert msg =~ "CA not found"
    end
  end
end
