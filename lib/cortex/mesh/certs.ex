defmodule Cortex.Mesh.Certs do
  @moduledoc """
  Certificate generation for mesh networking.

  Uses openssl CLI for certificate generation. This is a setup-time tool,
  not a runtime dependency — certs are generated once and used by :ssl.
  """

  @ca_validity_days 3650
  @node_validity_days 365

  @doc """
  Initialize a new mesh CA in the given directory.
  Returns {:ok, ca_cert_path} or {:error, reason}.
  """
  def init_ca(output_dir, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    ca_key_path = Path.join(output_dir, "ca.key")
    ca_cert_path = Path.join(output_dir, "ca.crt")

    if File.exists?(ca_key_path) and not force do
      {:error, "CA already exists at #{output_dir}. Use --force to overwrite."}
    else
      File.mkdir_p!(output_dir)

      with :ok <- run_openssl(["genrsa", "-out", ca_key_path, "4096"]),
           :ok <- File.chmod(ca_key_path, 0o600),
           :ok <-
             run_openssl([
               "req",
               "-new",
               "-x509",
               "-key",
               ca_key_path,
               "-out",
               ca_cert_path,
               "-days",
               to_string(@ca_validity_days),
               "-subj",
               "/CN=Cortex Mesh CA"
             ]) do
        {:ok, ca_cert_path}
      end
    end
  end

  @doc """
  Generate a node certificate signed by the mesh CA.
  Returns {:ok, cert_path} or {:error, reason}.
  """
  @valid_node_name ~r/^[a-zA-Z0-9_-]+$/

  def add_node(ca_dir, node_name, host, opts \\ []) do
    unless Regex.match?(@valid_node_name, node_name) do
      {:error, "invalid node name: must be alphanumeric with hyphens/underscores"}
    else
      do_add_node(ca_dir, node_name, host, opts)
    end
  end

  defp do_add_node(ca_dir, node_name, host, opts) do
    ca_key_path = Path.join(ca_dir, "ca.key")
    ca_cert_path = Path.join(ca_dir, "ca.crt")
    nodes_dir = Keyword.get(opts, :output_dir, Path.join(ca_dir, "nodes"))

    unless File.exists?(ca_key_path) do
      {:error, "CA not found at #{ca_dir}. Run 'cortex mesh init-ca' first."}
    else
      File.mkdir_p!(nodes_dir)

      node_key_path = Path.join(nodes_dir, "#{node_name}.key")
      node_csr_path = Path.join(nodes_dir, "#{node_name}.csr")
      node_cert_path = Path.join(nodes_dir, "#{node_name}.crt")
      ext_path = Path.join(nodes_dir, "#{node_name}.ext")

      # Build SAN extension config
      san_entries = ["DNS:#{node_name}"] ++ san_for_host(host)

      ext_content =
        "subjectAltName=#{Enum.join(san_entries, ",")}\n" <>
          "basicConstraints=CA:FALSE\n" <>
          "keyUsage=digitalSignature,keyEncipherment\n" <>
          "extendedKeyUsage=serverAuth,clientAuth\n"

      with :ok <- run_openssl(["genrsa", "-out", node_key_path, "2048"]),
           :ok <- File.chmod(node_key_path, 0o600),
           :ok <-
             run_openssl([
               "req",
               "-new",
               "-key",
               node_key_path,
               "-out",
               node_csr_path,
               "-subj",
               "/CN=#{node_name}"
             ]),
           :ok <- File.write(ext_path, ext_content),
           :ok <-
             run_openssl([
               "x509",
               "-req",
               "-in",
               node_csr_path,
               "-CA",
               ca_cert_path,
               "-CAkey",
               ca_key_path,
               "-CAcreateserial",
               "-out",
               node_cert_path,
               "-days",
               to_string(@node_validity_days),
               "-extfile",
               ext_path
             ]) do
        # Clean up temp files
        File.rm(node_csr_path)
        File.rm(ext_path)
        {:ok, node_cert_path}
      end
    end
  end

  defp san_for_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> ["IP:#{host}"]
      _ -> ["DNS:#{host}"]
    end
  end

  defp run_openssl(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "openssl exited #{code}: #{String.trim(output)}"}
    end
  end
end
