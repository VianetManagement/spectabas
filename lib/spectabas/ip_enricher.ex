defmodule Spectabas.IPEnricher do
  @moduledoc """
  IP address enrichment: geolocation, ASN data, and datacenter/VPN/Tor detection.
  Always uses the full IP for geo lookup (region/city accuracy requires it).
  In GDPR-on mode, anonymizes the IP for storage only.
  """

  alias Spectabas.IPEnricher.{IPCache, ASNBlocklist}

  @doc """
  Enrich an IP address string with geolocation and network data.
  Returns a map with all enrichment fields.
  """
  def enrich(ip_string, gdpr_mode) when is_binary(ip_string) do
    gdpr_on? = gdpr_mode in ["on", :on]

    case IPCache.get(ip_string) do
      {:ok, cached} ->
        cached

      :miss ->
        result = do_enrich(ip_string, gdpr_on?)
        IPCache.put(ip_string, result)
        result
    end
  end

  def enrich(_, _), do: empty_result()

  defp do_enrich(original_ip, gdpr_on?) do
    parsed_ip = parse_ip(original_ip)

    # DB-IP for primary geo data
    city_result = Geolix.lookup(parsed_ip, where: :city)
    asn_result = Geolix.lookup(parsed_ip, where: :asn)

    # MaxMind GeoLite2 for timezone (falls back gracefully if not loaded)
    maxmind_result = Geolix.lookup(parsed_ip, where: :maxmind_city)

    asn_number = get_in_safe(asn_result, [:autonomous_system_number])
    asn_org = get_in_safe(asn_result, [:autonomous_system_organization]) || ""

    # MaxMind extras: timezone, EU flag, metro code
    timezone =
      get_in_safe(maxmind_result, [:location, :time_zone]) ||
        get_in_safe(city_result, [:location, :time_zone]) ||
        get_in_safe(city_result, [:location, :timezone]) || ""

    is_eu =
      get_in_safe(maxmind_result, [:country, :is_in_european_union]) ||
        get_in_safe(city_result, [:country, :is_in_european_union]) || false

    vpn_provider = lookup_vpn_provider(parsed_ip)

    %{
      ip_address: if(gdpr_on?, do: anonymize(original_ip), else: original_ip),
      ip_country: get_in_safe(city_result, [:country, :iso_code]) || "",
      ip_country_name: get_localized_name(get_in_safe(city_result, [:country, :names])),
      ip_continent: get_in_safe(city_result, [:continent, :code]) || "",
      ip_continent_name: get_localized_name(get_in_safe(city_result, [:continent, :names])),
      ip_region_code: get_first_subdivision_iso(city_result),
      ip_region_name: get_first_subdivision_name(city_result),
      ip_city: get_localized_name(get_in_safe(city_result, [:city, :names])),
      ip_postal_code: get_in_safe(city_result, [:postal, :code]) || "",
      ip_lat: get_in_safe(city_result, [:location, :latitude]) || 0.0,
      ip_lon: get_in_safe(city_result, [:location, :longitude]) || 0.0,
      ip_accuracy_radius: get_in_safe(city_result, [:location, :accuracy_radius]) || 0,
      ip_timezone: timezone,
      ip_asn: asn_number || 0,
      ip_asn_org: asn_org,
      ip_org: format_org(asn_number, asn_org),
      ip_is_datacenter:
        if(asn_number && ASNBlocklist.datacenter?(asn_number) && vpn_provider == "",
          do: 1,
          else: 0
        ),
      ip_is_vpn:
        if((asn_number && ASNBlocklist.vpn?(asn_number)) || vpn_provider != "", do: 1, else: 0),
      ip_is_tor: if(asn_number && ASNBlocklist.tor?(asn_number), do: 1, else: 0),
      ip_vpn_provider: vpn_provider,
      ip_is_bot: 0,
      ip_is_eu: if(is_eu, do: 1, else: 0),
      ip_gdpr_anonymized: if(gdpr_on?, do: 1, else: 0)
    }
  end

  @doc """
  Anonymize an IP address for GDPR compliance.
  IPv4: zeroes the last octet. IPv6: zeroes the last 80 bits.
  """
  def anonymize(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, {a, b, c, _d}} ->
        "#{a}.#{b}.#{c}.0"

      {:ok, {a, b, c, _d, _e, _f, _g, _h}} ->
        parts = [a, b, c, 0, 0, 0, 0, 0]

        parts
        |> Enum.map(&Integer.to_string(&1, 16))
        |> Enum.join(":")

      {:error, _} ->
        ip_string
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp get_in_safe(nil, _keys), do: nil
  defp get_in_safe(map, []), do: map

  defp get_in_safe(map, [key | rest]) when is_map(map) do
    get_in_safe(Map.get(map, key), rest)
  end

  defp get_in_safe(_, _), do: nil

  defp get_localized_name(nil), do: ""

  defp get_localized_name(names) when is_map(names) do
    # DB-IP via Geolix uses atom keys (:en), MaxMind uses string keys ("en")
    Map.get(names, "en") || Map.get(names, :en) || ""
  end

  defp get_localized_name(_), do: ""

  defp get_first_subdivision_iso(nil), do: ""

  defp get_first_subdivision_iso(result) do
    case get_in_safe(result, [:subdivisions]) do
      [first | _] -> Map.get(first, :iso_code, "") || ""
      _ -> ""
    end
  end

  defp get_first_subdivision_name(nil), do: ""

  defp get_first_subdivision_name(result) do
    case get_in_safe(result, [:subdivisions]) do
      [first | _] -> get_localized_name(Map.get(first, :names))
      _ -> ""
    end
  end

  defp format_org(nil, _), do: ""
  defp format_org(asn, org), do: "AS#{asn} #{org}"

  def vpn_provider_for_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, parsed} -> lookup_vpn_provider(parsed)
      _ -> ""
    end
  end

  def vpn_provider_for_ip(_), do: ""

  defp empty_result do
    %{
      ip_address: "",
      ip_country: "",
      ip_country_name: "",
      ip_continent: "",
      ip_continent_name: "",
      ip_region_code: "",
      ip_region_name: "",
      ip_city: "",
      ip_postal_code: "",
      ip_lat: 0.0,
      ip_lon: 0.0,
      ip_accuracy_radius: 0,
      ip_timezone: "",
      ip_asn: 0,
      ip_asn_org: "",
      ip_org: "",
      ip_is_datacenter: 0,
      ip_is_vpn: 0,
      ip_is_tor: 0,
      ip_vpn_provider: "",
      ip_is_bot: 0,
      ip_is_eu: 0,
      ip_gdpr_anonymized: 0
    }
  end

  # Known privacy relay ASNs — CDN providers that serve as egress for
  # consumer privacy services (Apple iCloud Private Relay, Cloudflare WARP).
  # Not traditional VPNs but should be tagged for visibility.
  @privacy_relay_asns %{
    54113 => "Apple Private Relay (Fastly)",
    13335 => "Cloudflare (WARP/Private Relay)",
    20940 => "Akamai (CDN/Privacy Relay)",
    36183 => "Akamai (CDN/Privacy Relay)",
    63949 => "Akamai (CDN/Privacy Relay)",
    200_005 => "Akamai (CDN/Privacy Relay)",
    32787 => "Akamai (CDN/Privacy Relay)"
  }

  defp lookup_vpn_provider(parsed_ip) do
    # Check enumerated first (highest confidence), then interpolated, then privacy relays
    case Geolix.lookup(parsed_ip, where: :vpn_enumerated) do
      %{serviceName: name} when is_binary(name) and name != "" ->
        name

      _ ->
        case Geolix.lookup(parsed_ip, where: :vpn_interpolated) do
          %{serviceName: name} when is_binary(name) and name != "" ->
            name

          _ ->
            # Check if the IP belongs to a known privacy relay ASN
            case Geolix.lookup(parsed_ip, where: :asn) do
              %{autonomous_system_number: asn} -> Map.get(@privacy_relay_asns, asn, "")
              _ -> ""
            end
        end
    end
  end
end

defmodule Spectabas.IPEnricher.IPCache do
  @moduledoc """
  ETS-backed IP enrichment cache with 1-hour TTL and 50,000 entry limit.
  """

  use GenServer

  @table :spectabas_ip_cache
  @ttl_ms :timer.hours(1)
  @max_entries 50_000
  @sweep_interval_ms :timer.minutes(5)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached enrichment result for an IP.
  Returns `{:ok, result}` or `:miss`.
  """
  def get(ip) when is_binary(ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, ip) do
      [{^ip, result, expires_at}] when expires_at > now -> {:ok, result}
      _ -> :miss
    end
  end

  @doc """
  Cache an enrichment result for an IP.
  """
  def put(ip, result) when is_binary(ip) and is_map(result) do
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {ip, result, expires_at})
    :ok
  end

  @doc """
  Clear all entries from the cache.
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep do
    now = System.monotonic_time(:millisecond)

    # Delete expired entries
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    # Trim to max size: delete entries expiring soonest using a cutoff
    size = :ets.info(@table, :size)

    if size > @max_entries do
      # Find the median expiry and delete everything below it
      # This avoids tab2list + sort (O(n log n)) by using select_delete
      cutoff = now + div(@ttl_ms, 2)

      :ets.select_delete(@table, [
        {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
      ])

      # If still over, do a more aggressive cutoff
      if :ets.info(@table, :size) > @max_entries do
        :ets.select_delete(@table, [
          {{:_, :_, :"$1"}, [{:<, :"$1", now + @ttl_ms}], [true]}
        ])
      end
    end
  end
end

defmodule Spectabas.IPEnricher.ASNBlocklist do
  @moduledoc """
  Loads ASN blocklists for datacenter, VPN, and Tor detection from text files.
  Reloads every 24 hours.
  """

  use GenServer
  require Logger

  @dc_table :spectabas_asn_dc
  @vpn_table :spectabas_asn_vpn
  @tor_table :spectabas_asn_tor
  @reload_interval_ms :timer.hours(24)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if an ASN is a known datacenter."
  def datacenter?(asn), do: :ets.member(@dc_table, normalize_asn(asn))

  @doc "Check if an ASN is a known VPN provider."
  def vpn?(asn), do: :ets.member(@vpn_table, normalize_asn(asn))

  @doc "Check if an ASN is a known Tor exit."
  def tor?(asn), do: :ets.member(@tor_table, normalize_asn(asn))

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@dc_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@vpn_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@tor_table, [:named_table, :set, :public, read_concurrency: true])

    load_all()
    schedule_reload()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:reload, state) do
    load_all()
    schedule_reload()
    {:noreply, state}
  end

  defp schedule_reload do
    Process.send_after(self(), :reload, @reload_interval_ms)
  end

  defp load_all do
    load_file(@dc_table, asn_file("asn_datacenter.txt"))
    load_file(@vpn_table, asn_file("asn_vpn.txt"))
    load_file(@tor_table, asn_file("asn_tor.txt"))
  end

  defp load_file(table, path) do
    :ets.delete_all_objects(table)

    if File.exists?(path) do
      count =
        path
        |> File.stream!()
        |> Stream.map(&parse_line/1)
        |> Stream.reject(&is_nil/1)
        |> Enum.reduce(0, fn asn, acc ->
          :ets.insert(table, {asn, true})
          acc + 1
        end)

      Logger.notice("[ASNBlocklist] Loaded #{count} ASNs from #{Path.basename(path)}")
    else
      Logger.warning("[ASNBlocklist] File not found: #{path}")
    end
  end

  # File lines look like "AS45090 # Tencent cloud..." — strip the optional
  # `AS` prefix and inline `#` comments before parsing.
  defp parse_line(line) do
    cleaned =
      line
      |> String.split("#", parts: 2)
      |> hd()
      |> String.trim()

    cleaned =
      if String.starts_with?(cleaned, "AS") or String.starts_with?(cleaned, "as") do
        String.slice(cleaned, 2..-1//1)
      else
        cleaned
      end

    case Integer.parse(cleaned) do
      {asn, _} -> asn
      :error -> nil
    end
  end

  @doc "Returns {dc_count, vpn_count, tor_count} — useful for health checks."
  def sizes do
    {:ets.info(@dc_table, :size) || 0, :ets.info(@vpn_table, :size) || 0,
     :ets.info(@tor_table, :size) || 0}
  end

  @doc "Returns all ASNs in a given list as a sorted integer list."
  def all(:datacenter), do: :ets.tab2list(@dc_table) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  def all(:vpn), do: :ets.tab2list(@vpn_table) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  def all(:tor), do: :ets.tab2list(@tor_table) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp asn_file(filename) do
    Path.join(:code.priv_dir(:spectabas), "asn_lists/#{filename}")
  end

  defp normalize_asn(asn) when is_integer(asn), do: asn

  defp normalize_asn(asn) when is_binary(asn) do
    case Integer.parse(asn) do
      {n, _} -> n
      :error -> 0
    end
  end
end
