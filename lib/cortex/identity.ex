defmodule Cortex.Identity do
  @moduledoc """
  Extract peer credentials from Unix socket connections.

  Uses SO_PEERCRED via NIF to get the connecting process's UID.
  This is kernel-enforced and cannot be forged.
  """

  alias Cortex.Peercred

  @doc """
  Extract the UID from a connected gen_tcp socket.

  Returns {:ok, uid} or {:error, reason}.
  """
  def get_uid(socket) do
    with {:ok, fd} <- :inet.getfd(socket),
         {:ok, {_pid, uid, _gid}} <- Peercred.get_peercred(fd) do
      {:ok, uid}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Extract the Common Name (CN) from a TLS peer certificate.

  Returns {:ok, cn_string} or {:error, reason}.
  """
  def get_node_cn(ssl_socket) do
    with {:ok, cert_der} <- :ssl.peercert(ssl_socket) do
      otp_cert = :public_key.pkix_decode_cert(cert_der, :otp)
      # OTPTBSCertificate is elem 1, subject is elem 6
      # (0=tag, 1=version, 2=serial, 3=sig, 4=issuer, 5=validity, 6=subject, 7=spki)
      tbs = elem(otp_cert, 1)
      subject = elem(tbs, 6)

      case extract_cn(subject) do
        {:ok, cn} -> {:ok, cn}
        :not_found -> {:error, :no_cn_in_cert}
      end
    end
  end

  defp extract_cn({:rdnSequence, rdn_list}) do
    Enum.find_value(rdn_list, :not_found, fn attrs ->
      Enum.find_value(attrs, nil, fn
        {:AttributeTypeAndValue, {2, 5, 4, 3}, value} ->
          {:ok, to_string_value(value)}
        _ ->
          nil
      end)
    end)
  end

  defp to_string_value({:utf8String, v}) when is_binary(v), do: v
  defp to_string_value({:utf8String, v}) when is_list(v), do: List.to_string(v)
  defp to_string_value({:printableString, v}) when is_list(v), do: List.to_string(v)
  defp to_string_value({:printableString, v}) when is_binary(v), do: v
  defp to_string_value(v) when is_binary(v), do: v
  defp to_string_value(v) when is_list(v), do: List.to_string(v)

  @doc """
  Format a UID as an identity string.
  """
  def uid_to_identity(uid), do: "uid:#{uid}"

  @doc """
  Parse an identity string to extract the UID.
  """
  def parse_identity("uid:" <> uid_str) do
    case Integer.parse(uid_str) do
      {uid, ""} -> {:ok, uid}
      _ -> {:error, :invalid_identity}
    end
  end

  def parse_identity("*"), do: {:ok, :world}
  def parse_identity(_), do: {:error, :invalid_identity}

  @doc """
  Resolve a (node_name, uid) pair to a federated identity, if one exists.

  Returns {:ok, fed_id} or :not_found.
  """
  def resolve_federated(node_name, uid) do
    case Cortex.Store.lookup_federated_by_local(node_name, uid) do
      {:ok, fed_id} -> {:ok, fed_id}
      _ -> :not_found
    end
  end
end
