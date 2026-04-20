defmodule Spectabas.R2 do
  @moduledoc "Minimal R2/S3-compatible client using Req with AWS Signature V4."

  require Logger

  def configured? do
    bucket() != nil and access_key() != nil and secret_key() != nil and endpoint() != nil
  end

  def upload(key, body, content_type \\ "application/octet-stream") do
    url = object_url(key)
    headers = sign(:put, key, body, content_type)

    case Req.put(url, body: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.notice("[R2] Uploaded #{key} (#{byte_size(body)} bytes)")
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("[R2] Upload failed #{key}: #{status} #{inspect(resp_body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.warning("[R2] Upload error #{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def download(key) do
    url = object_url(key)
    headers = sign(:get, key, "", "")

    case Req.get(url, headers: headers, receive_timeout: 120_000, decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def download_to_file(key, dest_path) do
    case download(key) do
      {:ok, body} ->
        File.mkdir_p!(Path.dirname(dest_path))
        File.write!(dest_path, body)
        {:ok, dest_path}

      error ->
        error
    end
  end

  # Generate a presigned GET URL valid for `expires_in` seconds (default 1 hour)
  def presigned_url(key, expires_in \\ 3600) do
    now = DateTime.utc_now()
    date_stamp = Calendar.strftime(now, "%Y%m%d")
    datetime_stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    region = "auto"
    service = "s3"
    credential = "#{access_key()}/#{date_stamp}/#{region}/#{service}/aws4_request"

    query_params = [
      {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential", credential},
      {"X-Amz-Date", datetime_stamp},
      {"X-Amz-Expires", to_string(expires_in)},
      {"X-Amz-SignedHeaders", "host"}
    ]

    query_string = URI.encode_query(query_params)
    host = URI.parse(endpoint()).host

    canonical_request =
      Enum.join(
        [
          "GET",
          "/#{bucket()}/#{key}",
          query_string,
          "host:#{host}",
          "",
          "host",
          "UNSIGNED-PAYLOAD"
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(
        [
          "AWS4-HMAC-SHA256",
          datetime_stamp,
          "#{date_stamp}/#{region}/#{service}/aws4_request",
          sha256(canonical_request)
        ],
        "\n"
      )

    signing_key = derive_signing_key(date_stamp, region, service)
    signature = hmac_hex(signing_key, string_to_sign)

    "#{endpoint()}/#{bucket()}/#{key}?#{query_string}&X-Amz-Signature=#{signature}"
  end

  # --- Private ---

  defp object_url(key), do: "#{endpoint()}/#{bucket()}/#{key}"

  defp sign(method, key, body, content_type) do
    now = DateTime.utc_now()
    date_stamp = Calendar.strftime(now, "%Y%m%d")
    datetime_stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    region = "auto"
    service = "s3"
    host = URI.parse(endpoint()).host
    body_hash = sha256(body)

    method_str = method |> to_string() |> String.upcase()

    signed_headers =
      if content_type != "" do
        "content-type;host;x-amz-content-sha256;x-amz-date"
      else
        "host;x-amz-content-sha256;x-amz-date"
      end

    canonical_headers =
      if content_type != "" do
        "content-type:#{content_type}\nhost:#{host}\nx-amz-content-sha256:#{body_hash}\nx-amz-date:#{datetime_stamp}\n"
      else
        "host:#{host}\nx-amz-content-sha256:#{body_hash}\nx-amz-date:#{datetime_stamp}\n"
      end

    canonical_request =
      Enum.join(
        [method_str, "/#{bucket()}/#{key}", "", canonical_headers, signed_headers, body_hash],
        "\n"
      )

    scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join(["AWS4-HMAC-SHA256", datetime_stamp, scope, sha256(canonical_request)], "\n")

    signing_key = derive_signing_key(date_stamp, region, service)
    signature = hmac_hex(signing_key, string_to_sign)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{access_key()}/#{scope},SignedHeaders=#{signed_headers},Signature=#{signature}"

    headers =
      [
        {"authorization", auth},
        {"x-amz-date", datetime_stamp},
        {"x-amz-content-sha256", body_hash},
        {"host", host}
      ]

    if content_type != "", do: [{"content-type", content_type} | headers], else: headers
  end

  defp derive_signing_key(date_stamp, region, service) do
    ("AWS4" <> secret_key())
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_hex(key, data), do: hmac(key, data) |> Base.encode16(case: :lower)
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp bucket, do: Application.get_env(:spectabas, :r2_bucket)
  defp access_key, do: Application.get_env(:spectabas, :r2_access_key_id)
  defp secret_key, do: Application.get_env(:spectabas, :r2_secret_access_key)
  defp endpoint, do: Application.get_env(:spectabas, :r2_endpoint)
end
