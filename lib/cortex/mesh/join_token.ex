defmodule Cortex.Mesh.JoinToken do
  @moduledoc """
  Join tokens for mesh pairing.

  Encodes/decodes join tokens in the format `cxm_<base64url(host|port|secret|cert_fingerprint)>`.
  Uses `|` as the delimiter to support IPv6 addresses which contain colons.
  These are distinct from identity claim tokens in `Cortex.Mesh.Token`.
  """

  @prefix "cxm_"

  @doc """
  Encode a join token from its components.
  Returns a string like `cxm_<base64url(host|port|secret|cert_fingerprint)>`.
  """
  def encode(host, port, secret, cert_fingerprint) do
    payload = "#{host}|#{port}|#{secret}|#{cert_fingerprint}"
    @prefix <> Base.url_encode64(payload, padding: false)
  end

  @doc """
  Decode a join token string.
  Returns `{:ok, %{host: ..., port: ..., secret: ..., cert_fingerprint: ...}}` or `{:error, reason}`.
  """
  def decode(@prefix <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, payload} ->
        case String.split(payload, "|") do
          [host, port_str, secret, cert_fingerprint] ->
            case Integer.parse(port_str) do
              {port, ""} ->
                {:ok,
                 %{host: host, port: port, secret: secret, cert_fingerprint: cert_fingerprint}}

              _ ->
                {:error, "invalid port in join token"}
            end

          _ ->
            {:error, "invalid join token format: expected 4 pipe-delimited fields"}
        end

      :error ->
        {:error, "invalid join token encoding"}
    end
  end

  def decode(_), do: {:error, "invalid join token prefix"}

  @doc """
  Generate a cryptographically random 32-byte secret, hex-encoded.
  """
  def generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  @doc """
  Compute the SHA-256 fingerprint of a PEM certificate file.
  Returns `{:ok, hex_fingerprint}` or `{:error, reason}`.
  """
  def cert_fingerprint(cert_path) do
    with {:ok, pem} <- File.read(cert_path) do
      case :public_key.pem_decode(pem) do
        [{:Certificate, der, :not_encrypted} | _rest] ->
          hash = :crypto.hash(:sha256, der)
          {:ok, Base.encode16(hash, case: :lower)}

        [] ->
          {:error, "no certificate found in PEM file"}

        _ ->
          {:error, "invalid PEM certificate"}
      end
    end
  end
end
