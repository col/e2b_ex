defmodule E2bEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :e2b_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "E2bEx",
      description: description(),
      package: package(),
      source_url: "https://github.com/col/e2b_ex",
      docs: [
        main: "E2bEx",
        extras: ["README.md"],
        source_ref: "v0.2.0"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "An Elixir client for the E2B sandbox platform"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/col/e2b_ex"},
      maintainers: ["Colin Harris"]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:plug, "~> 1.16", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
