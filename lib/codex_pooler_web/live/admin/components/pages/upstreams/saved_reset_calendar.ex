defmodule CodexPoolerWeb.Admin.SavedResetCalendar do
  @moduledoc """
  One-time iCalendar export of an upstream's reported future banked-reset expirations.
  """

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @spec available?(UpstreamIdentity.t(), DateTime.t()) :: boolean()
  def available?(%UpstreamIdentity{} = identity, now \\ DateTime.utc_now()) do
    upcoming_expirations(identity, now) != []
  end

  @spec build(UpstreamIdentity.t(), String.t(), DateTime.t()) :: {:ok, binary()} | {:error, :no_upcoming_expirations}
  def build(%UpstreamIdentity{} = identity, upstream_url, now \\ DateTime.utc_now()) do
    case upcoming_expirations(identity, now) do
      [] ->
        {:error, :no_upcoming_expirations}

      expirations ->
        label = upstream_label(identity)

        lines =
          ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Codex Pooler//Banked reset expirations//EN", "CALSCALE:GREGORIAN"] ++
            Enum.flat_map(expirations, &event_lines(identity.id, label, upstream_url, &1, now)) ++
            ["END:VCALENDAR"]

        {:ok, lines |> Enum.map(&fold_line(&1, 0, [])) |> IO.iodata_to_binary()}
    end
  end

  defp upcoming_expirations(identity, now) do
    snapshot = SavedResets.snapshot(identity, now)

    values =
      case snapshot.available_expirations do
        [] -> snapshot.available_expires_at
        rows -> Enum.map(rows, & &1.expires_at)
      end

    if snapshot.available? do
      values
      |> Enum.flat_map(&future_expiration(&1, now))
      |> Enum.uniq_by(&DateTime.to_unix(&1, :microsecond))
      |> Enum.sort_by(&DateTime.to_unix(&1, :microsecond))
    else
      []
    end
  end

  defp future_expiration(value, now) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> if DateTime.compare(expires_at, now) == :gt, do: [expires_at], else: []
      {:error, _reason} -> []
    end
  end

  defp event_lines(identity_id, label, upstream_url, expires_at, now) do
    digest = :crypto.hash(:sha256, identity_id <> ":" <> DateTime.to_iso8601(expires_at)) |> Base.encode16(case: :lower)

    [
      "BEGIN:VEVENT",
      "UID:banked-reset-#{digest}@codex-pooler.invalid",
      "DTSTAMP:#{timestamp(now)}",
      "DTSTART:#{timestamp(expires_at)}",
      "DURATION:PT1M",
      "SUMMARY:#{escape_text("Banked reset expires — #{label}")}",
      "DESCRIPTION:#{escape_text("A banked reset for upstream #{label} expires at the start of this one-minute calendar marker.\nOpen the upstream to review its current reset bank. This calendar export is a snapshot and does not update after redemption.")}",
      "URL:#{upstream_url}",
      "CLASS:PRIVATE",
      "TRANSP:TRANSPARENT",
      "END:VEVENT"
    ]
  end

  defp upstream_label(%{account_label: label}) when is_binary(label) do
    case String.trim(label) do
      "" -> "Upstream"
      label -> label
    end
  end

  defp upstream_label(_identity), do: "Upstream"

  defp timestamp(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp escape_text(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
  end

  # RFC 5545 folds at 75 octets, including the continuation space, without
  # splitting UTF-8 characters. Every content line terminates in CRLF.
  defp fold_line(<<>>, _size, parts), do: Enum.reverse(["\r\n" | parts])

  defp fold_line(<<codepoint::utf8, rest::binary>>, size, parts) do
    character = <<codepoint::utf8>>
    bytes = byte_size(character)

    if size + bytes > 75 do
      fold_line(rest, bytes + 1, [character, "\r\n " | parts])
    else
      fold_line(rest, size + bytes, [character | parts])
    end
  end
end
