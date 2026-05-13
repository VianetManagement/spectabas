defmodule Spectabas.ScraperLabelsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.{Repo, ScraperLabels, Sites}

  defp build_site! do
    Repo.insert!(%Sites.Site{
      name: "Test Site #{System.unique_integer([:positive])}",
      domain: "b.test-#{System.unique_integer([:positive])}.com",
      public_key: "key_#{System.unique_integer([:positive])}",
      active: true,
      gdpr_mode: "off",
      account_id: Spectabas.AccountsFixtures.test_account().id
    })
  end

  defp insert_label!(site, label, source, score, signals, opts \\ []) do
    ScraperLabels.record(
      Keyword.merge(
        [
          site_id: site.id,
          visitor_id: Ecto.UUID.generate(),
          label: label,
          source: source,
          score: score,
          signals: signals,
          tier: tier_for(score)
        ],
        opts
      )
      |> Map.new()
    )
  end

  defp tier_for(s) when s >= 85, do: "certain"
  defp tier_for(s) when s >= 70, do: "suspicious"
  defp tier_for(s) when s >= 40, do: "watching"
  defp tier_for(_), do: "normal"

  describe "signal_correlation_report/1" do
    test "returns zero counts on a site with no labels" do
      site = build_site!()
      report = ScraperLabels.signal_correlation_report(site.id)

      assert report.n_scraper == 0
      assert report.n_not_scraper == 0
      assert report.false_positives == []
      assert report.false_negatives == []
      # Signal stats list still present, all rows showing too_few_labels
      assert Enum.all?(report.signal_stats, &(&1.verdict == :too_few_labels))
    end

    test "computes per-signal P(scraper|signal) and verdicts" do
      site = build_site!()

      # 5 scrapers all with datacenter_asn — should mark underweighted if
      # the current weight is small enough. (datacenter_asn weight is 40,
      # so the heuristic won't fire — but we can verify the counts.)
      for _ <- 1..5 do
        insert_label!(site, "scraper", "manual_flag", 90, ["datacenter_asn", "no_referrer"])
      end

      # 5 not-scrapers with NO datacenter_asn but WITH no_referrer
      for _ <- 1..5 do
        insert_label!(site, "not_scraper", "manual_whitelist", 80, ["no_referrer"])
      end

      report = ScraperLabels.signal_correlation_report(site.id)

      assert report.n_scraper == 5
      assert report.n_not_scraper == 5

      dc = Enum.find(report.signal_stats, &(&1.signal == "datacenter_asn"))
      assert dc.scraper_count == 5
      assert dc.not_scraper_count == 0
      assert dc.ratio == :infinity

      no_ref = Enum.find(report.signal_stats, &(&1.signal == "no_referrer"))
      assert no_ref.scraper_count == 5
      assert no_ref.not_scraper_count == 5
      # Ratio is 1.0 → weak_signal (current weight is 10 which qualifies)
      assert no_ref.ratio == 1.0
      assert no_ref.verdict == :weak_signal
    end

    test "lists false positives (score>=85 + not_scraper) and false negatives (score<40 + scraper)" do
      site = build_site!()

      # False positive: high score, but human said not_scraper
      insert_label!(site, "not_scraper", "manual_whitelist", 95, ["datacenter_asn"])
      # False negative: low score, but human marked scraper
      insert_label!(site, "scraper", "manual_flag", 25, ["no_referrer"])
      # Neither: high score AND scraper agrees, low score AND not_scraper agrees
      insert_label!(site, "scraper", "manual_flag", 95, ["datacenter_asn"])
      insert_label!(site, "not_scraper", "manual_whitelist", 20, [])

      report = ScraperLabels.signal_correlation_report(site.id)

      assert length(report.false_positives) == 1
      assert length(report.false_negatives) == 1

      [fp] = report.false_positives
      assert fp.score == 95
      assert fp.label == "not_scraper"

      [fn_row] = report.false_negatives
      assert fn_row.score == 25
      assert fn_row.label == "scraper"
    end

    test "excludes low-confidence labels (auto-fired) from signal stats by default" do
      site = build_site!()

      # 10 auto-fired flags — should be excluded (source_weight 0.3)
      for _ <- 1..10 do
        insert_label!(site, "scraper", "webhook_auto_flag", 50, ["datacenter_asn"])
      end

      # 0 manual labels
      report = ScraperLabels.signal_correlation_report(site.id)

      assert report.n_scraper == 0
      assert report.n_not_scraper == 0
    end

    test "isolates by site_id" do
      site_a = build_site!()
      site_b = build_site!()

      insert_label!(site_a, "scraper", "manual_flag", 90, ["datacenter_asn"])
      insert_label!(site_b, "not_scraper", "manual_whitelist", 50, ["no_referrer"])

      report_a = ScraperLabels.signal_correlation_report(site_a.id)
      report_b = ScraperLabels.signal_correlation_report(site_b.id)

      assert report_a.n_scraper == 1
      assert report_a.n_not_scraper == 0
      assert report_b.n_scraper == 0
      assert report_b.n_not_scraper == 1
    end
  end
end
