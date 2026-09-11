defmodule CodexPooler.Status.FeedParser do
  @moduledoc "Bounded, metadata-only parser for the OpenAI status RSS feed."

  @max_bytes 1_000_000
  @max_items 100
  @max_text 4_000
  @max_guid 512
  @max_link 2_048

  @type item :: %{
          guid: String.t(),
          title: String.t(),
          status: String.t(),
          active?: boolean(),
          summary: String.t(),
          component: String.t() | nil,
          link: String.t(),
          published_at: DateTime.t()
        }

  @spec parse(binary(), keyword()) ::
          {:ok, %{items: [item()], content_hash: String.t()}} | {:error, map()}
  def parse(xml, opts \\ [])

  def parse(xml, opts) when is_binary(xml) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      byte_size(xml) > @max_bytes ->
        error(:body_too_large, "feed body exceeds limit")

      byte_size(xml) == 0 ->
        error(:malformed_xml, "feed body is empty")

      Regex.match?(~r/<!(?:DOCTYPE|ENTITY)\b/i, xml) ->
        error(:unsafe_xml, "doctype and entities are not accepted")

      true ->
        parse_xml(xml, now)
    end
  end

  def parse(_, _), do: error(:invalid_body, "feed body must be binary")

  defp parse_xml(xml, now) do
    # xmerl expects the original UTF-8 byte sequence as a charlist. `String.to_charlist/1`
    # turns multibyte characters into codepoints and makes otherwise valid feeds fail.
    {doc, _} = :xmerl_scan.string(:binary.bin_to_list(xml), [{:quiet, true}])
    nodes = :xmerl_xpath.string(~c"//item", doc) |> Enum.map(&elem(&1, 8))

    if length(nodes) > @max_items do
      error(:too_many_items, "feed item count exceeds limit")
    else
      with {:ok, parsed} <- parse_items(nodes, now),
           {:ok, items} <- deduplicate(parsed) do
        hash_fields =
          Enum.map(
            items,
            &Map.take(&1, [
              :guid,
              :title,
              :status,
              :summary,
              :component,
              :link,
              :hash_published_at
            ])
          )

        {:ok,
         %{
           items: Enum.map(items, &Map.delete(&1, :hash_published_at)),
           content_hash: hash(hash_fields)
         }}
      end
    end
  catch
    :exit, _ -> error(:malformed_xml, "feed XML could not be parsed")
    _, _ -> error(:malformed_xml, "feed XML could not be parsed")
  end

  defp parse_items(nodes, now) do
    Enum.reduce_while(nodes, {:ok, []}, fn children, {:ok, acc} ->
      case parse_fields(children, now) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_fields(children, now) do
    fields =
      children
      |> Enum.filter(&match?({:xmlElement, _, _, _, _, _, _, _, _, _, _, _}, &1))
      |> Map.new(fn child -> {local_name(elem(child, 2)), text(child)} end)

    with :ok <- validate_explicit_status(fields),
         {:ok, guid} <- required(fields, "guid", @max_guid),
         {:ok, title} <- required(fields, "title", @max_text),
         {:ok, published_raw} <- required(fields, "pubDate", @max_text),
         {:ok, published} <- parse_date(published_raw, now),
         {:ok, link} <- safe_link(Map.get(fields, "link", "")),
         {:ok, description} <- description(fields),
         {:ok, status_raw} <- extract_status(description, Map.get(fields, "status", "")),
         {:ok, status} <- normalize_status(status_raw),
         {:ok, summary} <- bounded_text(strip_html(description), @max_text) do
      {:ok,
       %{
         guid: guid,
         title: title,
         status: status,
         active?: status != "Resolved",
         summary: summary,
         component: extract_component(description),
         link: link,
         published_at: published,
         hash_published_at: published_raw
       }}
    end
  end

  defp validate_explicit_status(fields) do
    if Map.has_key?(fields, "status") and String.trim(Map.get(fields, "status", "")) == "" do
      error(:missing_status, "status is blank")
    else
      :ok
    end
  end

  defp required(fields, key, limit) do
    value = String.trim(Map.get(fields, key, ""))

    cond do
      value == "" -> error(:missing_field, "required feed field is missing")
      byte_size(value) > limit -> error(:field_too_large, "feed field exceeds limit")
      unsafe_text?(value) -> error(:unsafe_text, "feed field contains unsafe text")
      true -> {:ok, value}
    end
  end

  defp description(fields) do
    value = Map.get(fields, "description", "")
    fallback = Map.get(fields, "encoded", "")

    if String.trim(value) != "",
      do: {:ok, value},
      else:
        if(String.trim(fallback) != "",
          do: {:ok, fallback},
          else: error(:missing_description, "feed description is missing")
        )
  end

  defp extract_status(description, explicit_status) do
    plain = strip_html(description)

    case Regex.run(
           ~r/\bstatus\s*[:\-]?\s*(investigating|identified|monitoring|resolved)\b/i,
           plain
         ) do
      [_, status] ->
        {:ok, status}

      _ ->
        extract_unrecognized_status(plain, explicit_status)
    end
  end

  defp extract_unrecognized_status(plain, explicit_status) do
    case Regex.run(~r/\bstatus\s*[:\-]?\s*([A-Za-z][A-Za-z _-]{0,63})\b/i, plain) do
      [_, status] ->
        case String.trim(status) do
          "" -> error(:missing_status, "status is missing from feed description")
          trimmed -> {:ok, trimmed}
        end

      _ ->
        fallback_status(plain, explicit_status)
    end
  end

  defp fallback_status(plain, explicit_status) do
    case String.trim(explicit_status) do
      "" ->
        if Regex.match?(~r/\bstatus\b/i, plain),
          do: error(:missing_status, "status is missing from feed description"),
          else: error(:missing_field, "required feed field is missing")

      trimmed ->
        {:ok, trimmed}
    end
  end

  defp normalize_status(value) do
    case String.downcase(String.trim(value)) do
      "investigating" -> {:ok, "Investigating"}
      "identified" -> {:ok, "Identified"}
      "monitoring" -> {:ok, "Monitoring"}
      "resolved" -> {:ok, "Resolved"}
      "" -> error(:missing_status, "status is blank")
      _ -> {:ok, "Unknown"}
    end
  end

  defp extract_component(description) do
    plain = strip_html(description)

    case Regex.run(~r/affected\s+components?\s+(.{1,256}?)(?:\s+operational\b|\z)/i, plain) do
      [_, value] ->
        value |> String.trim() |> String.split(~r/\s{2,}|\n/) |> List.first() |> blank_to_nil()

      _ ->
        nil
    end
  end

  defp safe_link(value) do
    value = String.trim(value)

    if byte_size(value) > @max_link,
      do: error(:field_too_large, "feed link exceeds limit"),
      else: do_safe_link(value)
  end

  defp do_safe_link(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: "status.openai.com",
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(path) and path != "" ->
        safe_link_path(port, path)

      _ ->
        error(:unsafe_link, "feed link is not an allowed HTTPS status URL")
    end
  end

  defp safe_link_path(port, _path) when port not in [nil, 443],
    do: error(:unsafe_link, "feed link uses an unsafe port")

  defp safe_link_path(_port, path) do
    normalized = "/" <> String.trim_leading(path, "/")

    if normalized == "/",
      do: error(:unsafe_link, "feed link path is empty"),
      else: {:ok, "https://status.openai.com" <> normalized}
  end

  defp parse_date(value, now) do
    value = String.trim(value)
    parsed = DateTime.from_iso8601(value)
    parsed = if match?({:error, _}, parsed), do: rfc822(value), else: parsed

    case parsed do
      {:ok, dt, _} -> {:ok, if(DateTime.compare(dt, now) == :gt, do: now, else: dt)}
      _ -> error(:invalid_date, "feed date is invalid")
    end
  end

  defp rfc822(value) do
    case Regex.run(
           ~r/^\w{3},\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+(GMT|UTC|[+-]\d{4})$/i,
           value
         ) do
      [_, day, month, year, hh, mm, ss, zone] ->
        months = %{
          "jan" => 1,
          "feb" => 2,
          "mar" => 3,
          "apr" => 4,
          "may" => 5,
          "jun" => 6,
          "jul" => 7,
          "aug" => 8,
          "sep" => 9,
          "oct" => 10,
          "nov" => 11,
          "dec" => 12
        }

        with {:ok, date} <- Date.new(to_int(year), months[String.downcase(month)], to_int(day)),
             {:ok, time} <- Time.new(to_int(hh), to_int(mm), to_int(ss), 0),
             {:ok, dt} <- DateTime.new(date, time, offset(zone)) do
          {:ok, dt, 0}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  rescue
    _ -> {:error, :invalid_date}
  end

  defp offset("GMT"), do: "Etc/UTC"
  defp offset("UTC"), do: "Etc/UTC"

  defp offset(<<sign, hh::binary-size(2), mm::binary-size(2)>>) do
    seconds = (to_int(hh) * 60 + to_int(mm)) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  defp to_int(v), do: String.to_integer(v)

  defp text(node) do
    node
    |> elem(8)
    |> Enum.map_join("", fn
      {:xmlText, _, _, _, value, _} -> List.to_string(value)
      {:xmlElement, _, _, _, _, _, _, _, _, _, _, _} = child -> text(child)
      _ -> ""
    end)
    |> String.trim()
  end

  defp strip_html(value) do
    value
    |> String.replace(~r/<[^>]*>/u, " ")
    |> decode_entities()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp decode_entities(value) do
    value
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> then(&Regex.replace(~r/&#x([0-9a-fA-F]{1,6});/, &1, fn _, hex -> codepoint(hex, 16) end))
    |> then(&Regex.replace(~r/&#([0-9]{1,7});/, &1, fn _, dec -> codepoint(dec, 10) end))
  end

  defp codepoint(value, base) do
    case Integer.parse(value, base) do
      {n, ""} when n > 0 and n <= 0x10FFFF -> <<n::utf8>>
      _ -> " "
    end
  end

  defp bounded_text(value, limit),
    do:
      if(byte_size(value) > limit,
        do: error(:field_too_large, "feed text exceeds limit"),
        else: {:ok, value}
      )

  defp unsafe_text?(value), do: String.contains?(value, <<0>>) or not String.valid?(value)
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp local_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.split(":") |> List.last()

  defp local_name(name) when is_list(name),
    do: name |> List.to_string() |> String.split(":") |> List.last()

  defp deduplicate(items),
    do:
      {:ok,
       items
       |> Enum.group_by(& &1.guid)
       |> Enum.map(fn {_guid, xs} -> Enum.max_by(xs, & &1.published_at, DateTime) end)
       |> Enum.sort_by(& &1.published_at, {:desc, DateTime})}

  defp hash(fields),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(fields, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp error(code, message), do: {:error, %{code: code, message: message}}
end
