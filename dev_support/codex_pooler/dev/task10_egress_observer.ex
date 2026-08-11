defmodule CodexPooler.Dev.Task10EgressObserver do
  @moduledoc """
  Metadata-only Task 10 egress observer for the local dev runtime.

  Records, per trusted internal request correlator, the *names* of the HTTP
  headers and the *keys* of the websocket `client_metadata` that the gateway
  actually sent to its real upstream. Values, payloads, frames, tokens, and
  prompts are never read, stored, or served. The store is bounded and lives in
  this BEAM only; nothing is persisted.

  Lifecycle is fail-closed: the gateway emits its sanitized egress observation
  event only while `:task10_egress_observation_enabled` is true, and that flag
  is set exclusively by `arm/0` (invoked through the loopback `POST /reset`)
  and cleared by `disarm/0`. Without an explicit arm, the observer records
  nothing and serves an empty capture.

  A name that fails the bounded-ASCII allowlist is replaced by its 12-character
  SHA-256 fingerprint rather than dropped, so a hostile or malformed name can
  never hide from the capture. An unparseable websocket payload marks the
  entry's websocket keys as unknown, which downstream validation rejects —
  absence of evidence is never served as evidence of absence.
  """

  @store __MODULE__.Store
  @handler_id "codex-pooler-task10-egress-observer"
  @event [:codex_pooler, :gateway, :upstream, :egress_observation]
  @flag :task10_egress_observation_enabled
  @identity_header_name "x-task10-egress-observer"
  @identity_header_value "pooler-egress-v1"
  @max_correlators 32
  @max_names 64
  @bounded_name ~r/^[A-Za-z0-9_-]{1,120}$/

  @spec identity_header() :: {String.t(), String.t()}
  def identity_header, do: {@identity_header_name, @identity_header_value}

  @doc "Arms the observer: attach, enable, and clear. Idempotent."
  @spec arm() :: :ok
  def arm do
    ensure_store()
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)

    Application.put_env(:codex_pooler, @flag, true)
    Agent.update(@store, fn _state -> %{} end)
  end

  @doc "Disarms the observer and clears the bounded store."
  @spec disarm() :: :ok
  def disarm do
    Application.put_env(:codex_pooler, @flag, false)
    :telemetry.detach(@handler_id)

    case Process.whereis(@store) do
      nil -> :ok
      _pid -> Agent.update(@store, fn _state -> %{} end)
    end
  end

  @doc "Bounded metadata-only captures keyed by request correlator."
  @spec captures() :: map()
  def captures do
    ensure_store()
    Agent.get(@store, & &1)
  end

  @doc """
  Bounded lifecycle status: whether the gateway emission flag is enabled, how
  many telemetry handlers are attached to the egress event, and how many
  correlator entries the store holds. Counts and booleans only.
  """
  @spec status() :: map()
  def status do
    %{
      "armed" => Application.get_env(:codex_pooler, @flag, false) == true,
      "telemetryHandlers" => length(:telemetry.list_handlers(@event)),
      "captureEntries" => map_size(captures())
    }
  end

  @doc false
  def handle_event(@event, _measurements, metadata, _config) do
    correlator = metadata[:client_request_id]

    if is_binary(correlator) and byte_size(correlator) in 1..120 do
      # The correlator originates from a client-supplied header: it gets the
      # same allowlist-else-fingerprint discipline as every other name, so a
      # raw header value is never stored or served and a non-UTF-8 binary can
      # never poison the JSON surface.
      key = sanitize_name(correlator)
      entry_update = observation_entry(metadata)
      Agent.update(@store, fn state -> record(state, key, entry_update) end)
    end

    :ok
  end

  defp observation_entry(metadata) do
    header_names =
      metadata
      |> Map.get(:header_names, [])
      |> Enum.map(&sanitize_name(String.downcase(to_string(&1))))

    websocket_keys =
      case Map.get(metadata, :websocket_client_metadata, :none) do
        {:keys, keys} -> {:keys, Enum.map(keys, &sanitize_name(to_string(&1)))}
        :unparseable -> :unparseable
        :none -> :none
      end

    %{header_names: header_names, websocket: websocket_keys}
  end

  defp record(state, correlator, entry_update) do
    if map_size(state) >= @max_correlators and not Map.has_key?(state, correlator) do
      state
    else
      existing =
        Map.get(state, correlator, %{
          "httpHeaderNames" => [],
          "websocketClientMetadataKeys" => []
        })

      Map.put(state, correlator, merge_entry(existing, entry_update))
    end
  end

  defp merge_entry(existing, %{header_names: header_names, websocket: websocket}) do
    merged_names =
      case Map.get(existing, "httpHeaderNames", []) do
        nil -> nil
        known -> bounded_union(known, header_names)
      end

    merged_keys =
      case {Map.get(existing, "websocketClientMetadataKeys"), websocket} do
        # An unparseable payload poisons the entry permanently: downstream
        # validation must reject it instead of trusting later observations.
        {nil, _observed} -> nil
        {_known, :unparseable} -> nil
        {known, :none} -> known
        {known, {:keys, keys}} -> bounded_union(known, keys)
      end

    %{"httpHeaderNames" => merged_names, "websocketClientMetadataKeys" => merged_keys}
  end

  # A silent cap could drop a late Lite marker. Overflow poisons the field to
  # nil so downstream validation rejects the entry as malformed instead of
  # trusting a truncated view.
  defp bounded_union(known, incoming) do
    merged =
      known
      |> Enum.concat(incoming)
      |> Enum.uniq()

    if length(merged) > @max_names, do: nil, else: merged
  end

  defp sanitize_name(name) do
    if String.valid?(name) and Regex.match?(@bounded_name, name) do
      name
    else
      :sha256
      |> :crypto.hash(name)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end
  end

  defp ensure_store do
    case Process.whereis(@store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defmodule Plug do
    @moduledoc """
    Loopback capture surface: GET / for captures, GET /status for the bounded
    lifecycle, POST /reset to arm, POST /disarm to stop observing entirely.
    """

    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias CodexPooler.Dev.Task10EgressObserver

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Elixir.Plug.Conn{method: "GET", path_info: []} = conn, _opts) do
      json(conn, 200, serve_captures())
    end

    def call(%Elixir.Plug.Conn{method: "GET", path_info: ["status"]} = conn, _opts) do
      json(conn, 200, Task10EgressObserver.status())
    end

    def call(%Elixir.Plug.Conn{method: "POST", path_info: ["reset"]} = conn, _opts) do
      :ok = Task10EgressObserver.arm()
      json(conn, 200, %{"status" => "reset"})
    end

    # Explicit teardown: detaches the telemetry handler, disables the gateway
    # emission flag, and clears the store, so nothing is observed or retained
    # once a round is finished.
    def call(%Elixir.Plug.Conn{method: "POST", path_info: ["disarm"]} = conn, _opts) do
      :ok = Task10EgressObserver.disarm()
      json(conn, 200, Map.put(Task10EgressObserver.status(), "status", "disarmed"))
    end

    def call(conn, _opts) do
      json(conn, 404, %{"error" => "not_found"})
    end

    defp serve_captures do
      Map.new(Task10EgressObserver.captures(), fn {correlator, entry} ->
        served =
          entry
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        {correlator, served}
      end)
    end

    defp json(conn, status, body) do
      {name, value} = Task10EgressObserver.identity_header()

      conn
      |> put_resp_header(name, value)
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
