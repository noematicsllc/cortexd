defmodule Cortex.MixProject do
  use Mix.Project

  def project do
    [
      app: :cortex,
      version: "0.1.0-beta",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
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
      extra_applications: [:logger, :ssl, :public_key, :mnesia],
      mod: {Cortex.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
        # Bundle Erlang runtime for standalone distribution
        include_erts: true,
        applications: [
          # Include but don't start - we start it manually
          mnesia: :load,
          cortex: :permanent
        ]
      ]
    ]
  end
end
