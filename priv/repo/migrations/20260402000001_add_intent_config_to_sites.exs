defmodule Spectabas.Repo.Migrations.AddIntentConfigToSites do
  use Ecto.Migration

  def up do
    alter table(:sites) do
      add :intent_config, :map, default: %{}
    end

    flush()

    # Pre-configure intent paths for existing sites based on real traffic patterns
    # roommates.com (site_id 4): marketplace with search, listings, messaging
    execute """
    UPDATE sites SET intent_config = '#{Jason.encode!(%{"buying_paths" => ["/subscribe", "/upgrade", "/payment", "/register"], "engaging_paths" => ["/search", "/listings", "/messages", "/notifications", "/dashboard", "/users/profile", "/rooms-for-rent"], "support_paths" => ["/contact", "/help", "/faq"], "researching_threshold" => 2})}' WHERE domain = 'b.roommates.com'
    """

    # puppyfind.com (site_id 3): marketplace with listings, seller contact
    execute """
    UPDATE sites SET intent_config = '#{Jason.encode!(%{"buying_paths" => ["/register", "/signup", "/upgrade"], "engaging_paths" => ["/view_listing", "/view_photo", "/contact_seller", "/search"], "support_paths" => ["/support", "/contact", "/help"], "researching_threshold" => 2})}' WHERE domain = 'b.puppyfind.com'
    """

    # beverlyonmain.com (site_id 2): restaurant with menus
    execute """
    UPDATE sites SET intent_config = '#{Jason.encode!(%{"buying_paths" => ["/reservations", "/order", "/book"], "engaging_paths" => ["/menus", "/events", "/fwb"], "support_paths" => ["/contact"], "researching_threshold" => 2})}' WHERE domain = 'b.beverlyonmain.com'
    """

    # dogbreederlicensing.org (site_id 1): info site with reports, state pages
    execute """
    UPDATE sites SET intent_config = '#{Jason.encode!(%{"buying_paths" => [], "engaging_paths" => ["/reports", "/license-lookup", "/states", "/inspection-guide"], "support_paths" => ["/contact"], "researching_threshold" => 2})}' WHERE domain = 'b.dogbreederlicensing.org'
    """
  end

  def down do
    alter table(:sites) do
      remove :intent_config
    end
  end
end
