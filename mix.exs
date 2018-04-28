defmodule Crux.Base.MixProject do
  use Mix.Project

  def project do
    [
      start_permanent: Mix.env() == :prod,
      package: package(),
      app: :crux_base,
      version: "0.1.0",
      elixir: "~> 1.6",
      description: "An example / base implemention of various crux components.",
      source_url: "https://github.com/SpaceEEC/crux_base/",
      homepage_url: "https://github.com/SpaceEEC/crux_base/",
      deps: deps()
    ]
  end

  def package do
    [
      name: :crux_base,
      licenses: ["MIT"],
      maintainers: ["SpaceEEC"],
      links: %{
        "GitHub" => "https://github.com/SpaceEEC/crux_base/",
        "Docs" => "https://hexdocs.pm/crux_base/"
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Crux.Base.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:crux_structs, "~> 0.1.0"},
      {:crux_cache, "~> 0.1.0"},
      {:crux_gateway, "~> 0.1.0"},
      {:crux_rest, "~> 0.1.0"},
      {:ex_doc, "~> 0.18.3", only: :dev}
    ]
  end
end
