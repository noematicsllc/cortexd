defmodule Cortex.Mesh.CertsTest do
  use ExUnit.Case, async: true
  import Bitwise

  @moduletag :mesh
  @moduletag :openssl

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

  describe "init_mesh/2" do
    test "creates CA and node cert in one call", %{dir: dir} do
      assert {:ok, %{ca_cert: ca_cert, node_cert: node_cert, node_key: node_key}} =
               Cortex.Mesh.Certs.init_mesh(dir, node_name: "mesh-node", host: "10.0.0.1")

      assert File.exists?(ca_cert)
      assert File.exists?(node_cert)
      assert File.exists?(node_key)

      # Verify node cert is signed by CA
      {_output, 0} =
        System.cmd("openssl", ["verify", "-CAfile", ca_cert, node_cert])
    end

    test "fails if already exists without force", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_mesh(dir, node_name: "n1", host: "10.0.0.1")

      assert {:error, msg} = Cortex.Mesh.Certs.init_mesh(dir, node_name: "n1", host: "10.0.0.1")
      assert msg =~ "already exists"
    end

    test "overwrites with force option", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_mesh(dir, node_name: "n1", host: "10.0.0.1")

      assert {:ok, _} =
               Cortex.Mesh.Certs.init_mesh(dir, node_name: "n1", host: "10.0.0.1", force: true)
    end
  end

  describe "sign_csr/3" do
    test "signs a valid CSR", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)

      # Generate a CSR
      key_path = Path.join(dir, "joiner.key")
      csr_path = Path.join(dir, "joiner.csr")
      {_, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "openssl",
          ["req", "-new", "-key", key_path, "-out", csr_path, "-subj", "/CN=joiner-node"],
          stderr_to_stdout: true
        )

      csr_pem = File.read!(csr_path)

      assert {:ok, cert_pem} =
               Cortex.Mesh.Certs.sign_csr(csr_pem, dir,
                 node_name: "joiner-node",
                 host: "10.0.0.5"
               )

      assert cert_pem =~ "BEGIN CERTIFICATE"

      # Verify the cert is signed by our CA
      cert_tmp = Path.join(dir, "joiner_signed.crt")
      File.write!(cert_tmp, cert_pem)

      {_output, 0} =
        System.cmd("openssl", ["verify", "-CAfile", Path.join(dir, "ca.crt"), cert_tmp])
    end

    test "rejects malformed CSR", %{dir: dir} do
      {:ok, _} = Cortex.Mesh.Certs.init_ca(dir)

      assert {:error, _} = Cortex.Mesh.Certs.sign_csr("not a valid CSR", dir)
    end

    test "fails without CA", %{dir: dir} do
      assert {:error, msg} = Cortex.Mesh.Certs.sign_csr("whatever", dir)
      assert msg =~ "not found"
    end
  end
end
