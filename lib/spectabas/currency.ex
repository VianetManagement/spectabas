defmodule Spectabas.Currency do
  @moduledoc "Currency formatting helpers."

  @symbols %{
    "USD" => "$",
    "EUR" => "\u20AC",
    "GBP" => "\u00A3",
    "JPY" => "\u00A5",
    "CAD" => "CA$",
    "AUD" => "A$",
    "CHF" => "CHF",
    "CNY" => "\u00A5",
    "INR" => "\u20B9",
    "BRL" => "R$",
    "MXN" => "MX$",
    "KRW" => "\u20A9",
    "SEK" => "kr",
    "NOK" => "kr",
    "DKK" => "kr",
    "PLN" => "z\u0142",
    "NZD" => "NZ$",
    "SGD" => "S$",
    "HKD" => "HK$",
    "ZAR" => "R"
  }

  @doc """
  Format a number as currency with the appropriate symbol.
  Returns e.g. "$100.00", "€50.00", "£25.00".
  """
  def format(amount, currency \\ "USD") do
    symbol =
      Map.get(@symbols, String.upcase(currency || "USD"), String.upcase(currency || "USD") <> " ")

    amount_str = format_number(amount)
    "#{symbol}#{amount_str}"
  end

  @doc "Get just the currency symbol."
  def symbol(currency) do
    Map.get(@symbols, String.upcase(currency || "USD"), String.upcase(currency || "USD"))
  end

  defp format_number(n) when is_float(n), do: add_commas(:erlang.float_to_binary(n, decimals: 2))

  defp format_number(n) when is_integer(n),
    do: add_commas(:erlang.float_to_binary(n / 1, decimals: 2))

  defp format_number(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> add_commas(:erlang.float_to_binary(f, decimals: 2))
      :error -> n
    end
  end

  defp format_number(%Decimal{} = d), do: add_commas(Decimal.to_string(d, :normal))
  defp format_number(n), do: to_string(n)

  # Add thousand separators: "1234567.89" → "1,234,567.89"
  defp add_commas(s) when is_binary(s) do
    case String.split(s, ".") do
      [int_part, dec_part] ->
        comma_int(int_part) <> "." <> dec_part

      [int_part] ->
        comma_int(int_part)
    end
  end

  defp comma_int("-" <> rest), do: "-" <> comma_int(rest)

  defp comma_int(s) do
    s
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
