defmodule Spectabas.TypeHelpers do
  @moduledoc "Shared type conversion and query helpers for ClickHouse string values."

  require Logger

  @doc """
  Safely execute an analytics query function, returning fallback on error.
  Logs warnings for non-ok results so errors are observable.
  """
  def safe_query(fun, fallback \\ []) do
    case fun.() do
      {:ok, data} ->
        data

      {:error, reason} ->
        Logger.warning("[Analytics] Query error: #{inspect(reason) |> String.slice(0, 200)}")
        fallback

      other ->
        Logger.warning("[Analytics] Unexpected result: #{inspect(other) |> String.slice(0, 200)}")
        fallback
    end
  rescue
    e ->
      Logger.warning("[Analytics] Query crashed: #{Exception.message(e) |> String.slice(0, 200)}")
      fallback
  end

  def to_num(n) when is_integer(n), do: n
  def to_num(n) when is_float(n), do: trunc(n)

  def to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  def to_num(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0

  def to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def to_float(_), do: 0.0

  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: round(n)

  def to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  def to_int(_), do: 0

  def format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}m #{secs}s"
  end

  def format_duration(_), do: "0m 0s"

  def format_ms(ms) do
    ms = to_num(ms)

    cond do
      ms >= 1000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{ms}ms"
    end
  end

  def format_number(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def format_number(n) when is_number(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_number(n) when is_number(n), do: to_string(n)
  def format_number(n), do: to_string(to_num(n))
end
