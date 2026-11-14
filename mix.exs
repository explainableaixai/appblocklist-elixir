defmodule AppBlockList.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/explainableaixai/appblocklist-elixir"

  def project do
    [
      app: :appblocklist,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "AppBlockList",
      source_url: @source_url,
      homepage_url: "https://www.appblocklist.com",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir client for the AppBlockList App Lookup API: categorize iOS and Android apps " <>
      "by bundle ID, App Store ID or package name for MDM blocklists, school devices and parental control."
  end

  defp package do
    [
      name: "appblocklist",
      licenses: ["MIT"],
      maintainers: ["Alpha Quantum"],
      files: ~w(lib examples mix.exs .formatter.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "Homepage" => "https://www.appblocklist.com",
        "GitHub" => @source_url,
        "API documentation" => "https://www.appblocklist.com/app-categorization-api.php",
        "Support" => "https://www.appblocklist.com/contact.php"
      }
      # Keywords: mdm, app-blocklist, bundle-id, ios, android, app-categorization,
      # intune, jamf, parental-control, school-devices, mobile-security, app-store, api-client
    ]
  end
end
