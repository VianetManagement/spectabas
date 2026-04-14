defmodule Spectabas.Analytics.AnomalyBadges do
  alias Spectabas.Analytics.AnomalyDetector

  @category_to_section %{
    "traffic" => "overview",
    "engagement" => "overview",
    "sources" => "overview",
    "pages" => "overview",
    "seo" => "acquisition",
    "revenue" => "conversions",
    "advertising" => "conversions",
    "retention" => "audience",
    "ad traffic" => "ad_effectiveness"
  }

  def compute(site, user) do
    case AnomalyDetector.detect(site, user) do
      {:ok, anomalies} ->
        Enum.reduce(anomalies, %{}, fn a, acc ->
          section = Map.get(@category_to_section, a.category)

          if section do
            current = Map.get(acc, section)

            if is_nil(current) or severity_rank(a.severity) > severity_rank(current) do
              Map.put(acc, section, a.severity)
            else
              acc
            end
          else
            acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp severity_rank(:high), do: 3
  defp severity_rank(:medium), do: 2
  defp severity_rank(:low), do: 1
  defp severity_rank(_), do: 0
end
