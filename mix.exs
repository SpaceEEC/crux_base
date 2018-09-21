defmodule Crux.Base.MixProject do
  use Mix.Project

  @vsn "0.1.0"
  @name :crux_base

  def project do
    [
      start_permanent: Mix.env() == :prod,
      package: package(),
      app: @name,
      version: @vsn,
      elixir: "~> 1.6",
      description: "An example / base implemention of crux' components.",
      source_url: "https://github.com/SpaceEEC/#{@name}/",
      homepage_url: "https://github.com/SpaceEEC/#{@name}/",
      deps: deps()
    ]
  end

  def package do
    [
      name: @name,
      licenses: ["MIT"],
      maintainers: ["SpaceEEC"],
      links: %{
        "GitHub" => "https://github.com/SpaceEEC/#{@name}/",
        "Changelog" => "https://github.com/SpaceEEC/#{@name}/releases/tag/#{@vsn}/",
        "Documentation" => "https://hexdocs.pm/#{@name}/",
        "Unified Development Documentation" => "https://crux.randomly.space/"
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Crux.Base, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:crux_structs, "~> 0.1.5"},
      {:crux_cache, "~> 0.1.1"},
      {:crux_gateway, "~> 0.1.3"},
      {:crux_rest, "~> 0.1.6"},
      {:ex_doc, git: "https://github.com/spaceeec/ex_doc", only: :dev, runtime: false}
    ]
  end
end
