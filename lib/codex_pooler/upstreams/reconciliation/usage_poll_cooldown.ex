defmodule CodexPooler.Upstreams.Reconciliation.UsagePollCooldown do
  @moduledoc """
  The provider-requested pause on reading an upstream's usage endpoints.

  A `429` or `503` answer to a usage read may carry `Retry-After`. Honouring it
  is not a retry policy: it is the one instruction the provider gives us about
  when it is willing to answer again, and ignoring it turns a single throttled
  read into a fallback chain and then into the next minute's probe.

  The pause is scoped to one upstream identity, at one credential epoch, for one
  provider origin, and it lives in that identity's metadata so every replica,
  every Pool assignment sharing the identity, and every entry point - scheduled
  reconciliation, manual refresh, gateway quota refresh, post-reset confirmation
  - reads the same committed deadline. Assignments may point at different usage
  hosts, so origins are kept side by side rather than overwriting one slot.

  What it is not: a circuit breaker, a quota fact, or a reason to refuse a
  generation request. A deferred read reports that it did not happen; the
  ordinary rules about reusing fresh evidence and failing closed on stale
  evidence are unchanged.
  """

  import Ecto.Query

  require Logger

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @metadata_key "usage_poll_cooldown_v1"
  @version 1
  @max_header_bytes 128
  @max_year 9999
  @rfc9110_future_years 50
  @statuses %{429 => "throttled", 503 => "unavailable"}
  @source "retry_after"
  # A pause this long outlasts the quota evidence freshness window several
  # times over (15 minutes by default), so an idle account leaves routing well
  # before usage is read again. Fixed rather than configurable: it only decides
  # whether the operator is told, never how long the pause lasts.
  @long_pause_seconds 3_600

  @type instruction :: {:retry_after, DateTime.t()} | :retry_now | :absent
  @type admission :: :ok | {:deferred, DateTime.t()}
  @type active_pause :: %{
          required(:origin_key) => String.t(),
          required(:not_before) => DateTime.t(),
          required(:status) => String.t() | nil,
          required(:status_code) => pos_integer() | nil,
          required(:source) => String.t() | nil
        }

  @doc """
  The metadata key this record occupies, for callers that must keep it internal.
  """
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  What the provider's `Retry-After` header on this response asks us to do.

  `{:retry_after, at}` is a deadline in the future. `:retry_now` is a valid
  instruction that has already elapsed - stop this fallback chain, because the
  provider did answer with a throttle, but record nothing. `:absent` is no
  usable instruction at all, and the caller keeps whatever it did before.

  Duplicated, overlong, malformed and unrepresentable values are all `:absent`:
  a header we cannot read is not a licence to invent a pause.
  """
  @spec instruction(term(), DateTime.t()) :: instruction()
  def instruction(%Req.Response{} = response, %DateTime{} = received_at) do
    response
    |> Req.Response.get_header("retry-after")
    |> instruction(received_at)
  end

  def instruction([value], %DateTime{} = received_at) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or byte_size(trimmed) > @max_header_bytes do
      :absent
    else
      trimmed |> parse_value(received_at) |> classify(received_at)
    end
  end

  def instruction(_headers, %DateTime{}), do: :absent

  @doc """
  The stable key for a provider origin, derived from where the read is actually
  going rather than from anything a caller supplies.

  Scheme, host and effective port only: path, query and userinfo are not part of
  the provider's identity for throttling, and none of the URL is stored.
  """
  @spec origin_key(term()) :: String.t() | nil
  def origin_key(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        host = String.downcase(String.trim(host))
        scheme = String.downcase(scheme)

        if host == "" do
          nil
        else
          "#{scheme}://#{host}:#{effective_port(uri, scheme)}"
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.encode16(case: :lower)
          |> String.slice(0, 32)
        end

      _unusable ->
        nil
    end
  end

  def origin_key(_url), do: nil

  @doc """
  Whether a usage read for this identity, epoch and origin may go out now.

  The caller passes the metadata it already holds. Reads see whatever was
  committed before them, which is the whole contract: a read admitted before a
  concurrent pause commits may finish, and one admitted after it may not start.
  This is not an in-flight lease.
  """
  @spec admit(map() | nil, pos_integer(), String.t() | nil, DateTime.t()) :: admission()
  def admit(metadata, credential_epoch, origin_key, %DateTime{} = as_of) do
    with %{"not_before" => not_before} <- entry(metadata, credential_epoch, origin_key),
         {:ok, deadline, 0} <- DateTime.from_iso8601(not_before),
         :lt <- DateTime.compare(as_of, deadline) do
      {:deferred, deadline}
    else
      _admitted -> :ok
    end
  end

  @doc """
  The same question against the identity row as currently committed.

  Every outbound usage read re-asks it, because the pause a sibling replica
  committed a moment ago is exactly the one this read must not ignore.
  """
  @spec admit_current(Ecto.UUID.t(), pos_integer(), String.t() | nil, DateTime.t()) :: admission()
  def admit_current(identity_id, credential_epoch, origin_key, %DateTime{} = as_of) do
    Repo.one(from identity in UpstreamIdentity, where: identity.id == ^identity_id, select: identity.metadata)
    |> admit(credential_epoch, origin_key, as_of)
  end

  @doc """
  Persist a provider-requested deadline for one identity, epoch and origin.

  Taken under the identity row lock so a deadline and a credential replacement
  cannot interleave, and merged with `max/2` so neither a later success nor a
  shorter concurrent instruction can shorten a pause the provider asked for.
  A response that arrived for a credential we have since replaced is dropped:
  it says nothing about the credential we hold now.
  """
  @spec record(Ecto.UUID.t(), pos_integer(), String.t(), pos_integer(), DateTime.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def record(identity_id, credential_epoch, origin_key, status, %DateTime{} = not_before, %DateTime{} = as_of)
      when is_binary(origin_key) and is_map_key(@statuses, status) do
    Repo.transaction(fn ->
      case lock_identity(identity_id) do
        %UpstreamIdentity{} = identity ->
          write_deadline(identity, credential_epoch, origin_key, status, not_before, as_of)

        nil ->
          Repo.rollback(:upstream_identity_not_found)
      end
    end)
    |> tap(&maybe_log_long_pause(&1, identity_id, credential_epoch, origin_key, status, not_before, as_of))
  end

  def record(_identity_id, _credential_epoch, _origin_key, _status, %DateTime{}, %DateTime{}),
    do: {:error, :invalid_usage_poll_cooldown}

  @doc """
  The pauses still running for the credential the identity holds at
  `credential_epoch`, longest first.

  This is what `admit/4` would defer on, read the same way: an entry recorded
  for another credential epoch, or one whose deadline has passed, is not a
  pause. Status and source are the bounded vocabulary this module writes; an
  entry carrying anything else still counts as a pause, with `nil` in place of
  the value it cannot name.
  """
  @spec active_pauses(map() | nil, pos_integer() | nil, DateTime.t()) :: [active_pause()]
  def active_pauses(metadata, credential_epoch, %DateTime{} = as_of)
      when is_map(metadata) and is_integer(credential_epoch) do
    case Map.get(metadata, @metadata_key) do
      %{"version" => @version, "credential_epoch" => ^credential_epoch, "origins" => %{} = origins} ->
        origins
        |> Enum.flat_map(fn {origin_key, entry} -> active_pause(origin_key, entry, as_of) end)
        |> Enum.sort_by(&{DateTime.to_unix(&1.not_before, :microsecond), &1.origin_key}, :desc)

      _absent ->
        []
    end
  end

  def active_pauses(_metadata, _credential_epoch, %DateTime{}), do: []

  @doc """
  The bounded status name for a throttling response, or `nil` for a status that
  carries no pause.
  """
  @spec status_name(term()) :: String.t() | nil
  def status_name(status), do: Map.get(@statuses, status)

  # Said once, when the instruction that sets the longer deadline commits: a
  # shorter or equal one merged into it changes nothing and says nothing. Only
  # bounded values are logged - the identity id, the origin digest, the status
  # and the deadline - never the URL or the header as received.
  defp maybe_log_long_pause({:ok, deadline}, identity_id, credential_epoch, origin_key, status, not_before, as_of) do
    pause_seconds = DateTime.diff(not_before, as_of, :second)

    if DateTime.compare(deadline, not_before) == :eq and pause_seconds > @long_pause_seconds do
      Logger.warning(
        "usage polling paused beyond the long-pause threshold by a provider Retry-After " <>
          "upstream_identity_id=#{identity_id} credential_epoch=#{credential_epoch} " <>
          "origin=#{origin_key} status=#{status} paused_until=#{DateTime.to_iso8601(not_before)} " <>
          "pause_seconds=#{pause_seconds} threshold_seconds=#{@long_pause_seconds}"
      )
    end
  end

  defp maybe_log_long_pause(_result, _identity_id, _credential_epoch, _origin_key, _status, _not_before, _as_of), do: :ok

  defp write_deadline(identity, credential_epoch, origin_key, status, not_before, as_of) do
    metadata = identity.metadata || %{}

    if CredentialFencing.current_credential_epoch?(identity, credential_epoch) do
      record = record_for_epoch(metadata, credential_epoch)
      merged = merge_deadline(record["origins"], origin_key, status, not_before, as_of)

      metadata =
        Map.put(metadata, @metadata_key, %{
          "version" => @version,
          "credential_epoch" => credential_epoch,
          "origins" => merged
        })

      identity
      |> UpstreamIdentity.changeset(%{metadata: metadata})
      |> Repo.update!()

      deadline(merged, origin_key) || not_before
    else
      Repo.rollback(:stale_credential_epoch)
    end
  end

  # A record written under another credential epoch describes a credential we no
  # longer hold, so it is replaced rather than merged. Within the current epoch,
  # entries whose deadline has passed are pruned as we write - an expired pause
  # is not protecting anything, and an active one is never evicted to make room.
  defp record_for_epoch(metadata, credential_epoch) do
    case Map.get(metadata, @metadata_key) do
      %{"version" => @version, "credential_epoch" => ^credential_epoch, "origins" => origins} when is_map(origins) ->
        %{"origins" => origins}

      _replaced ->
        %{"origins" => %{}}
    end
  end

  # Pruning is relative to the moment the response arrived, never to the
  # deadline being written: a long pause for one origin must not evict a
  # shorter one that is still running for another.
  defp merge_deadline(origins, origin_key, status, not_before, as_of) do
    origins
    |> prune_expired(as_of)
    |> Map.update(
      origin_key,
      new_entry(status, not_before),
      fn existing -> extend_entry(existing, status, not_before) end
    )
  end

  defp prune_expired(origins, as_of) do
    Enum.reduce(origins, %{}, fn {key, entry}, kept ->
      if active_entry?(entry, as_of), do: Map.put(kept, key, entry), else: kept
    end)
  end

  defp active_entry?(entry, as_of) do
    case entry_deadline(entry) do
      %DateTime{} = deadline -> DateTime.compare(deadline, as_of) == :gt
      nil -> false
    end
  end

  defp extend_entry(existing, status, not_before) do
    case entry_deadline(existing) do
      %DateTime{} = current ->
        if DateTime.compare(current, not_before) == :gt,
          do: existing,
          else: new_entry(status, not_before)

      nil ->
        new_entry(status, not_before)
    end
  end

  defp new_entry(status, not_before) do
    %{
      "not_before" => DateTime.to_iso8601(not_before),
      "status" => Map.fetch!(@statuses, status),
      "source" => @source
    }
  end

  defp active_pause(origin_key, %{} = entry, as_of) when is_binary(origin_key) do
    case entry_deadline(entry) do
      %DateTime{} = deadline ->
        if DateTime.compare(as_of, deadline) == :lt do
          status = known_value(entry["status"], Map.values(@statuses))

          [
            %{
              origin_key: origin_key,
              not_before: deadline,
              status: status,
              status_code: status_code(status),
              source: known_value(entry["source"], [@source])
            }
          ]
        else
          []
        end

      nil ->
        []
    end
  end

  defp active_pause(_origin_key, _entry, _as_of), do: []

  defp status_code(status_name) do
    Enum.find_value(@statuses, fn {code, name} -> if name == status_name, do: code end)
  end

  defp known_value(value, known) do
    if value in known, do: value
  end

  defp deadline(origins, origin_key), do: origins |> Map.get(origin_key) |> entry_deadline()

  defp entry_deadline(%{"not_before" => not_before}) when is_binary(not_before) do
    case DateTime.from_iso8601(not_before) do
      {:ok, deadline, 0} -> deadline
      _unusable -> nil
    end
  end

  defp entry_deadline(_entry), do: nil

  defp entry(metadata, credential_epoch, origin_key) when is_map(metadata) and is_binary(origin_key) do
    case Map.get(metadata, @metadata_key) do
      %{"version" => @version, "credential_epoch" => ^credential_epoch, "origins" => %{} = origins} ->
        case Map.get(origins, origin_key) do
          %{} = entry -> entry
          _missing -> nil
        end

      _absent ->
        nil
    end
  end

  defp entry(_metadata, _credential_epoch, _origin_key), do: nil

  defp lock_identity(identity_id) do
    Repo.one(from identity in UpstreamIdentity, where: identity.id == ^identity_id, lock: "FOR UPDATE")
  end

  defp effective_port(%URI{port: port}, _scheme) when is_integer(port) and port > 0, do: port
  defp effective_port(_uri, "https"), do: 443
  defp effective_port(_uri, "http"), do: 80
  defp effective_port(_uri, _scheme), do: 0

  defp classify(nil, _received_at), do: :absent

  defp classify(%DateTime{} = at, received_at) do
    if DateTime.compare(at, received_at) == :gt, do: {:retry_after, at}, else: :retry_now
  end

  defp parse_value(value, received_at) do
    case delay_seconds(value) do
      {:ok, seconds} -> representable(DateTime.add(received_at, seconds, :second))
      :error -> http_date(value, received_at)
    end
  end

  # `Retry-After` delay-seconds is a nonnegative decimal integer, with no sign
  # and no fraction. Any length the header bound allows is read as written: a
  # delay that lands outside a representable date is rejected by
  # `representable/1`, never quietly shortened into one that fits.
  defp delay_seconds(value) do
    if value =~ ~r/\A\d+\z/ do
      {:ok, String.to_integer(value)}
    else
      :error
    end
  end

  defp representable(%DateTime{year: year} = at) when year <= @max_year, do: at
  defp representable(_overflowed), do: nil

  # The three HTTP-date forms RFC 9110 requires a recipient to accept, read
  # directly from their own shapes. Doing it here rather than through
  # `:httpd_util` keeps the parser inside this release's applications and keeps
  # the two-digit-year rule ours: that function also answers without validating
  # the calendar, so `32 Nov` comes back as a thirty-second of November.
  @imf_fixdate ~r/\A[A-Za-z]{3}, (?<day>\d{2}) (?<month>[A-Za-z]{3}) (?<year>\d{4}) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) GMT\z/
  @rfc850 ~r/\A[A-Za-z]{6,9}, (?<day>\d{2})-(?<month>[A-Za-z]{3})-(?<year>\d{2}) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) GMT\z/
  @asctime ~r/\A[A-Za-z]{3} (?<month>[A-Za-z]{3}) (?<day>[ \d]\d) (?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2}) (?<year>\d{4})\z/

  @months %{
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

  defp http_date(value, received_at) do
    cond do
      captures = Regex.named_captures(@imf_fixdate, value) -> utc_datetime(captures, received_at, :four_digit)
      captures = Regex.named_captures(@asctime, value) -> utc_datetime(captures, received_at, :four_digit)
      captures = Regex.named_captures(@rfc850, value) -> utc_datetime(captures, received_at, :two_digit)
      true -> nil
    end
  end

  defp utc_datetime(captures, received_at, year_form) do
    with {:ok, month} <- Map.fetch(@months, String.downcase(captures["month"])),
         {:ok, date} <- Date.new(calendar_year(captures["year"], year_form, received_at), month, to_integer(captures["day"])),
         {:ok, time} <-
           Time.new(
             to_integer(captures["hour"]),
             to_integer(captures["minute"]),
             to_integer(captures["second"])
           ),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      representable(DateTime.from_naive!(naive, "Etc/UTC"))
    else
      _impossible -> nil
    end
  end

  defp calendar_year(year, :four_digit, _received_at), do: to_integer(year)

  # RFC 9110: a two-digit year that would put the date more than fifty years
  # ahead of the receipt time is the most recent past year with those digits.
  defp calendar_year(year, :two_digit, received_at) do
    candidate = 2000 + to_integer(year)

    if candidate - received_at.year > @rfc9110_future_years,
      do: candidate - 100,
      else: candidate
  end

  defp to_integer(value), do: value |> String.trim() |> String.to_integer()
end
