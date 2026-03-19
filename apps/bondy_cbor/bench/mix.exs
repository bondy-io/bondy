defmodule BondyCborBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bondy_cbor_bench,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.3"},
      {:benchee_html, "~> 1.0"},
      {:benchee_markdown, "~> 0.3"},
      {:msgpack, "~> 0.7"},
      # Include bondy_cbor from parent directory
      {:bondy_cbor, path: ".."}
    ]
  end

  defp aliases do
    [
      bench: "run bench.exs"
    ]
  end
end
