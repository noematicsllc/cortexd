defmodule Cortex.MixProject do
  use Mix.Project

  def project do
    [
      app: :cortex,
      version: "0.1.0-alpha",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Cortex.Application, []}
    ]
  end

  defp deps do
    [
      {:msgpax, "~> 2.4"},
      {:jason, "~> 1.4"},
      {:elixir_make, "~> 0.8", runtime: false}
    ]
  end

  defp escript do
    [main_module: Cortex.CLI, app: nil]
  end

  defp releases do
    [
      cortex: [
        include_erts: true,   # Bundle Erlang runtime for standalone distribution
        applications: [
          mnesia: :load,      # Include but don't start - we start it manually
          cortex: :permanent
        ]
      ]
    ]
  end
end
