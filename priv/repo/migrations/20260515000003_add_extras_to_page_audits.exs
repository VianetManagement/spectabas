defmodule Spectabas.Repo.Migrations.AddExtrasToPageAudits do
  use Ecto.Migration

  def change do
    alter table(:page_audits) do
      # v6.10.52: structured payload for the richer audit data —
      # performance timing (nav + paint + LCP + resources), heading
      # hierarchy, viewport meta, twitter card fields, HTML lang
      # attribute, HTTPS flag, text-to-html ratio, all-OG-fields.
      #
      # Single jsonb instead of N columns so we can iterate the audit
      # rubric without more migrations. Read-side access is by key
      # rather than column scans.
      add :extras, :map, default: %{}
    end
  end
end
