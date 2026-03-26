defmodule Spectabas.Sites.DNSVerifier do
  @moduledoc """
  Periodically checks DNS records for all active sites.
  Marks sites as verified or unverified based on DNS resolution.
  """

  use GenServer
  require Logger

  @check_interval_ms :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
    alias Spectabas.{Repo, Sites, Sites.Site}

    sites = Repo.all(from s in Site, where: s.active == true)

    Enum.each(sites, fn site ->
      case :inet.gethostbyname(String.to_charlist(site.domain)) do
        {:ok, _hostent} ->
          unless site.dns_verified do
            Sites.mark_dns_verified(site)
            Logger.info("[DNSVerifier] Verified: #{site.domain}")
          end

        {:error, _reason} ->
          if site.dns_verified do
            Sites.mark_dns_unverified(site)
            Logger.warning("[DNSVerifier] Unverified: #{site.domain}")
          end
      end
    end)
  end
end
