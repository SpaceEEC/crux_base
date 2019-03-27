defmodule Crux.Base.MixProject do
  use Mix.Project

  @vsn "0.2.0-dev"
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
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:crux_structs, git: "https://github.com/spaceeec/crux_structs.git", override: true},
      {:crux_cache, git: "https://github.com/spaceeec/crux_cache.git", override: true},
      {:crux_gateway, git: "https://github.com/spaceeec/crux_gateway.git", override: true},
      {:ex_doc, git: "https://github.com/spaceeec/ex_doc", branch: "feat/umbrella", only: :dev, runtime: false}
    ]
  end
end
