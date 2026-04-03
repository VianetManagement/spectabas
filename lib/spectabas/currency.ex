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

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_number(n) when is_integer(n), do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_number(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> n
    end
  end

  defp format_number(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_number(n), do: to_string(n)
end
