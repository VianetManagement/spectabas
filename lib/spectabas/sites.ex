defmodule Spectabas.Sites do
  @moduledoc """
  Context for managing sites: CRUD, DNS verification, IP filtering, and snippet generation.
  """

  require Logger
  import Ecto.Query, warn: false
  alias Spectabas.{Repo, Audit}
  alias Spectabas.Sites.{Site, DomainCache}

  @doc "Extract parent domain from a site's analytics subdomain (e.g., b.example.com → example.com)."
  def parent_domain_for(%Site{domain: domain}) do
    parts = String.split(domain, ".")

    if length(parts) > 2 do
      parts |> Enum.drop(1) |> Enum.join(".")
    else
      domain
    end
  end

  @doc "List all sites, ordered by name."
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
  Accepts attrs map which must include account_id.
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
        register_render_domain(site.domain)
        {:ok, site}

      error ->
        error
    end
  end

  @doc """
  Register a custom domain on Render. Returns :ok, {:ok, :already_exists}, or {:error, reason}.
  """
  def register_render_domain(domain) do
    api_key = System.get_env("RENDER_API_KEY")
    service_id = System.get_env("RENDER_SERVICE_ID")

    if api_key && service_id do
      result =
        Req.post("https://api.render.com/v1/services/#{service_id}/custom-domains",
          headers: [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"}
          ],
          json: %{name: domain}
        )

      case result do
        {:ok, %{status: s}} when s in [200, 201] ->
          Logger.info("[Sites] Registered custom domain on Render: #{domain}")
          :ok

        {:ok, %{status: 409}} ->
          Logger.info("[Sites] Domain already registered on Render: #{domain}")
          {:ok, :already_exists}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[Sites] Failed to register domain #{domain} on Render: status=#{status} body=#{inspect(body)}"
          )

          {:error, "Render API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          Logger.warning(
            "[Sites] Failed to register domain #{domain} on Render: #{inspect(reason)}"
          )

          {:error, inspect(reason)}
      end
    else
      missing =
        [
          if(is_nil(api_key), do: "RENDER_API_KEY"),
          if(is_nil(service_id), do: "RENDER_SERVICE_ID")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      Logger.warning("[Sites] Cannot register domain — missing env vars: #{missing}")
      {:error, "Missing env vars: #{missing}"}
    end
  end

  @doc """
  List custom domains currently registered on Render.
  """
  def list_render_domains do
    api_key = System.get_env("RENDER_API_KEY")
    service_id = System.get_env("RENDER_SERVICE_ID")

    if api_key && service_id do
      case Req.get("https://api.render.com/v1/services/#{service_id}/custom-domains",
             headers: [{"authorization", "Bearer #{api_key}"}]
           ) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, Enum.map(body, fn d -> d["customDomain"]["name"] end)}

        {:ok, %{status: status, body: body}} ->
          {:error, "status #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:error, "Missing RENDER_API_KEY or RENDER_SERVICE_ID"}
    end
  end

  @doc """
  Update a site. Invalidates domain cache if domain changed.
  """
  def update_site(%Site{} = site, attrs) do
    old_domain = site.domain
    attrs = parse_text_fields(attrs)

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

  defp parse_text_fields(attrs) when is_map(attrs) do
    attrs
    |> maybe_parse_list("cross_domain_sites_text", "cross_domain_sites")
    |> maybe_parse_list("ip_allowlist_text", "ip_allowlist")
    |> maybe_parse_list("ip_blocklist_text", "ip_blocklist")
    |> maybe_parse_list("scraper_content_prefixes_text", "scraper_content_prefixes")
    |> maybe_parse_list("journey_conversion_pages_text", "journey_conversion_pages")
    |> maybe_parse_list("search_query_params_text", "search_query_params")
    |> Map.drop([
      "cross_domain_sites_text",
      "ip_allowlist_text",
      "ip_blocklist_text",
      "scraper_content_prefixes_text",
      "journey_conversion_pages_text",
      "search_query_params_text"
    ])
  end

  defp maybe_parse_list(attrs, text_key, list_key) do
    case Map.get(attrs, text_key) do
      nil ->
        attrs

      text ->
        list =
          text
          |> String.split(~r/[,\n]/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(attrs, list_key, list)
    end
  end

  @doc """
  Returns the HTML snippet for embedding the Spectabas tracker on a site.
  """
  def snippet_code(%Site{} = site) do
    gdpr_attr = if site.gdpr_mode == "on", do: ~s( data-gdpr="on"), else: ""

    xd_attr =
      if site.cross_domain_sites not in [nil, []],
        do: ~s( data-xd="#{Enum.join(site.cross_domain_sites, ",")}"),
        else: ""

    xid_attr =
      if site.identity_cookie_name not in [nil, ""],
        do: ~s( data-xid-cookie="#{site.identity_cookie_name}"),
        else: ""

    """
    <script defer data-id="#{site.public_key}"#{gdpr_attr}#{xd_attr}#{xid_attr} src="https://#{site.domain}/assets/v1.js"></script>
    <noscript><img src="https://#{site.domain}/c/p?s=#{site.public_key}" alt="" style="position:absolute;width:0;height:0" /></noscript>\
    """
    |> String.trim()
  end

  @doc "Proxy snippet for Cloudflare Workers."
  def proxy_snippet_code(%Site{} = site) do
    parent = parent_domain_for(site)
    gdpr_attr = if site.gdpr_mode == "on", do: ~s( data-gdpr="on"), else: ""

    xd_attr =
      if site.cross_domain_sites not in [nil, []],
        do: ~s( data-xd="#{Enum.join(site.cross_domain_sites, ",")}"),
        else: ""

    """
    <script defer data-id="#{site.public_key}"#{gdpr_attr}#{xd_attr} data-proxy="https://www.#{parent}/t" src="https://www.#{parent}/t/v1.js"></script>
    <noscript><img src="https://www.#{parent}/t/c/p?s=#{site.public_key}" alt="" style="position:absolute;width:0;height:0" /></noscript>\
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
