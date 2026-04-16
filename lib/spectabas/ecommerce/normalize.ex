defmodule Spectabas.Ecommerce.Normalize do
  @moduledoc """
  Normalization helpers for ecommerce transaction fields.
  """

  @doc """
  Normalize a short string field: trim, downcase, cap at `max_length` chars.

  Used for `channel` and `source` on ecommerce transactions. Accepts arbitrary
  client values (no allowlist). Non-string inputs become empty string.

  ## Examples

      iex> Spectabas.Ecommerce.Normalize.short_string("  WEB  ")
      "web"

      iex> Spectabas.Ecommerce.Normalize.short_string(nil)
      ""

      iex> Spectabas.Ecommerce.Normalize.short_string(42)
      ""
  """
  def short_string(nil), do: ""

  def short_string(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.slice(0, 64)
  end

  def short_string(_), do: ""
end
