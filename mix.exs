defmodule MobBackground.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_background"

  def project do
    [
      app: :mob_background,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps(),
      aliases: aliases(),
      description:
        "Background execution keep-alive (iOS silent audio session / Android foreground service) for Mob apps",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push
    # and the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:mob, "~> 0.7"},
      {:mob_dev, "~> 0.6", only: [:dev, :test], runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/<plugin>/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
    ]
  end
end
