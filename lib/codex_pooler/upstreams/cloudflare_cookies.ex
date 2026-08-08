defmodule CodexPooler.Upstreams.CloudflareCookies do
  @moduledoc false

  use GenServer

  @table __MODULE__
  @allowed_cookie_names ~w(
    __cf_bm
    __cflb
    __cfruid
    __cfseq
    __cfwaitingroom
    _cfuvid
    cf_clearance
    cf_ob_info
    cf_use_ob
  )
  @exact_chatgpt_hosts ~w(chatgpt.com chat.openai.com chatgpt-staging.com)
  @chatgpt_subdomain_suffixes ~w(.chatgpt.com .chatgpt-staging.com)
  @http_date_months %{
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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])

        table ->
          table
      end

    {:ok, %{table: table}}
  end

  @spec request_headers(String.t(), [{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def request_headers(url, headers) when is_binary(url) and is_list(headers) do
    case cookie_header(url) do
      nil ->
        headers

      cookie ->
        headers
        |> Enum.reject(fn
          {name, _value} when is_binary(name) -> String.downcase(name) == "cookie"
          _header -> false
        end)
        |> Kernel.++([{"cookie", cookie}])
    end
  end

  @spec store_from_response(String.t(), Req.Response.t()) :: boolean()
  def store_from_response(url, %Req.Response{} = response) when is_binary(url) do
    store_from_set_cookie_headers(url, Req.Response.get_header(response, "set-cookie"))
  end

  @spec store_from_result(String.t(), {:ok, Req.Response.t()} | term()) :: boolean()
  def store_from_result(url, {:ok, %Req.Response{} = response}) when is_binary(url) do
    store_from_response(url, response)
  end

  def store_from_result(_url, _result), do: false

  @spec store_from_headers(String.t(), [{String.t(), String.t()}] | map() | term()) :: boolean()
  def store_from_headers(url, headers) when is_binary(url) do
    store_from_set_cookie_headers(url, set_cookie_headers(headers))
  end

  defp store_from_set_cookie_headers(url, headers) do
    origin = origin_key(url)

    if origin do
      Enum.reduce(headers, false, fn header, stored_any? ->
        store_set_cookie(origin, header) or stored_any?
      end)
    else
      false
    end
  end

  defp set_cookie_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "set-cookie", do: [value], else: []

      value when is_binary(value) ->
        [value]

      _header ->
        []
    end)
  end

  defp set_cookie_headers(%{} = headers) do
    headers
    |> Enum.flat_map(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "set-cookie", do: List.wrap(value), else: []

      _header ->
        []
    end)
    |> Enum.filter(&is_binary/1)
  end

  defp set_cookie_headers(_headers), do: []

  defp store_set_cookie(origin, header) when is_binary(header) do
    case cookie_change(header, System.system_time(:millisecond)) do
      {:store, name, cookie} ->
        if allowed_cookie_name?(name) do
          insert_cookie(origin, name, cookie)
        else
          false
        end

      {:delete, name} ->
        if allowed_cookie_name?(name) do
          delete_cookie(origin, name)
        else
          false
        end

      :ignore ->
        false
    end
  end

  defp store_set_cookie(_origin, _header), do: false

  defp cookie_header(url) do
    with origin when not is_nil(origin) <- origin_key(url),
         pairs when pairs != [] <- cookie_pairs(origin) do
      pairs
      |> Enum.sort_by(fn {name, _pair} -> name end)
      |> Enum.map_join("; ", fn {_name, pair} -> pair end)
    else
      _none -> nil
    end
  end

  defp cookie_pairs(origin) do
    now_ms = System.system_time(:millisecond)

    with_table(
      fn table ->
        table
        |> :ets.match_object({{origin, :_}, :_})
        |> Enum.flat_map(&cookie_pair_entry(table, origin, now_ms, &1))
      end,
      []
    )
  end

  defp cookie_pair_entry(table, origin, now_ms, {{origin, name}, cookie}) do
    case cookie do
      %{pair: pair, expires_at_ms: expires_at_ms} when is_binary(pair) ->
        cookie_pair_entry_from_stored_cookie(table, origin, name, pair, expires_at_ms, now_ms)

      pair when is_binary(pair) ->
        [{name, pair}]

      _cookie ->
        []
    end
  end

  defp cookie_pair_entry(_table, _origin, _now_ms, _entry), do: []

  defp cookie_pair_entry_from_stored_cookie(table, origin, name, pair, expires_at_ms, now_ms) do
    if expired?(expires_at_ms, now_ms) do
      :ets.delete(table, {origin, name})
      []
    else
      [{name, pair}]
    end
  end

  defp insert_cookie(origin, name, cookie) do
    with_table(
      fn table ->
        :ets.insert(table, {{origin, name}, cookie})
        true
      end,
      false
    )
  end

  defp delete_cookie(origin, name) do
    with_table(
      fn table ->
        :ets.delete(table, {origin, name})
        false
      end,
      false
    )
  end

  defp cookie_change(header, now_ms) do
    [pair | attrs] = String.split(header, ";")

    case cookie_pair(pair) do
      {name, value, pair} ->
        expires_at_ms = attrs |> cookie_attributes() |> cookie_expires_at_ms(now_ms)

        cond do
          value == "" -> {:delete, name}
          expired?(expires_at_ms, now_ms) -> {:delete, name}
          true -> {:store, name, %{pair: pair, expires_at_ms: expires_at_ms}}
        end

      _invalid ->
        :ignore
    end
  end

  defp cookie_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, value] -> normalized_cookie_pair(String.trim(name), String.trim(value))
      _invalid -> nil
    end
  end

  defp normalized_cookie_pair("", _value), do: nil
  defp normalized_cookie_pair(name, value), do: {name, value, "#{name}=#{value}"}

  defp cookie_attributes(attrs) do
    Map.new(attrs, fn attr ->
      case String.split(attr, "=", parts: 2) do
        [name, value] -> {attr_name(name), String.trim(value)}
        [name] -> {attr_name(name), true}
      end
    end)
  end

  defp attr_name(name), do: name |> String.trim() |> String.downcase()

  defp cookie_expires_at_ms(attrs, now_ms) do
    case max_age(attrs) do
      {:ok, seconds} -> now_ms + seconds * 1000
      :error -> expires_at_ms(attrs)
    end
  end

  defp max_age(attrs) do
    case Map.get(attrs, "max-age") do
      value when is_binary(value) ->
        case value |> String.trim() |> Integer.parse() do
          {seconds, ""} -> {:ok, seconds}
          _invalid -> :error
        end

      _value ->
        :error
    end
  end

  defp expires_at_ms(attrs) do
    case Map.get(attrs, "expires") do
      value when is_binary(value) -> http_date_to_ms(value)
      _value -> :session
    end
  end

  defp http_date_to_ms(value) do
    with {:ok, {year, month, day}, {hour, minute, second}} <- parse_http_date(value),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.to_unix(datetime, :millisecond)
    else
      _invalid -> :session
    end
  end

  defp parse_http_date(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> parse_http_date_parts()
  end

  defp parse_http_date_parts([weekday, day, month, year, time | _timezone]) do
    parse_http_date_with_weekday(weekday, day, month, year, time)
  end

  defp parse_http_date_parts([weekday, date, time | _timezone]) do
    parse_rfc850_http_date(weekday, date, time)
  end

  defp parse_http_date_parts(_parts), do: :error

  defp parse_http_date_with_weekday(weekday, day, month, year, time)
       when byte_size(weekday) == 4 do
    if String.ends_with?(weekday, ",") do
      parse_http_date_components(day, month, year, time, [2])
    else
      :error
    end
  end

  defp parse_http_date_with_weekday(weekday, day, month, year, time)
       when byte_size(weekday) == 3 do
    parse_http_date_components(month, day, time, year, [1, 2])
  end

  defp parse_http_date_with_weekday(_weekday, _day, _month, _year, _time), do: :error

  defp parse_rfc850_http_date(weekday, date, time) do
    with true <- String.ends_with?(weekday, ","),
         {:ok, day, month, year} <- parse_rfc850_date(date) do
      parse_http_date_components(day, month, "20" <> year, time, [2])
    else
      _invalid -> :error
    end
  end

  defp parse_rfc850_date(date) do
    case String.split(date, "-", parts: 3) do
      [day, month, year]
      when byte_size(day) == 2 and byte_size(month) == 3 and byte_size(year) == 2 ->
        {:ok, day, month, year}

      _invalid ->
        :error
    end
  end

  defp parse_http_date_components(day, month, year, time, day_lengths) do
    if byte_size(month) == 3 and byte_size(year) == 4 and byte_size(time) == 8 and
         byte_size(day) in day_lengths do
      with {:ok, day} <- parse_http_date_number(day),
           {:ok, month} <- Map.fetch(@http_date_months, String.downcase(month)),
           {:ok, year} <- parse_http_date_number(year),
           {:ok, hour, minute, second} <- parse_http_date_time(time) do
        {:ok, {year, month, day}, {hour, minute, second}}
      else
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp parse_http_date_time(value) do
    value
    |> String.split(":", parts: 3)
    |> parse_http_time_parts()
  end

  defp parse_http_time_parts([hour, minute, second])
       when byte_size(hour) == 2 and byte_size(minute) == 2 and byte_size(second) == 2 do
    with {:ok, hour} <- parse_http_date_number(hour),
         {:ok, minute} <- parse_http_date_number(minute),
         {:ok, second} <- parse_http_date_number(second) do
      {:ok, hour, minute, second}
    else
      _invalid -> :error
    end
  end

  defp parse_http_time_parts(_parts), do: :error

  defp parse_http_date_number(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _invalid -> :error
    end
  end

  defp expired?(:session, _now_ms), do: false
  defp expired?(expires_at_ms, now_ms) when is_integer(expires_at_ms), do: expires_at_ms <= now_ms
  defp expired?(_expires_at_ms, _now_ms), do: false

  defp allowed_cookie_name?(name) do
    name in @allowed_cookie_names or String.starts_with?(name, "cf_chl_")
  end

  defp origin_key(url) do
    uri = URI.parse(url)

    case uri do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        port = uri.port || 443
        host = String.downcase(host)

        if chatgpt_host?(host) do
          {"https", host, port}
        end

      _uri ->
        nil
    end
  end

  defp chatgpt_host?(host) do
    host in @exact_chatgpt_hosts or
      Enum.any?(@chatgpt_subdomain_suffixes, &String.ends_with?(host, &1))
  end

  defp with_table(callback, default) when is_function(callback, 1) do
    case :ets.whereis(@table) do
      :undefined ->
        default

      table ->
        callback.(table)
    end
  rescue
    ArgumentError -> default
  catch
    :error, :badarg -> default
  end

  @impl GenServer
  def handle_call(_message, _from, state) do
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(_message, state) do
    {:noreply, state}
  end
end
