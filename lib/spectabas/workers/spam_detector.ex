defmodule Spectabas.Workers.SpamDetector do
  @moduledoc """
  Daily Oban worker that detects potential spam referrer domains.
  Runs detect_spam_candidates/0 and logs any findings.
  Does NOT auto-add — candidates are reviewed on the admin Spam Filter page.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Spectabas.Analytics.SpamFilter

  @impl Oban.Worker
  def perform(_job) do
    candidates = SpamFilter.detect_spam_candidates()

    if candidates != [] do
      domains = Enum.map_join(candidates, ", ", & &1.domain)

      Logger.info("[SpamDetector] Found #{length(candidates)} spam candidates: #{domains}")
    else
      Logger.info("[SpamDetector] No new spam candidates detected")
    end

    :ok
  end
end
