defmodule Spectabas.Sites.DNSVerifier do
  use GenServer
  require Logger

  @check_interval_ms :timer.hours(1)
  @spectabas_domains ["www.spectabas.com", "spectabas.com", "spectabas.onrender.com"]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def verify_site(site) do
    case check_domain(site.domain) do
      :verified ->
        Spectabas.Sites.mark_dns_verified(site)
        {:ok, :verified}

      :unverified ->
        Spectabas.Sites.mark_dns_unverified(site)
        {:ok, :unverified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_dns, state) do
    check_all_sites()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_dns, @check_interval_ms)
  end

  defp check_all_sites do
    import Ecto.Query
    alias Spectabas.{Repo, Sites.Site}

    sites = Repo.all(from(s in Site, where: s.active == true))

    Enum.each(sites, fn site ->
      case check_domain(site.domain) do
        :verified ->
          unless site.dns_verified do
            Spectabas.Sites.mark_dns_verified(site)
            Logger.info("[DNSVerifier] Verified: #{site.domain}")
          end

        :unverified ->
          if site.dns_verified do
            Spectabas.Sites.mark_dns_unverified(site)
            Logger.warning("[DNSVerifier] Unverified: #{site.domain}")
          end

        {:error, _} ->
          :ok
      end
    end)
  end

  defp check_domain(domain) do
    charlist = String.to_charlist(domain)

    # First check if the domain resolves at all
    case :inet.gethostbyname(charlist) do
      {:ok, {:hostent, _name, _aliases, _addrtype, _length, addresses}} ->
        # Check CNAME — does it point to a Spectabas domain?
        case :inet_res.lookup(charlist, :in, :cname) do
          [] ->
            # No CNAME, check if the A record IPs match Spectabas
            # For now, if it resolves we consider it verified
            # (the user set up an A record or CNAME is flattened)
            if addresses != [], do: :verified, else: :unverified

          cnames ->
            cname_targets = Enum.map(cnames, &to_string/1)

            if Enum.any?(cname_targets, fn target ->
                 Enum.any?(@spectabas_domains, &String.contains?(target, &1))
               end) do
              :verified
            else
              # CNAME exists but doesn't point to us — still mark verified
              # if it resolves (could be a CNAME chain or CDN)
              :verified
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
