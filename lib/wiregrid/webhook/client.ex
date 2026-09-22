defmodule Wiregrid.Webhook.Client do
  import Bitwise

  @moduledoc false

  def validate_destination(url, allowlist)
      when is_binary(url) and byte_size(url) <= 4_096 and is_list(allowlist) do
    with %URI{} = uri <- URI.parse(url),
         true <- uri.scheme == "https",
         host when is_binary(host) <- uri.host,
         :ok <- validate_host(host),
         true <- allowlisted?(host, allowlist),
         :ok <- validate_target(request_target(uri)) do
      :ok
    else
      false -> {:error, :webhook_destination_not_allowed}
      {:error, _} = error -> error
      _ -> {:error, :invalid_webhook_url}
    end
  rescue
    _ -> {:error, :invalid_webhook_url}
  end

  def validate_destination(_, _), do: {:error, :invalid_webhook_url}

  def post(job, cfg) do
    with :ok <- validate_destination(job.url, cfg.allowlist),
         %URI{} = uri <- URI.parse(job.url),
         {:ok, ips} <- resolve_public(uri.host),
         {:ok, ip} <- choose_ip(ips),
         {:ok, socket} <- tls_connect(ip, uri, cfg) do
      try do
        with :ok <- send_request(socket, uri, job),
             {:ok, status} <- read_status(socket, cfg) do
          {:ok, status}
        else
          {:error, reason, retryable} -> {:error, reason, retryable}
          {:error, reason} -> {:error, reason, retryable_reason?(reason)}
          _ -> {:error, :webhook_request_failed, true}
        end
      after
        _ = :ssl.close(socket)
      end
    else
      {:error, reason, retryable} -> {:error, reason, retryable}
      {:error, reason} -> {:error, reason, retryable_reason?(reason)}
    end
  rescue
    _ -> {:error, :webhook_client_exception, true}
  end

  defp resolve_public(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if public_ip?(ip), do: {:ok, [ip]}, else: {:error, :private_destination, false}

      {:error, _} ->
        ipv4 =
          case :inet.getaddrs(String.to_charlist(host), :inet) do
            {:ok, values} -> values
            _ -> []
          end

        ipv6 =
          case :inet.getaddrs(String.to_charlist(host), :inet6) do
            {:ok, values} -> values
            _ -> []
          end

        ips = Enum.uniq(ipv4 ++ ipv6)

        cond do
          ips == [] -> {:error, :dns_resolution_failed, true}
          Enum.any?(ips, &(not public_ip?(&1))) -> {:error, :private_destination, false}
          true -> {:ok, ips}
        end
    end
  end

  defp choose_ip([ip | _]), do: {:ok, ip}

  defp tls_connect(ip, uri, cfg) do
    host = String.to_charlist(uri.host)
    port = uri.port || 443

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: host,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      active: false,
      mode: :binary
    ]

    case :ssl.connect(ip, port, ssl_opts, cfg.connect_timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:error, {:tls_connect_failed, reason}, true}
    end
  end

  defp send_request(socket, uri, job) do
    timestamp = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    with {:ok, signature} <-
           Wiregrid.Webhook.Signature.sign(job.secret, job.id, job.body, timestamp, nonce) do
      target = request_target(uri)
      host = http_host(uri.host)

      host_header =
        if (uri.port || 443) == 443, do: host, else: host <> ":" <> Integer.to_string(uri.port)

      headers =
        [
          {"host", host_header},
          {"content-type", "application/octet-stream"},
          {"content-length", Integer.to_string(byte_size(job.body))},
          {"connection", "close"},
          {"x-wiregrid-id", job.id},
          {"x-wiregrid-timestamp", timestamp},
          {"x-wiregrid-nonce", nonce},
          {"x-wiregrid-signature", signature}
        ] ++ job.headers

      request = ["POST ", target, " HTTP/1.1\r\n", encode_headers(headers), "\r\n", job.body]

      case :ssl.send(socket, request) do
        :ok -> :ok
        {:error, reason} -> {:error, {:send_failed, reason}, true}
      end
    else
      {:error, reason} -> {:error, reason, false}
    end
  end

  defp read_status(socket, cfg), do: read_headers(socket, cfg, <<>>)

  defp read_headers(socket, cfg, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {index, 4} ->
        header_size = index + 4

        if header_size > cfg.max_header_bytes do
          {:error, :response_headers_too_large, false}
        else
          <<headers::binary-size(^header_size), body::binary>> = acc

          with :ok <- validate_response_length(headers, cfg.max_response_bytes),
               true <- byte_size(body) <= cfg.max_response_bytes do
            parse_status(headers)
          else
            false -> {:error, :response_body_too_large, false}
            {:error, _reason, _retryable} = error -> error
          end
        end

      :nomatch ->
        if byte_size(acc) > cfg.max_header_bytes do
          {:error, :response_headers_too_large, false}
        else
          case :ssl.recv(socket, 0, cfg.request_timeout_ms) do
            {:ok, chunk} -> read_headers(socket, cfg, acc <> chunk)
            {:error, :closed} -> {:error, :response_closed_early, true}
            {:error, reason} -> {:error, {:response_read_failed, reason}, true}
          end
        end
    end
  end

  defp validate_response_length(headers, max_bytes) do
    lengths =
      headers
      |> :binary.split("\r\n", [:global])
      |> Enum.flat_map(fn line ->
        case :binary.match(line, ":") do
          {index, 1} ->
            <<name::binary-size(^index), _colon, value::binary>> = line

            if String.downcase(String.trim(name)) == "content-length" do
              case Integer.parse(String.trim(value)) do
                {size, ""} when size >= 0 -> [size]
                _ -> [:invalid]
              end
            else
              []
            end

          :nomatch ->
            []
        end
      end)

    case lengths do
      [] -> :ok
      [size] when size <= max_bytes -> :ok
      [_size] -> {:error, :response_body_too_large, false}
      _ -> {:error, :invalid_content_length, false}
    end
  end

  defp http_host(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp parse_status(headers) do
    case :binary.split(headers, "\r\n", [:global]) do
      [status_line | _] ->
        case :binary.split(status_line, " ", [:global]) do
          ["HTTP/1.1", status | _] -> parse_status_code(status)
          ["HTTP/1.0", status | _] -> parse_status_code(status)
          _ -> {:error, :invalid_http_response, false}
        end

      _ ->
        {:error, :invalid_http_response, false}
    end
  end

  defp parse_status_code(binary) do
    case Integer.parse(binary) do
      {status, ""} when status in 100..599 -> {:ok, status}
      _ -> {:error, :invalid_http_status, false}
    end
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} -> [String.downcase(name), ": ", value, "\r\n"] end)
  end

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if is_binary(uri.query), do: path <> "?" <> uri.query, else: path
  end

  defp validate_target(target) when is_binary(target) and byte_size(target) <= 4_096 do
    if Enum.any?(:binary.bin_to_list(target), fn byte -> byte <= 32 or byte == 127 end),
      do: {:error, :invalid_request_target},
      else: :ok
  end

  defp validate_target(_), do: {:error, :invalid_request_target}

  defp validate_host(host) when is_binary(host) and byte_size(host) in 1..253 do
    bytes = :binary.bin_to_list(host)

    if Enum.all?(bytes, fn ch -> ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch in ~c".-:" end) do
      :ok
    else
      {:error, :non_ascii_hostname}
    end
  end

  defp validate_host(_), do: {:error, :invalid_hostname}

  defp allowlisted?(_host, []), do: false

  defp allowlisted?(host, allowlist) when is_list(allowlist) do
    if Wiregrid.Validation.bounded_list(allowlist, 128) == :ok do
      normalized = String.downcase(host)

      Enum.any?(allowlist, fn
        allowed when is_binary(allowed) ->
          allowed = String.downcase(allowed)

          case allowed do
            "*." <> suffix ->
              normalized != suffix and String.ends_with?(normalized, "." <> suffix)

            _ ->
              normalized == allowed
          end

        _ ->
          false
      end)
    else
      false
    end
  end

  defp retryable_reason?(reason),
    do:
      reason not in [
        :private_destination,
        :webhook_destination_not_allowed,
        :invalid_webhook_url,
        :invalid_hostname,
        :non_ascii_hostname,
        :invalid_request_target
      ]

  defp public_ip?({a, b, c, d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 100 and b in 64..127 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 0 and c == 0 -> false
      a == 192 and b == 0 and c == 2 -> false
      a == 192 and b == 168 -> false
      a == 198 and b in 18..19 -> false
      a == 192 and b == 88 and c == 99 -> false
      a == 198 and b == 51 and c == 100 -> false
      a == 203 and b == 0 and c == 113 -> false
      a >= 224 -> false
      Enum.any?([a, b, c, d], &(&1 < 0 or &1 > 255)) -> false
      true -> true
    end
  end

  defp public_ip?({0, 0, 0, 0, 0, 65_535, hi, lo}) do
    public_ip?({hi >>> 8, hi &&& 255, lo >>> 8, lo &&& 255})
  end

  defp public_ip?({a, b, c, d, e, f, g, h}) do
    first = a

    cond do
      Enum.any?([a, b, c, d, e, f, g, h], &(&1 < 0 or &1 > 65_535)) -> false
      {a, b, c, d, e, f, g, h} == {0, 0, 0, 0, 0, 0, 0, 0} -> false
      {a, b, c, d, e, f, g, h} == {0, 0, 0, 0, 0, 0, 0, 1} -> false
      (first &&& 0xFE00) == 0xFC00 -> false
      (first &&& 0xFFC0) == 0xFE80 -> false
      (first &&& 0xFFC0) == 0xFEC0 -> false
      (first &&& 0xFF00) == 0xFF00 -> false
      a == 0x0100 and b == 0x0000 -> false
      a == 0x0064 and b == 0xFF9B -> false
      a == 0x2001 and b == 0x0000 -> false
      a == 0x2001 and b == 0x0DB8 -> false
      a == 0x2002 -> false
      true -> true
    end
  end

  defp public_ip?(_), do: false
end
