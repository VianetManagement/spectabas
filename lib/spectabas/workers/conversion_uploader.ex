defmodule Spectabas.Workers.ConversionUploader do
  @moduledoc """
  Hourly per-site: pulls pending conversion rows, groups by ad-platform
  destination, and pushes to Google Data Manager API + Microsoft Ads
  Bulk. Records match results / errors per row.
  """

  use Oban.Worker,
    queue: :ad_sync,
    max_attempts: 3,
    unique: [period: 600, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias Spectabas.{AdIntegrations, Conversions, Repo, Sites}
  alias Spectabas.Conversions.{Conversion, ConversionAction, GoogleDataManager, MicrosoftAds}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    sites = Sites.list_sites() |> Enum.filter(& &1.active)

    Enum.each(sites, fn site ->
      try do
        upload_for_site(site)
      rescue
        e ->
          Logger.warning("[ConversionUploader] site=#{site.id} crashed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp upload_for_site(site) do
    pending = Conversions.list_pending(site.id, 1000)

    if pending != [] do
      # Group by (conversion_action_id, click_id_type-platform)
      pending
      |> Enum.group_by(fn c ->
        case classify_platform(c.click_id_type) do
          :unknown -> nil
          platform -> {c.conversion_action_id, platform}
        end
      end)
      |> Enum.reject(fn {key, _} -> is_nil(key) end)
      |> Enum.each(fn {{action_id, platform}, rows} ->
        action = Repo.get(ConversionAction, action_id)
        if action, do: upload_batch(site, action, platform, rows)
      end)
    end
  end

  defp classify_platform("google"), do: :google
  defp classify_platform("google_wbraid"), do: :google
  defp classify_platform("google_gbraid"), do: :google
  defp classify_platform("microsoft"), do: :microsoft
  defp classify_platform(_), do: :unknown

  defp upload_batch(site, %ConversionAction{} = action, :google, conversions) do
    case google_integration(site) do
      nil ->
        Logger.warning("[ConversionUploader] site=#{site.id} no Google Ads integration; skipping")
        :ok

      integration ->
        if action.google_conversion_action_id in [nil, ""] do
          Conversions.mark_failed(conversions, "no google_conversion_action_id configured")
        else
          login_id = (integration.extra || %{})["login_customer_id"] || integration.account_id

          # Chunk to 2000 events per request — Google's per-call sane limit.
          conversions
          |> Enum.chunk_every(2000)
          |> Enum.each(fn chunk ->
            mark_in_progress(chunk)

            case GoogleDataManager.upload(
                   integration,
                   integration.account_id,
                   login_id,
                   action.google_conversion_action_id,
                   chunk
                 ) do
              {:ok, %{failures: failures}} ->
                handle_google_result(chunk, failures)

              {:error, reason} ->
                Conversions.mark_failed(chunk, "google: #{inspect(reason)}")
            end
          end)
        end
    end
  end

  defp upload_batch(site, %ConversionAction{} = action, :microsoft, conversions) do
    case microsoft_integration(site) do
      nil ->
        Logger.warning(
          "[ConversionUploader] site=#{site.id} no Microsoft Ads integration; skipping"
        )

        :ok

      integration ->
        if action.microsoft_conversion_name in [nil, ""] do
          Conversions.mark_failed(conversions, "no microsoft_conversion_name configured")
        else
          customer_id = (integration.extra || %{})["customer_id"] || integration.account_id
          account_id = integration.account_id

          conversions
          |> Enum.chunk_every(1000)
          |> Enum.each(fn chunk ->
            mark_in_progress(chunk)

            case MicrosoftAds.upload(
                   integration,
                   customer_id,
                   account_id,
                   action.microsoft_conversion_name,
                   chunk
                 ) do
              {:ok, _result} ->
                Conversions.mark_uploaded(chunk, :microsoft)

              {:error, reason} ->
                Conversions.mark_failed(chunk, "microsoft: #{inspect(reason)}")
            end
          end)
        end
    end
  end

  # Mark all rows in chunk as currently uploading. Cheap — just stops a
  # parallel run from picking them up again.
  defp mark_in_progress(chunk) do
    ids = Enum.map(chunk, & &1.id)

    Repo.update_all(
      from(c in Conversion, where: c.id in ^ids),
      set: [
        upload_state: "uploading",
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )
  end

  # `failures` is whatever Google's partial-failure response contained.
  # When the format isn't yet finalized in Google's docs we conservatively
  # mark all rows as uploaded if the call returned 200 with no obvious
  # failure list, and fail the rows mentioned in any failure structure.
  defp handle_google_result(chunk, []) do
    Conversions.mark_uploaded(chunk, :google)
  end

  defp handle_google_result(chunk, failures) when is_list(failures) do
    failed_idx =
      failures
      |> Enum.map(fn f -> f["index"] || f[:index] end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {failed, ok} =
      chunk
      |> Enum.with_index()
      |> Enum.split_with(fn {_c, idx} -> MapSet.member?(failed_idx, idx) end)

    if ok != [], do: Conversions.mark_uploaded(Enum.map(ok, &elem(&1, 0)), :google)

    if failed != [],
      do:
        Conversions.mark_failed(
          Enum.map(failed, &elem(&1, 0)),
          "google partial: #{inspect(failures)}"
        )
  end

  defp google_integration(site) do
    AdIntegrations.list_for_site(site.id)
    |> Enum.find(&(&1.platform == "google_ads" and &1.status == "active"))
  end

  defp microsoft_integration(site) do
    AdIntegrations.list_for_site(site.id)
    |> Enum.find(&(&1.platform == "bing_ads" and &1.status == "active"))
  end
end
