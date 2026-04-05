defmodule Spectabas.Repo.Migrations.AddSecurityFields do
  use Ecto.Migration

  def change do
    # Idle timeout preference
    alter table(:users) do
      add :idle_timeout_disabled, :boolean, default: false, null: false
    end

    # Session metadata for active session management
    alter table(:users_tokens) do
      add :ip, :string
      add :user_agent, :string
      add :last_active_at, :utc_datetime
    end

    # Account-level MFA enforcement
    alter table(:accounts) do
      add :require_mfa, :boolean, default: false, null: false
    end
  end
end
