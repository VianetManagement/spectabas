defmodule Spectabas.Repo.Migrations.ExpandUrlFields do
  use Ecto.Migration

  def change do
    # URLs easily exceed 255 chars — switch to :text (unlimited)
    alter table(:sessions) do
      modify :entry_url, :text, from: :string
      modify :exit_url, :text, from: :string
      modify :referrer, :text, from: :string
    end

    alter table(:visitors) do
      modify :fingerprint_id, :text, from: :string
      modify :cookie_id, :text, from: :string
    end
  end
end
