defmodule Cortex.Version do
  @moduledoc """
  Version information for Cortex.
  """

  @version Mix.Project.config()[:version]

  def version, do: @version
end
