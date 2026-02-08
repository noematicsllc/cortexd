defmodule Cortex.Mesh.Token do
  @moduledoc """
  Claim tokens for federated identity linking.

  Tokens are signed by the origin node's TLS private key and verified
  by contacting the origin node over mTLS. The format is a simple
  base64-encoded payload with an appended signature — no JWT dependency.
  """

  require Logger

  @default_ttl_seconds 86400

  @doc """
  Generate a claim token signed with the node's private key.
  Returns {:ok, token_string} or {:error, reason}.
  """
  def generate(fed_id, node_name, uid) do
    case Cortex.mesh_config() do
      nil ->
        {:error, "mesh networking not configured"}

      config ->
        key_path = Keyword.fetch!(config, :node_key)

        with {:ok, pem} <- File.read(key_path) |> wrap_file_error("node key"),
             {:ok, private_key} <- decode_private_key(pem) do
          now = System.system_time(:second)

          payload = %{
            "fed_id" => fed_id,
            "origin_node" => node_name,
            "origin_uid" => uid,
            "issued_at" => now,
            "expires_at" => now + @default_ttl_seconds
          }

          payload_json = Jason.encode!(payload)
          payload_b64 = Base.url_encode64(payload_json)
          signature = :public_key.sign(payload_json, :sha256, private_key)
          sig_b64 = Base.url_encode64(signature)

          {:ok, "#{payload_b64}.#{sig_b64}"}
        end
    end
  end

  @doc """
  Decode and validate a claim token.
  Returns {:ok, payload_map} or {:error, reason}.

  Verification requires the origin node's certificate to check the signature.
  Pass the CA cert path to locate trusted certificates.
  """
  def verify(token_string) do
    case Cortex.mesh_config() do
      nil ->
        {:error, "mesh networking not configured"}

      config ->
        ca_cert_path = Keyword.fetch!(config, :ca_cert)

        with {:ok, {payload_json, signature}} <- decode_token(token_string),
             {:ok, payload} <- Jason.decode(payload_json),
             :ok <- check_expiry(payload),
             {:ok, origin_cert_pem} <- fetch_origin_cert(payload["origin_node"], config),
             :ok <- verify_signature(payload_json, signature, origin_cert_pem, ca_cert_path) do
          {:ok, payload}
        end
    end
  end

  @doc """
  Decode token payload without verification (for inspection).
  """
  def decode_payload(token_string) do
    with {:ok, {payload_json, _sig}} <- decode_token(token_string),
         {:ok, payload} <- Jason.decode(payload_json) do
      {:ok, payload}
    end
  end

  defp decode_token(token_string) do
    case String.split(token_string, ".") do
      [payload_b64, sig_b64] ->
        with {:ok, payload_json} <- Base.url_decode64(payload_b64),
             {:ok, signature} <- Base.url_decode64(sig_b64) do
          {:ok, {payload_json, signature}}
        else
          _ -> {:error, "invalid token encoding"}
        end

      _ ->
        {:error, "invalid token format"}
    end
  end

  defp check_expiry(%{"expires_at" => expires_at}) do
    if System.system_time(:second) < expires_at do
      :ok
    else
      {:error, "token expired"}
    end
  end

  defp check_expiry(_), do: {:error, "missing expiry"}

  defp fetch_origin_cert(origin_node, config) do
    nodes = Keyword.get(config, :nodes, [])

    case Enum.find(nodes, fn {name, _, _} -> name == origin_node end) do
      nil ->
        {:error, "origin node #{origin_node} not found in mesh config"}

      {_name, host, port} ->
        # Primary: fetch cert via mTLS connection to origin node
        case fetch_cert_via_mtls(host, port, config) do
          {:ok, pem} ->
            {:ok, pem}

          {:error, reason} ->
            Logger.debug(
              "mTLS cert fetch from #{origin_node} failed (#{inspect(reason)}), trying local store"
            )

            # Fallback: read from local cert store
            fetch_cert_from_local_store(origin_node, config)
        end
    end
  end

  defp fetch_cert_via_mtls(host, port, config) do
    ca_cert = Keyword.fetch!(config, :ca_cert)
    node_cert = Keyword.fetch!(config, :node_cert)
    node_key = Keyword.fetch!(config, :node_key)

    ssl_opts = [
      certfile: node_cert,
      keyfile: node_key,
      cacertfile: ca_cert,
      verify: :verify_peer,
      versions: [:"tlsv1.3", :"tlsv1.2"],
      active: false
    ]

    host_charlist = String.to_charlist(host)

    with {:ok, ssl_socket} <- :ssl.connect(host_charlist, port, ssl_opts, 5_000),
         {:ok, cert_der} <- :ssl.peercert(ssl_socket) do
      :ssl.close(ssl_socket)
      # Convert DER to PEM
      pem_entry = {:Certificate, cert_der, :not_encrypted}
      {:ok, :public_key.pem_encode([pem_entry])}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_cert_from_local_store(origin_node, config) do
    ca_cert = Keyword.fetch!(config, :ca_cert)
    ca_dir = Path.dirname(ca_cert)
    cert_path = Path.join([ca_dir, "nodes", "#{origin_node}.crt"])

    case File.read(cert_path) do
      {:ok, pem} -> {:ok, pem}
      {:error, _} -> {:error, "cannot find certificate for #{origin_node}"}
    end
  end

  defp verify_signature(payload_json, signature, cert_pem, ca_cert_path) do
    with [{:Certificate, cert_der, :not_encrypted}] <- :public_key.pem_decode(cert_pem),
         {:ok, ca_pem} <- File.read(ca_cert_path),
         [{:Certificate, ca_der, :not_encrypted}] <- :public_key.pem_decode(ca_pem) do
      otp_cert = :public_key.pkix_decode_cert(cert_der, :otp)
      ca_otp = :public_key.pkix_decode_cert(ca_der, :otp)

      case :public_key.pkix_path_validation(ca_otp, [otp_cert], []) do
        {:ok, _} ->
          public_key = extract_public_key(otp_cert)

          if :public_key.verify(payload_json, :sha256, signature, public_key) do
            :ok
          else
            {:error, "invalid token signature"}
          end

        {:error, {:bad_cert, reason}} ->
          {:error, "origin certificate not signed by mesh CA: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "cannot read CA certificate: #{inspect(reason)}"}
      _bad_pem -> {:error, "malformed certificate PEM"}
    end
  end

  defp extract_public_key(otp_cert) do
    # OTPCertificate -> OTPTBSCertificate -> OTPSubjectPublicKeyInfo -> public key
    # TBS: (0=tag, 1=version, 2=serial, 3=sig, 4=issuer, 5=validity, 6=subject, 7=spki)
    # SPKI: (0=tag, 1=algorithm, 2=subjectPublicKey)
    tbs = elem(otp_cert, 1)
    spki = elem(tbs, 7)
    elem(spki, 2)
  end

  defp decode_private_key(pem) do
    case :public_key.pem_decode(pem) do
      [{type, der, :not_encrypted}] ->
        case type do
          :RSAPrivateKey -> {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
          :PrivateKeyInfo -> {:ok, :public_key.der_decode(:PrivateKeyInfo, der)}
          :ECPrivateKey -> {:ok, :public_key.der_decode(:ECPrivateKey, der)}
          other -> {:error, "unsupported key type: #{inspect(other)}"}
        end

      [{_type, _der, _cipher}] ->
        {:error, "encrypted private keys are not supported"}

      [] ->
        {:error, "no PEM entries found in key file"}

      _other ->
        {:error, "malformed PEM key file"}
    end
  end

  defp wrap_file_error({:ok, _} = ok, _label), do: ok

  defp wrap_file_error({:error, reason}, label),
    do: {:error, "cannot read #{label}: #{inspect(reason)}"}
end
