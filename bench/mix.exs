defmodule BondyDbBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bondy_db_bench,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: ["lib"],
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :sasl]
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.3"},
      {:benchee_html, "~> 1.0"},
      {:benchee_json, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      bench: ["run benchmarks/all.exs"]
    ]
  end
end
