defmodule Spectabas.Sites do
  @moduledoc """
  Context for managing sites: CRUD, DNS verification, IP filtering, and snippet generation.
  """

  import Ecto.Query, warn: false
  alias Spectabas.{Repo, Audit}
  alias Spectabas.Sites.{Site, DomainCache}

  @doc """
  List all sites, ordered by name.
  """
  def list_sites do
    Repo.all(from s in Site, order_by: [asc: s.name])
  end

  @doc """
  Get a single site by ID. Raises if not found.
  """
  def get_site!(id), do: Repo.get!(Site, id)

  @doc """
  Get a single site by ID. Returns nil if not found.
  """
  def get_site(id), do: Repo.get(Site, id)

  @doc """
  Get a site by its domain. Returns nil if not found.
  """
  def get_site_by_domain(domain) when is_binary(domain) do
    Repo.get_by(Site, domain: domain)
  end

  @doc """
  Create a new site. Generates a public key and warms the domain cache.
  """
  def create_site(attrs) do
    public_key = Site.generate_public_key()

    %Site{}
    |> Site.changeset(attrs)
    |> Ecto.Changeset.put_change(:public_key, public_key)
    |> Repo.insert()
    |> case do
      {:ok, site} ->
        DomainCache.put(site)
        Audit.log("site.created", %{site_id: site.id, domain: site.domain})
        {:ok, site}

      error ->
        error
    end
  end

  @doc """
  Update a site. Invalidates domain cache if domain changed.
  """
  def update_site(%Site{} = site, attrs) do
    old_domain = site.domain

    site
    |> Site.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_site} ->
        if updated_site.domain != old_domain do
          DomainCache.delete(old_domain)
        end

        DomainCache.put(updated_site)
        Audit.log("site.updated", %{site_id: site.id, domain: updated_site.domain})
        {:ok, updated_site}

      error ->
        error
    end
  end

  @doc """
  Delete a site and remove it from the domain cache.
  """
  def delete_site(admin, %Site{} = site) do
    case Repo.delete(site) do
      {:ok, deleted} ->
        DomainCache.delete(site.domain)
        Audit.log("site.deleted", %{site_id: site.id, deleted_by: admin.id, domain: site.domain})
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Mark a site as DNS verified.
  """
  def mark_dns_verified(%Site{} = site) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    site
    |> Ecto.Changeset.change(dns_verified: true, dns_verified_at: now)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        DomainCache.put(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Mark a site as DNS unverified.
  """
  def mark_dns_unverified(%Site{} = site) do
    site
    |> Ecto.Changeset.change(dns_verified: false, dns_verified_at: nil)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        DomainCache.put(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Check if an IP address is in the site's blocklist.
  Returns true if blocked, false otherwise.
  """
  def ip_blocked?(%Site{ip_blocklist: blocklist}, ip_string) when is_binary(ip_string) do
    ip_string in (blocklist || [])
  end

  def ip_blocked?(_, _), do: false

  @doc """
  Returns the HTML snippet for embedding the Spectabas tracker on a site.
  """
  def snippet_code(%Site{} = site) do
    gdpr_attr = if site.gdpr_mode == "off", do: ~s( data-gdpr="off"), else: ""

    xd_attr =
      if site.cross_domain_tracking && site.cross_domain_sites != [] do
        ~s( data-xd="#{Enum.join(site.cross_domain_sites, ",")}")
      else
        ""
      end

    """
    <script defer data-site="#{site.public_key}"#{gdpr_attr}#{xd_attr} src="https://www.spectabas.com/s.js"></script>
    """
    |> String.trim()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking site changes.
  """
  def change_site(%Site{} = site, attrs \\ %{}) do
    Site.changeset(site, attrs)
  end
end
