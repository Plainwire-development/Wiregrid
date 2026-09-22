defmodule Wiregrid.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :wiregrid,
      version: @version,
      elixir: ">= 1.17.0",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_options: [
        :warnings_as_errors,
        :warn_export_vars,
        :warn_unused_function,
        :warn_unused_vars
      ],
      deps: deps(),
      description:
        "BEAM-native realtime infrastructure and chat toolkit for sessions, fanout, presence, rooms and signaling",
      docs: [main: "readme", extras: docs_extras()],
      package: package()
    ]
  end

  def cli do
    [preferred_envs: ["wiregrid.load": :test, "wiregrid.verify": :test]]
  end

  def application do
    [
      extra_applications: [:crypto, :logger, :public_key, :ssl],
      mod: {Wiregrid.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The runtime itself deliberately has no mandatory third-party dependency.
  # These are test-only so the adapter integration suite can exercise the
  # supported PostgreSQL, Redis, Scylla and Cowboy boundaries in CI.
  defp deps do
    [
      {:postgrex, "~> 0.22.4", only: :test},
      {:redix, "~> 1.9", only: :test},
      {:xandra, "~> 0.19.4", only: :test},
      {:cowboy, "~> 2.19", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end

  defp docs_extras do
    ["README.md", "SECURITY.md", "CHANGELOG.md"] ++ Path.wildcard("docs/*.md")
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files:
        ~w(lib src priv bindings native config examples scripts docs mix.exs README.md LICENSE SECURITY.md CHANGELOG.md CONTRIBUTING.md)
    ]
  end
end
