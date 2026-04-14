defmodule Spectabas.Repo.Migrations.AddScraperContentPrefixesToSites do
  use Ecto.Migration

  # List of URL-path prefixes that identify "content" pages on this site —
  # e.g. ["/listings", "/products", "/profiles"]. Used by the scraper
  # detector to compute the :systematic_crawl signal. NULL/empty disables
  # the signal for that site.
  def change do
    alter table(:sites) do
      add :scraper_content_prefixes, {:array, :string}, default: []
    end
  end
end
