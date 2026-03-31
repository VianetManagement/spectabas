defmodule Spectabas.Accounts.ApiAccessLog do
  use Ecto.Schema

  schema "api_access_logs" do
    field :api_key_id, :id
    field :key_prefix, :string
    field :user_id, :id
    field :method, :string
    field :path, :string
    field :site_id, :integer
    field :status_code, :integer
    field :ip_address, :string
    field :user_agent, :string
    field :duration_ms, :integer
    timestamps(updated_at: false)
  end
end
