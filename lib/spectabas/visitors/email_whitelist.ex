defmodule Spectabas.Visitors.EmailWhitelist do
  @moduledoc """
  Persistent per-site email allowlist for the scraper detector.

  Solves the case where an external service wants to pre-whitelist a customer
  email *before* that customer has ever visited (so no `visitors` row exists
  yet). When the visitor eventually shows up and is identified via the
  `_sab` cookie + email, `Visitors.identify/4` checks this table and inherits
  `scraper_whitelisted = true` automatically.

  Operations are keyed by `(site_id, email_hash)` so we don't store plaintext
  duplicates and lookups stay fast.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Spectabas.Repo
  alias Spectabas.Visitors.EmailWhitelist

  schema "site_email_whitelist" do
    field :site_id, :id
    field :email, :string
    field :email_hash, :string
    field :source, :string, default: "manual"
    field :added_by_user_id, :id
    field :notes, :string

    timestamps()
  end

  @doc """
  Add an email to a site's allowlist. Idempotent — re-adding refreshes
  source / added_by_user_id / notes / updated_at.
  """
  def add(site_id, email, opts \\ []) do
    case normalize_and_hash(email) do
      {nil, nil} ->
        {:error, :invalid_email}

      {n_email, hash} ->
        attrs = %{
          site_id: site_id,
          email: n_email,
          email_hash: hash,
          source: Keyword.get(opts, :source, "manual"),
          added_by_user_id: Keyword.get(opts, :added_by_user_id),
          notes: Keyword.get(opts, :notes)
        }

        %EmailWhitelist{}
        |> changeset(attrs)
        |> Repo.insert(
          on_conflict: [
            set: [
              source: attrs.source,
              added_by_user_id: attrs.added_by_user_id,
              notes: attrs.notes,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            ]
          ],
          conflict_target: [:site_id, :email_hash]
        )
    end
  end

  @doc """
  Remove an email from a site's allowlist. Returns `{:ok, n}` where `n` is
  the number of rows deleted (0 or 1).
  """
  def remove(site_id, email) do
    case normalize_and_hash(email) do
      {nil, nil} ->
        {:error, :invalid_email}

      {_, hash} ->
        {n, _} =
          Repo.delete_all(
            from(w in EmailWhitelist,
              where: w.site_id == ^site_id and w.email_hash == ^hash
            )
          )

        {:ok, n}
    end
  end

  @doc "Is this email whitelisted on this site?"
  def whitelisted?(_site_id, nil), do: false
  def whitelisted?(_site_id, ""), do: false

  def whitelisted?(site_id, email) when is_binary(email) do
    case normalize_and_hash(email) do
      {_, nil} -> false
      {_, hash} -> whitelisted_by_hash?(site_id, hash)
    end
  end

  def whitelisted?(_site_id, _other), do: false

  @doc "Hash-keyed exists check, for callers that already computed the hash."
  def whitelisted_by_hash?(_site_id, nil), do: false
  def whitelisted_by_hash?(_site_id, ""), do: false

  def whitelisted_by_hash?(site_id, hash) when is_binary(hash) do
    Repo.exists?(
      from(w in EmailWhitelist,
        where: w.site_id == ^site_id and w.email_hash == ^hash
      )
    )
  end

  defp changeset(record, attrs) do
    record
    |> cast(attrs, [:site_id, :email, :email_hash, :source, :added_by_user_id, :notes])
    |> validate_required([:site_id, :email, :email_hash, :source])
    |> unique_constraint([:site_id, :email_hash],
      name: :site_email_whitelist_site_id_email_hash_index
    )
  end

  # Returns {downcased_trimmed_email, sha256_hex} or {nil, nil} for invalid input.
  defp normalize_and_hash(email) when is_binary(email) do
    n = email |> String.trim() |> String.downcase()

    cond do
      n == "" -> {nil, nil}
      not String.contains?(n, "@") -> {nil, nil}
      String.length(n) > 320 -> {nil, nil}
      true -> {n, hash_email(n)}
    end
  end

  defp normalize_and_hash(_), do: {nil, nil}

  defp hash_email(email) do
    :crypto.hash(:sha256, email)
    |> Base.hex_encode32(case: :lower, padding: false)
  end
end
