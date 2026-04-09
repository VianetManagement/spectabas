defmodule Spectabas.AdIntegrations.HTTP do
  @moduledoc """
  Shared HTTP client for ad/payment integrations with automatic retry
  on transient transport errors (:closed, :timeout, :econnrefused, etc.).
  """

  require Logger

  @max_attempts 3

  @doc "Req.get with retry on transport errors."
  def get(url, opts \\ []) do
    request(:get, url, opts)
  end

  @doc "Req.get! with retry on transport errors."
  def get!(url, opts \\ []) do
    case get(url, opts) do
      {:ok, resp} -> resp
      {:error, error} -> raise error
    end
  end

  @doc "Req.post with retry on transport errors."
  def post(url, opts \\ []) do
    request(:post, url, opts)
  end

  @doc "Req.post! with retry on transport errors."
  def post!(url, opts \\ []) do
    case post(url, opts) do
      {:ok, resp} -> resp
      {:error, error} -> raise error
    end
  end

  defp request(method, url, opts, attempt \\ 1) do
    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    case result do
      {:ok, _} = success ->
        success

      {:error, %Req.TransportError{reason: reason}} when attempt < @max_attempts ->
        Logger.warning(
          "[IntegrationHTTP] #{method} transport error: #{inspect(reason)}, retrying (#{attempt}/#{@max_attempts})..."
        )

        Process.sleep(1_000 * attempt)
        request(method, url, opts, attempt + 1)

      {:error, _} = error ->
        error
    end
  end
end
