defmodule Cortex.Mesh.TokenTest do
  use ExUnit.Case

  alias Cortex.Mesh.Token
  alias Cortex.TestHelpers.Mesh, as: MH

  @moduletag :mesh

  setup do
    dir = Path.join(System.tmp_dir!(), "cortex_token_test_#{:erlang.unique_integer([:positive])}")
    certs = MH.generate_test_certs(dir)

    # Set up mesh config pointing to node-a's certs
    mesh_config =
      MH.mesh_config_for(certs, :node_a, "node-a", 4711, [
        {"node-b", "127.0.0.1", 4711}
      ])

    original_mesh = Application.get_env(:cortex, :mesh)
    Application.put_env(:cortex, :mesh, mesh_config)

    on_exit(fn ->
      if original_mesh, do: Application.put_env(:cortex, :mesh, original_mesh),
      else: Application.delete_env(:cortex, :mesh)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, certs: certs, mesh_config: mesh_config}
  end

  describe "generate/3" do
    test "produces a two-part base64url token" do
      {:ok, token} = Token.generate("alice", "node-a", 1000)

      parts = String.split(token, ".")
      assert length(parts) == 2

      [payload_b64, sig_b64] = parts
      assert {:ok, _} = Base.url_decode64(payload_b64)
      assert {:ok, _} = Base.url_decode64(sig_b64)
    end

    test "token payload contains expected fields" do
      {:ok, token} = Token.generate("bob", "node-a", 1001)
      {:ok, payload} = Token.decode_payload(token)

      assert payload["fed_id"] == "bob"
      assert payload["origin_node"] == "node-a"
      assert payload["origin_uid"] == 1001
      assert is_integer(payload["issued_at"])
      assert is_integer(payload["expires_at"])
      assert payload["expires_at"] > payload["issued_at"]
    end

    test "token expiry defaults to 24 hours" do
      {:ok, token} = Token.generate("carol", "node-a", 1002)
      {:ok, payload} = Token.decode_payload(token)

      assert payload["expires_at"] - payload["issued_at"] == 86400
    end
  end

  describe "decode_payload/1" do
    test "decodes valid token payload without verification" do
      {:ok, token} = Token.generate("dave", "node-a", 1003)
      {:ok, payload} = Token.decode_payload(token)

      assert payload["fed_id"] == "dave"
    end

    test "rejects malformed token" do
      assert {:error, _} = Token.decode_payload("not-a-valid-token")
    end

    test "rejects token with invalid base64" do
      assert {:error, _} = Token.decode_payload("!!!.!!!")
    end
  end

  describe "verify/1" do
    test "verifies token signed by known node", %{certs: certs} do
      # Register node-b as a peer so verify can find its cert
      # node-a is the origin (signs the token), node-b needs to be in config
      # But we're configured as node-a, and generate creates tokens from node-a
      # We need to verify from node-b's perspective looking at node-a's token

      # Reconfigure as node-b to verify a token from node-a
      mesh_config =
        MH.mesh_config_for(certs, :node_b, "node-b", 4711, [
          {"node-a", "127.0.0.1", 4711}
        ])
      Application.put_env(:cortex, :mesh, mesh_config)

      # First generate as node-a
      Application.put_env(:cortex, :mesh,
        MH.mesh_config_for(certs, :node_a, "node-a", 4711, [
          {"node-b", "127.0.0.1", 4711}
        ])
      )
      {:ok, token} = Token.generate("eve", "node-a", 1004)

      # Now verify as node-b (needs to find node-a's cert)
      Application.put_env(:cortex, :mesh, mesh_config)
      {:ok, payload} = Token.verify(token)

      assert payload["fed_id"] == "eve"
      assert payload["origin_node"] == "node-a"
    end

    test "rejects token with tampered payload", %{certs: certs} do
      {:ok, token} = Token.generate("frank", "node-a", 1005)
      [_payload_b64, sig_b64] = String.split(token, ".")

      # Tamper with the payload
      tampered_payload = Base.url_encode64(Jason.encode!(%{"fed_id" => "hacker", "origin_node" => "node-a", "origin_uid" => 9999, "issued_at" => System.system_time(:second), "expires_at" => System.system_time(:second) + 86400}))
      tampered_token = "#{tampered_payload}.#{sig_b64}"

      # Reconfigure to be able to find node-a's cert
      mesh_config =
        MH.mesh_config_for(certs, :node_b, "node-b", 4711, [
          {"node-a", "127.0.0.1", 4711}
        ])
      Application.put_env(:cortex, :mesh, mesh_config)

      assert {:error, "invalid token signature"} = Token.verify(tampered_token)
    end
  end
end
