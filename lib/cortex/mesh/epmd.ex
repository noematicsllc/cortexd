defmodule Cortex.Mesh.Epmd do
  @moduledoc """
  Custom EPMD module that uses a fixed distribution port (tls_port + 2).
  Eliminates the need for EPMD (port 4369) on mesh nodes.
  """

  @dist_port_offset 2

  def start_link do
    :ignore
  end

  def register_node(_name, _port) do
    {:ok, 0}
  end

  def register_node(_name, _port, _driver) do
    {:ok, 0}
  end

  def port_please(_name, _host) do
    {:port, dist_port(), 5}
  end

  def port_please(_name, _host, _timeout) do
    {:port, dist_port(), 5}
  end

  def names(_hostname) do
    {:ok, []}
  end

  def address_please(_name, host, _address_family) do
    case :inet.getaddr(host, :inet) do
      {:ok, addr} -> {:ok, addr}
      _ -> {:error, :nxdomain}
    end
  end

  defp dist_port do
    case Application.get_env(:cortex, :mesh) do
      nil -> 5528 + @dist_port_offset
      config -> Keyword.get(config, :tls_port, 5528) + @dist_port_offset
    end
  end
end
