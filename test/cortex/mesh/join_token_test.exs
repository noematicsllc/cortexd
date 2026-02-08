defmodule Cortex.Mesh.JoinTokenTest do
  use ExUnit.Case, async: true

  alias Cortex.Mesh.JoinToken

  describe "encode/4 and decode/1" do
    test "round-trip with IP host" do
      secret = JoinToken.generate_secret()
      fingerprint = String.duplicate("ab", 32)
      token = JoinToken.encode("158.69.220.39", 5529, secret, fingerprint)

      assert String.starts_with?(token, "cxm_")
      assert {:ok, decoded} = JoinToken.decode(token)
      assert decoded.host == "158.69.220.39"
      assert decoded.port == 5529
      assert decoded.secret == secret
      assert decoded.ca_fingerprint == fingerprint
    end

    test "round-trip with hostname" do
      secret = JoinToken.generate_secret()
      fingerprint = String.duplicate("cd", 32)
      token = JoinToken.encode("node1.example.com", 5529, secret, fingerprint)

      assert {:ok, decoded} = JoinToken.decode(token)
      assert decoded.host == "node1.example.com"
    end
  end

  describe "decode/1 error cases" do
    test "rejects token with wrong prefix" do
      assert {:error, "invalid join token prefix"} = JoinToken.decode("bad_token")
    end

    test "rejects token with no prefix" do
      assert {:error, "invalid join token prefix"} = JoinToken.decode("noprefixhere")
    end

    test "rejects token with invalid base64" do
      assert {:error, "invalid join token encoding"} = JoinToken.decode("cxm_!!!invalid!!!")
    end

    test "rejects token with wrong field count (too few)" do
      payload = Base.url_encode64("host:5529", padding: false)
      assert {:error, "invalid join token format" <> _} = JoinToken.decode("cxm_" <> payload)
    end

    test "rejects token with wrong field count (too many)" do
      payload = Base.url_encode64("host:5529:secret:fp:extra", padding: false)
      assert {:error, "invalid join token format" <> _} = JoinToken.decode("cxm_" <> payload)
    end

    test "rejects token with non-integer port" do
      payload = Base.url_encode64("host:notaport:secret:fp", padding: false)
      assert {:error, "invalid port in join token"} = JoinToken.decode("cxm_" <> payload)
    end
  end

  describe "generate_secret/0" do
    test "returns 64 hex characters" do
      secret = JoinToken.generate_secret()
      assert String.length(secret) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, secret)
    end

    test "generates unique secrets" do
      s1 = JoinToken.generate_secret()
      s2 = JoinToken.generate_secret()
      assert s1 != s2
    end
  end

  describe "cert_fingerprint/1" do
    test "computes SHA-256 of DER-encoded certificate" do
      # Generate a self-signed CA cert for testing
      dir = System.tmp_dir!() |> Path.join("join_token_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      key_path = Path.join(dir, "ca.key")
      cert_path = Path.join(dir, "ca.crt")

      {_, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "openssl",
          ["req", "-new", "-x509", "-key", key_path, "-out", cert_path, "-days", "1", "-subj", "/CN=Test CA"],
          stderr_to_stdout: true
        )

      assert {:ok, fingerprint} = JoinToken.cert_fingerprint(cert_path)
      assert String.length(fingerprint) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, fingerprint)

      # Verify deterministic
      assert {:ok, ^fingerprint} = JoinToken.cert_fingerprint(cert_path)

      File.rm_rf!(dir)
    end

    test "returns error for missing file" do
      assert {:error, _} = JoinToken.cert_fingerprint("/nonexistent/path.crt")
    end
  end
end
