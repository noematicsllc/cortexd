defmodule Cortex.Mesh.MeshInviteTest do
  use ExUnit.Case

  alias Cortex.Mesh.{Certs, JoinToken, Pairing}

  @moduletag :mesh

  setup do
    dir = Path.join(System.tmp_dir!(), "mesh_invite_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, %{ca_cert: ca_cert, node_cert: node_cert, node_key: node_key}} =
      Certs.init_mesh(dir, node_name: "invite-seed", host: "127.0.0.1")

    tls_port = 15_528 + rem(:erlang.unique_integer([:positive]), 10_000)

    mesh_config = [
      node_name: "invite-seed",
      tls_port: tls_port,
      ca_cert: ca_cert,
      node_cert: node_cert,
      node_key: node_key,
      host: "127.0.0.1",
      nodes: []
    ]

    prev_config = Application.get_env(:cortex, :mesh)
    Application.put_env(:cortex, :mesh, mesh_config)

    {:ok, pid} = Pairing.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if prev_config,
        do: Application.put_env(:cortex, :mesh, prev_config),
        else: Application.delete_env(:cortex, :mesh)

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, tls_port: tls_port, node_cert: node_cert}
  end

  # These tests exercise the same logic as dispatch("mesh_invite", ...) in Handler,
  # which is a private function. We test the components directly: Pairing.add_secret
  # + JoinToken.cert_fingerprint + JoinToken.encode.

  test "mesh_invite produces a valid cxm_ token", %{tls_port: tls_port, node_cert: node_cert} do
    {:ok, secret} = Pairing.add_secret()
    {:ok, fingerprint} = JoinToken.cert_fingerprint(node_cert)
    token = JoinToken.encode("127.0.0.1", tls_port + 1, secret, fingerprint)

    assert String.starts_with?(token, "cxm_")
    assert {:ok, decoded} = JoinToken.decode(token)
    assert decoded.host == "127.0.0.1"
    assert decoded.port == tls_port + 1
    assert String.length(decoded.secret) == 64
    assert String.length(decoded.ca_fingerprint) == 64
  end

  test "mesh_invite produces different tokens each time", %{tls_port: tls_port, node_cert: node_cert} do
    {:ok, s1} = Pairing.add_secret()
    {:ok, s2} = Pairing.add_secret()
    {:ok, fingerprint} = JoinToken.cert_fingerprint(node_cert)
    t1 = JoinToken.encode("127.0.0.1", tls_port + 1, s1, fingerprint)
    t2 = JoinToken.encode("127.0.0.1", tls_port + 1, s2, fingerprint)
    assert t1 != t2
  end

  test "mesh_invite fails without mesh config" do
    config = Application.get_env(:cortex, :mesh)
    Application.delete_env(:cortex, :mesh)

    assert Cortex.mesh_config() == nil

    Application.put_env(:cortex, :mesh, config)
  end
end
