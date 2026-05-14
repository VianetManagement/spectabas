defmodule Spectabas.Repo.Migrations.AddSeoUserAgentToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      # Per-site override for the User-Agent string used during SEO
      # audits. Empty / null = use the sidecar's default (a real Chrome
      # UA with a SpectabasBot suffix). Customers with strict WAFs can
      # set their own UA to match a custom allow-rule.
      add :seo_user_agent, :string, size: 512
    end
  end
end
