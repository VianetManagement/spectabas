defmodule Spectabas.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectabas,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Spectabas.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.5"},
      {:geolix, "~> 2.0"},
      {:geolix_adapter_mmdb2, "~> 0.6"},
      {:ua_inspector, "~> 3.4"},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:hammer, "~> 6.0"},
      {:hammer_plug, "~> 3.0"},
      {:oban, "~> 2.17"},
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},
      {:wax_, "~> 0.7"},
      {:castore, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:tzdata, "~> 1.1"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.1"},
      {:csv, "~> 3.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:floki, ">= 0.30.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:gettext, "~> 1.0"},
      {:faker, "~> 0.18", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind spectabas", "esbuild spectabas"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
