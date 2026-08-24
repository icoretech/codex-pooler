defmodule CodexPooler.Dev.GatewayPerfFakeUpstream do
  @moduledoc """
  Deterministic fake upstream for local gateway performance drivers.

  The server is intentionally metadata-only: it selects a fixed pressure profile
  by name and emits synthetic SSE or websocket events without persisting request
  bodies or credentials.
  """

  use Plug.Router

  alias __MODULE__.Websocket

  @default_host "127.0.0.1"
  @default_port 4058
  @default_manifest_path "tmp/gateway-perf/bootstrap/profile-manifest.json"
  @manifest_fields [
    "name",
    "first_event_delay_ms",
    "inter_event_delay_ms",
    "event_count",
    "chunk_bytes",
    "http_status",
    "failure_phase",
    "close_mode",
    "expected_outcome",
    "allowed_statuses"
  ]
  @observation_max_entries 8

  @profiles [
    %{
      "name" => "short-ok",
      "first_event_delay_ms" => 50,
      "inter_event_delay_ms" => 25,
      "event_count" => 20,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "success",
      "allowed_statuses" => [200]
    },
    %{
      "name" => "long-ok",
      "first_event_delay_ms" => 100,
      "inter_event_delay_ms" => 1000,
      "event_count" => 300,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "success",
      "allowed_statuses" => [200]
    },
    %{
      "name" => "large-chunk",
      "first_event_delay_ms" => 50,
      "inter_event_delay_ms" => 100,
      "event_count" => 50,
      "chunk_bytes" => 65_536,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "success",
      "allowed_statuses" => [200]
    },
    %{
      "name" => "slow-first-event",
      "first_event_delay_ms" => 15_000,
      "inter_event_delay_ms" => 25,
      "event_count" => 20,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "timeout_or_classified_failure",
      "allowed_statuses" => [504, 502]
    },
    %{
      "name" => "disconnect-midstream",
      "first_event_delay_ms" => 50,
      "inter_event_delay_ms" => 25,
      "event_count" => 20,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "after_event_5",
      "close_mode" => "client_disconnect",
      "expected_outcome" => "classified_disconnect",
      "allowed_statuses" => [499, 502]
    },
    %{
      "name" => "partial-failure",
      "first_event_delay_ms" => 50,
      "inter_event_delay_ms" => 25,
      "event_count" => 20,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "after_event_5",
      "close_mode" => "upstream_error",
      "expected_outcome" => "classified_failure",
      "allowed_statuses" => [502]
    },
    %{
      "name" => "timeout",
      "first_event_delay_ms" => 999_999,
      "inter_event_delay_ms" => 25,
      "event_count" => 20,
      "chunk_bytes" => 512,
      "http_status" => 200,
      "failure_phase" => "before_first_event",
      "close_mode" => "timeout",
      "expected_outcome" => "timeout",
      "allowed_statuses" => [504]
    },
    %{
      "name" => "quota-429",
      "first_event_delay_ms" => 0,
      "inter_event_delay_ms" => 0,
      "event_count" => 0,
      "chunk_bytes" => 0,
      "http_status" => 429,
      "failure_phase" => "before_stream",
      "close_mode" => "http_error",
      "expected_outcome" => "rate_limited",
      "allowed_statuses" => [429]
    },
    %{
      "name" => "opencode-text-ok",
      "first_event_delay_ms" => 0,
      "inter_event_delay_ms" => 0,
      "event_count" => 8,
      "chunk_bytes" => 2,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "success",
      "allowed_statuses" => [200]
    },
    %{
      "name" => "native-compaction-v2-success",
      "first_event_delay_ms" => 0,
      "inter_event_delay_ms" => 0,
      "event_count" => 2,
      "chunk_bytes" => 0,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "clean_close",
      "expected_outcome" => "success",
      "allowed_statuses" => [200]
    },
    %{
      "name" => "native-compaction-terminal-failure",
      "first_event_delay_ms" => 0,
      "inter_event_delay_ms" => 0,
      "event_count" => 1,
      "chunk_bytes" => 0,
      "http_status" => 200,
      "failure_phase" => "before_none",
      "close_mode" => "upstream_error",
      "expected_outcome" => "classified_failure",
      "allowed_statuses" => [502]
    }
  ]

  @type profile :: %{required(String.t()) => String.t() | non_neg_integer() | [non_neg_integer()]}
  @type parse_result ::
          {:ok,
           %{
             host: String.t(),
             port: non_neg_integer(),
             run_id: String.t(),
             profile_manifest: String.t(),
             profiles: [profile()]
           }}
          | {:error, String.t()}
  @type server :: %{server: pid(), url: String.t(), profiles: [profile()], run_id: String.t()}

  plug :match

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 50_000_000

  plug :dispatch

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  # Bounded metadata-only wire capture. HTTP entries hold lowercased request header
  # *names*; websocket entries hold `client_metadata` *keys* read from the first text
  # frame. No header value, payload, prompt, or credential is retained. This is the one
  # Full-mode fact the correlated Pooler request rows deliberately do not persist.
  get "/__smoke/wire-capture" do
    json(conn, wire_captures())
  end

  get "/__smoke/request-observations" do
    json(conn, %{"observations" => request_observations()})
  end

  post "/__smoke/wire-capture/reset" do
    reset_wire_captures()
    json(conn, %{"status" => "reset"})
  end

  # Smallest deterministic Full catalog this control needs. Product discovery calls
  # GET /backend-api/codex/responses' sibling path with a client_version query and
  # accepts a 200 body under "data", "models", or a bare list. One Full model with
  # use_responses_lite=false is enough to provision a loopback-routed pool; no secret,
  # token, or account value appears here.
  get "/backend-api/codex/models" do
    {conn, _fingerprint} = with_upstream_request_id(conn, :http)
    json(conn, %{"data" => [full_catalog_model()]})
  end

  post "/backend-api/codex/responses" do
    serve_http_stream(conn)
  end

  post "/v1/responses" do
    serve_http_stream(conn)
  end

  post "/v1/chat/completions" do
    serve_http_stream(conn)
  end

  get "/backend-api/codex/responses" do
    serve_websocket(conn)
  end

  get "/v1/responses" do
    serve_websocket(conn)
  end

  match _ do
    json(conn |> put_status(404), %{"error" => %{"code" => "not_found"}})
  end

  @spec parse_args([String.t()]) :: parse_result()
  def parse_args(args) when is_list(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          run_id: :string,
          host: :string,
          port: :integer,
          profile_manifest: :string,
          profiles: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, "invalid options: #{format_invalid_options(invalid)}"}

      rest != [] ->
        {:error, "unexpected arguments: #{Enum.join(rest, " ")}"}

      true ->
        opts = Map.new(opts)

        with {:ok, run_id} <- fetch_required_string(opts, :run_id, "--run-id"),
             {:ok, profiles} <- profiles_from_selector(Map.get(opts, :profiles, "all")),
             {:ok, port} <- normalize_port(Map.get(opts, :port, @default_port)) do
          {:ok,
           %{
             host: Map.get(opts, :host, @default_host),
             port: port,
             run_id: run_id,
             profile_manifest: Map.get(opts, :profile_manifest, @default_manifest_path),
             profiles: profiles
           }}
        end
    end
  end

  @spec start_link(keyword()) :: {:ok, server()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    profiles = Keyword.fetch!(opts, :profiles)
    run_id = Keyword.fetch!(opts, :run_id)
    host = Keyword.get(opts, :host, @default_host)
    port = Keyword.get(opts, :port, @default_port)

    reset_request_observations()

    with {:ok, ip} <- parse_host(host),
         {:ok, server} <-
           Bandit.start_link(
             plug: {__MODULE__, %{profiles: profiles, run_id: run_id}},
             port: port,
             ip: ip,
             startup_log: false
           ),
         {:ok, {_ip, actual_port}} <- ThousandIsland.listener_info(server) do
      {:ok,
       %{
         server: server,
         url: "http://#{host}:#{actual_port}",
         profiles: profiles,
         run_id: run_id
       }}
    end
  end

  @spec stop(server()) :: :ok
  def stop(%{server: server}) do
    ThousandIsland.stop(server)
  catch
    :exit, _reason -> :ok
  end

  @spec run([String.t()]) :: :ok | no_return()
  def run(args) when is_list(args) do
    case parse_args(args) do
      {:ok, config} ->
        {:ok, _apps} = Application.ensure_all_started(:bandit)
        write_manifest!(config.profile_manifest, config.profiles)

        {:ok, server} =
          start_link(
            host: config.host,
            port: config.port,
            profiles: config.profiles,
            run_id: config.run_id
          )

        IO.puts(
          "gateway-perf-fake-upstream listening on #{server.url} run_id=#{config.run_id} profiles=#{profile_selector(config.profiles)} manifest=#{config.profile_manifest}"
        )

        Process.sleep(:infinity)

      {:error, message} ->
        IO.puts(:stderr, "gateway-perf-fake-upstream: #{message}")
        System.halt(2)
    end
  end

  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @spec profile_names() :: [String.t()]
  def profile_names, do: Enum.map(@profiles, & &1["name"])

  @spec manifest_entries([profile()]) :: [profile()]
  def manifest_entries(profiles) when is_list(profiles) do
    Enum.map(profiles, &Map.take(&1, @manifest_fields))
  end

  @spec stream_event_payloads(profile(), map()) :: [map()]
  def stream_event_payloads(profile, payload \\ %{}) when is_map(profile) and is_map(payload) do
    profile
    |> stream_events(payload)
    |> Enum.map(fn {_index, _event, payload} -> payload end)
  end

  @spec write_manifest!(String.t(), [profile()]) :: :ok
  def write_manifest!(path, profiles) when is_binary(path) and is_list(profiles) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode_to_iodata!(manifest_entries(profiles), pretty: true))
  end

  @spec profiles_from_selector(String.t()) :: {:ok, [profile()]} | {:error, String.t()}
  def profiles_from_selector("all"), do: {:ok, @profiles}

  def profiles_from_selector(selector) when is_binary(selector) do
    names = selector |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    by_name = Map.new(@profiles, &{&1["name"], &1})
    unknown = Enum.reject(names, &Map.has_key?(by_name, &1))

    cond do
      names == [] -> {:error, "--profiles must include at least one profile or all"}
      unknown != [] -> {:error, "unknown profiles: #{Enum.join(unknown, ", ")}"}
      true -> {:ok, Enum.map(names, &Map.fetch!(by_name, &1))}
    end
  end

  def init(opts), do: opts

  def call(conn, opts) do
    conn
    |> put_private(:gateway_perf_fake_upstream_opts, opts)
    |> super(opts)
  end

  @full_catalog_model_id "gateway-perf-full"

  @doc """
  Deterministic Full catalog entry served to Pooler catalog discovery.

  `use_responses_lite` is explicitly false so a pool provisioned against this fake is a
  Full-mode target; the wire capture then proves no Lite marker was actually sent.
  """
  @spec full_catalog_model() :: map()
  def full_catalog_model do
    %{
      "id" => @full_catalog_model_id,
      "slug" => @full_catalog_model_id,
      "display_name" => "Gateway perf Full",
      "use_responses_lite" => false,
      "capabilities" => %{
        "responses" => true,
        "streaming" => true,
        "reasoning" => true,
        "tools" => true
      }
    }
  end

  @wire_capture_store __MODULE__.WireCapture
  @wire_capture_correlator_headers ["x-request-id", "x-client-request-id"]
  @wire_capture_max_correlators 32
  @wire_capture_max_names 64
  @upstream_request_id_prefix "perfreq_"

  @doc """
  Generates one bounded synthetic upstream request id.

  The id is returned to the caller in the established `x-request-id` response
  header (HTTP responses and websocket 101 upgrades alike), which the product
  already persists as attempt metadata `upstream_request_id`. Only its
  12-character SHA-256 fingerprint is stored beside the wire capture, so the
  capture entry and the durable Pooler attempt row can be correlated without
  forwarding any new downstream header.
  """
  @spec generate_upstream_request_id() :: String.t()
  def generate_upstream_request_id do
    @upstream_request_id_prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  @doc "12-character lowercase-hex SHA-256 fingerprint of a request id."
  @spec upstream_request_id_fingerprint(String.t()) :: String.t()
  def upstream_request_id_fingerprint(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @doc """
  Returns the bounded metadata-only wire capture keyed by request correlator.

  Values are header *names* and derived websocket client-metadata *keys* only.
  """
  @spec wire_captures() :: map()
  def wire_captures do
    ensure_wire_capture_store()
    Agent.get(@wire_capture_store, & &1)
  end

  @spec reset_wire_captures() :: :ok
  def reset_wire_captures do
    ensure_wire_capture_store()
    Agent.update(@wire_capture_store, fn _state -> %{} end)
  end

  defp ensure_wire_capture_store do
    case Process.whereis(@wire_capture_store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @wire_capture_store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  @observation_store __MODULE__.RequestObservation

  @spec request_observations() :: [map()]
  def request_observations do
    ensure_observation_store()
    Agent.get(@observation_store, & &1)
  end

  @spec reset_request_observations() :: :ok
  def reset_request_observations do
    ensure_observation_store()
    Agent.update(@observation_store, fn _observations -> [] end)
  end

  defp ensure_observation_store do
    case Process.whereis(@observation_store) do
      nil ->
        case Agent.start(fn -> [] end, name: @observation_store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp record_request_observation(
         %Plug.Conn{body_params: body_params, request_path: endpoint} = conn
       )
       when is_map(body_params) do
    input = Map.get(body_params, "input")

    observation = %{
      "endpoint" => endpoint,
      "inputCount" => if(is_list(input), do: length(input), else: 0),
      "terminalCompactionTrigger" =>
        is_list(input) and List.last(input) == %{"type" => "compaction_trigger"},
      "store" => Map.get(body_params, "store"),
      "stream" => Map.get(body_params, "stream")
    }

    ensure_observation_store()
    Agent.update(@observation_store, &Enum.take(&1 ++ [observation], -@observation_max_entries))
    conn
  end

  @doc """
  Records bounded websocket `client_metadata` keys observed in a decoded text frame.

  Only the metadata keys are retained, never their values.
  """
  @spec record_websocket_client_metadata(String.t(), term()) :: :ok
  def record_websocket_client_metadata(key, payload) when is_binary(key) do
    keys = websocket_client_metadata_keys(payload)

    if keys == [] do
      :ok
    else
      ensure_wire_capture_store()

      Agent.update(@wire_capture_store, fn captures ->
        if map_size(captures) >= @wire_capture_max_correlators and
             not Map.has_key?(captures, key) do
          captures
        else
          Map.update(
            captures,
            key,
            new_wire_capture(:websocket, keys, nil),
            &merge_wire_capture(&1, :websocket, keys, nil)
          )
        end
      end)
    end
  end

  defp websocket_client_metadata_keys(payload) do
    case payload do
      %{"client_metadata" => metadata} when is_map(metadata) ->
        metadata
        |> Map.keys()
        |> Enum.filter(&bounded_wire_name?/1)
        |> Enum.uniq()
        |> Enum.take(@wire_capture_max_names)

      _other ->
        []
    end
  end

  # Mints the per-request synthetic upstream request id, returns it in the
  # `x-request-id` response header, and records the bounded capture entry keyed
  # by the downstream correlator header when one exists, or by the id's own
  # fingerprint otherwise (Pooler deliberately forwards no downstream
  # correlator upstream). The raw id is never stored; only its fingerprint.
  defp with_upstream_request_id(conn, transport) do
    upstream_request_id = generate_upstream_request_id()
    fingerprint = upstream_request_id_fingerprint(upstream_request_id)

    conn =
      conn
      |> put_resp_header("x-request-id", upstream_request_id)
      |> record_wire_capture(transport, fingerprint)

    {conn, fingerprint}
  end

  defp record_wire_capture(conn, transport, fingerprint) do
    ensure_wire_capture_store()
    key = wire_capture_key(conn, fingerprint)
    names = wire_capture_names(conn)

    Agent.update(@wire_capture_store, fn captures ->
      if map_size(captures) >= @wire_capture_max_correlators and
           not Map.has_key?(captures, key) do
        captures
      else
        Map.update(
          captures,
          key,
          new_wire_capture(transport, names, fingerprint),
          &merge_wire_capture(&1, transport, names, fingerprint)
        )
      end
    end)

    conn
  end

  defp new_wire_capture(:http, names, fingerprint) do
    put_wire_fingerprint(
      %{"httpHeaderNames" => names, "websocketClientMetadataKeys" => []},
      fingerprint
    )
  end

  defp new_wire_capture(:websocket, names, fingerprint) do
    put_wire_fingerprint(
      %{"httpHeaderNames" => [], "websocketClientMetadataKeys" => names},
      fingerprint
    )
  end

  defp merge_wire_capture(capture, :http, names, fingerprint) do
    capture
    |> Map.put("httpHeaderNames", merge_wire_names(capture["httpHeaderNames"], names))
    |> put_wire_fingerprint(fingerprint)
  end

  defp merge_wire_capture(capture, :websocket, names, fingerprint) do
    capture
    |> Map.put(
      "websocketClientMetadataKeys",
      merge_wire_names(capture["websocketClientMetadataKeys"], names)
    )
    |> put_wire_fingerprint(fingerprint)
  end

  defp put_wire_fingerprint(capture, nil), do: capture

  defp put_wire_fingerprint(capture, fingerprint) when is_binary(fingerprint),
    do: Map.put_new(capture, "upstreamRequestIdFingerprint", fingerprint)

  defp merge_wire_names(existing, names),
    do: (List.wrap(existing) ++ names) |> Enum.uniq() |> Enum.take(@wire_capture_max_names)

  defp wire_capture_key(conn, fingerprint) do
    Enum.find_value(@wire_capture_correlator_headers, fingerprint, fn name ->
      value = first_req_header(conn, name)
      if bounded_wire_name?(value), do: value, else: nil
    end)
  end

  defp wire_capture_names(conn) do
    conn.req_headers
    |> Enum.map(fn {name, _value} -> String.downcase(name) end)
    |> Enum.filter(&bounded_wire_name?/1)
    |> Enum.uniq()
    |> Enum.take(@wire_capture_max_names)
  end

  defp bounded_wire_name?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 120 and
      Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)
  end

  defp serve_http_stream(conn) do
    conn = record_request_observation(conn)
    {conn, _fingerprint} = with_upstream_request_id(conn, :http)

    case selected_profile(conn) do
      {:ok, profile} ->
        respond_with_profile(conn, profile)

      {:error, message} ->
        json(conn |> put_status(400), %{
          "error" => %{"code" => "invalid_profile", "message" => message}
        })
    end
  end

  defp serve_websocket(conn) do
    # The upgrade request carries ordinary HTTP headers, so they are recorded as such.
    # Websocket client metadata is not visible here: it arrives inside the first text
    # frame, and is recorded from that payload rather than inferred from the handshake.
    # The synthetic upstream request id travels on the 101 upgrade response header and
    # its fingerprint keys the entry so the later frame metadata joins the same entry.
    {conn, fingerprint} = with_upstream_request_id(conn, :http)

    case selected_profile(conn) do
      {:ok, profile} ->
        conn
        |> WebSockAdapter.upgrade(
          Websocket,
          %{profile: profile, wire_key: wire_capture_key(conn, fingerprint)},
          []
        )
        |> halt()

      {:error, message} ->
        json(conn |> put_status(400), %{
          "error" => %{"code" => "invalid_profile", "message" => message}
        })
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      json(conn |> put_status(400), %{
        "error" => %{
          "code" => "websocket_upgrade_required",
          "message" => Exception.message(error)
        }
      })
  end

  defp selected_profile(conn) do
    profiles = conn.private.gateway_perf_fake_upstream_opts.profiles
    by_name = Map.new(profiles, &{&1["name"], &1})

    requested_name =
      conn.params["profile"] ||
        first_req_header(conn, "x-gateway-perf-profile") ||
        first_req_header(conn, "x-codex-pooler-perf-profile") ||
        hd(profiles)["name"]

    case Map.fetch(by_name, requested_name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, "unknown profile #{requested_name}"}
    end
  end

  defp first_req_header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp respond_with_profile(conn, %{"http_status" => status} = profile) when status != 200 do
    json(conn |> put_status(status), http_error_payload(profile))
  end

  defp respond_with_profile(conn, profile) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    stream_profile(conn, profile, conn.body_params)
  end

  defp stream_profile(
         conn,
         %{"close_mode" => "timeout", "first_event_delay_ms" => delay_ms},
         _payload
       ) do
    wait_ms(delay_ms)
    conn
  end

  defp stream_profile(conn, profile, payload) do
    profile
    |> stream_events(payload)
    |> Enum.reduce_while(conn, fn {index, event, payload}, conn ->
      maybe_wait_for_event(index, profile)

      case chunk(conn, sse_chunk(event, payload)) do
        {:ok, conn} -> maybe_finish_after_event(conn, index, profile)
        {:error, _reason} -> {:halt, conn}
      end
    end)
    |> maybe_send_done(profile)
  end

  defp stream_events(%{"name" => "opencode-text-ok"}, _payload) do
    response_id = "resp_perf_opencode_text_ok"
    item_id = "msg_perf_opencode_text_ok"
    text = "ok"

    message = %{
      "id" => item_id,
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [output_text(text)]
    }

    response = %{
      "id" => response_id,
      "object" => "response",
      "status" => "completed",
      "output" => [message],
      "usage" => %{
        "input_tokens" => 1,
        "input_tokens_details" => %{"cached_tokens" => 0},
        "output_tokens" => 1,
        "output_tokens_details" => %{"reasoning_tokens" => 0},
        "total_tokens" => 2
      }
    }

    payloads = [
      %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{response | "status" => "in_progress", "output" => [], "usage" => nil}
      },
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{message | "status" => "in_progress", "content" => []}
      },
      %{
        "type" => "response.content_part.added",
        "sequence_number" => 2,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "part" => output_text("")
      },
      %{
        "type" => "response.output_text.delta",
        "sequence_number" => 3,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text,
        "logprobs" => []
      },
      %{
        "type" => "response.output_text.done",
        "sequence_number" => 4,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "text" => text,
        "logprobs" => []
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => 5,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "part" => output_text(text)
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 6,
        "output_index" => 0,
        "item" => message
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 7,
        "response" => response
      }
    ]

    Enum.with_index(payloads, 1)
    |> Enum.map(fn {payload, index} -> {index, payload["type"], payload} end)
  end

  defp stream_events(%{"name" => "native-compaction-v2-success"}, payload) do
    if terminal_compaction_trigger?(payload),
      do: native_compaction_success_events(),
      else: ordinary_events()
  end

  defp stream_events(%{"name" => "native-compaction-terminal-failure"}, payload) do
    if terminal_compaction_trigger?(payload),
      do: native_compaction_failure_events(),
      else: ordinary_events()
  end

  defp stream_events(%{"event_count" => count} = profile, _payload) do
    count = max(count, 0)

    if count == 0 do
      []
    else
      Enum.map(1..count, fn index -> event_payload(index, profile) end)
    end
  end

  defp native_compaction_success_events do
    item = %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-encrypted-compaction",
      "id" => "cmp_native_local",
      "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-native-local"}
    }

    response = %{
      "id" => "resp_native_local",
      "status" => "completed",
      "output" => [item],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
    }

    [
      {1, "response.output_item.done", %{"type" => "response.output_item.done", "item" => item}},
      {2, "response.completed", %{"type" => "response.completed", "response" => response}}
    ]
  end

  defp native_compaction_failure_events do
    [
      {1, "response.failed",
       %{
         "type" => "response.failed",
         "response" => %{
           "status" => "failed",
           "error" => %{
             "code" => "server_error",
             "message" => "synthetic compaction failure"
           }
         }
       }}
    ]
  end

  defp ordinary_events do
    response = %{
      "id" => "resp_native_follow_up",
      "status" => "completed",
      "output" => [],
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
    }

    [{1, "response.completed", %{"type" => "response.completed", "response" => response}}]
  end

  defp terminal_compaction_trigger?(%{"input" => input}) when is_list(input),
    do: List.last(input) == %{"type" => "compaction_trigger"}

  defp terminal_compaction_trigger?(_payload), do: false

  defp output_text(text) do
    %{"type" => "output_text", "annotations" => [], "logprobs" => [], "text" => text}
  end

  defp event_payload(index, %{"event_count" => count} = profile) when index == count do
    {index, "response.completed", completed_payload(profile)}
  end

  defp event_payload(index, profile) do
    {index, "response.output_text.delta", delta_payload(index, profile)}
  end

  defp maybe_wait_for_event(1, %{"first_event_delay_ms" => delay_ms}), do: wait_ms(delay_ms)
  defp maybe_wait_for_event(_index, %{"inter_event_delay_ms" => delay_ms}), do: wait_ms(delay_ms)

  defp maybe_finish_after_event(conn, 5, %{
         "failure_phase" => "after_event_5",
         "close_mode" => "client_disconnect"
       }),
       do: {:halt, conn}

  defp maybe_finish_after_event(conn, 5, %{
         "failure_phase" => "after_event_5",
         "close_mode" => "upstream_error"
       }) do
    {:ok, conn} = chunk(conn, sse_chunk("response.failed", upstream_error_payload()))
    {:halt, conn}
  end

  defp maybe_finish_after_event(conn, _index, _profile), do: {:cont, conn}

  defp maybe_send_done(conn, %{"close_mode" => mode})
       when mode in ["client_disconnect", "upstream_error", "timeout"], do: conn

  defp maybe_send_done(conn, _profile) do
    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp sse_chunk(event, payload),
    do: ["event: ", event, "\n", "data: ", Jason.encode!(payload), "\n\n"]

  defp delta_payload(index, profile) do
    %{
      "type" => "response.output_text.delta",
      "delta" => synthetic_chunk(profile["chunk_bytes"]),
      "index" => index,
      "profile" => profile["name"]
    }
  end

  defp completed_payload(profile) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_perf_#{profile["name"]}",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "profile #{profile["name"]} complete"}
            ]
          }
        ],
        "usage" => %{
          "input_tokens" => 1,
          "output_tokens" => profile["event_count"],
          "total_tokens" => profile["event_count"] + 1
        }
      }
    }
  end

  defp upstream_error_payload do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{"code" => "server_error", "message" => "synthetic upstream profile failure"}
      }
    }
  end

  defp http_error_payload(profile) do
    %{
      "error" => %{
        "code" => "rate_limit_exceeded",
        "message" => "synthetic profile #{profile["name"]} returned #{profile["http_status"]}",
        "type" => "rate_limit_error"
      }
    }
  end

  defp synthetic_chunk(0), do: ""

  defp synthetic_chunk(bytes) when is_integer(bytes) and bytes > 0,
    do: String.duplicate("x", bytes)

  defp json(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, Jason.encode!(payload))
  end

  defp wait_ms(0), do: :ok

  defp wait_ms(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    receive do
    after
      delay_ms -> :ok
    end
  end

  defp parse_host("127.0.0.1"), do: {:ok, {127, 0, 0, 1}}
  defp parse_host("localhost"), do: {:ok, {127, 0, 0, 1}}

  defp parse_host(host) when is_binary(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _reason} -> {:error, {:invalid_host, host}}
    end
  end

  defp fetch_required_string(opts, key, label) do
    case Map.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, "#{label} is required"}
    end
  end

  defp normalize_port(port) when is_integer(port) and port >= 0 and port <= 65_535,
    do: {:ok, port}

  defp normalize_port(_port), do: {:error, "--port must be an integer between 0 and 65535"}

  defp format_invalid_options(invalid) do
    Enum.map_join(invalid, ", ", fn {option, value} -> "#{option}=#{inspect(value)}" end)
  end

  defp profile_selector(profiles) do
    if Enum.map(profiles, & &1["name"]) == profile_names() do
      "all"
    else
      Enum.map_join(profiles, ",", & &1["name"])
    end
  end

  defmodule Websocket do
    @moduledoc false

    alias CodexPooler.Dev.GatewayPerfFakeUpstream

    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:ok, state}

    @impl WebSock
    def handle_in({payload, [opcode: :text]}, %{profile: profile} = state) do
      # Websocket client metadata travels in the frame payload, not the handshake.
      # Only its keys are recorded.
      record_client_metadata(state, payload)

      with {:ok, decoded} <- Jason.decode(payload) do
        case profile["http_status"] do
          200 ->
            push_profile(profile, decoded, state)

          status ->
            {:push,
             {:text,
              Jason.encode!(%{
                "type" => "error",
                "status" => status,
                "error" => %{"code" => "rate_limit_exceeded"}
              })}, state}
        end
      else
        {:error, _reason} -> {:stop, :invalid_json, state}
      end
    end

    def handle_in({_payload, [opcode: :binary]}, state), do: {:stop, :unsupported_binary, state}

    defp record_client_metadata(%{wire_key: wire_key}, payload) when is_binary(wire_key) do
      case Jason.decode(payload) do
        {:ok, decoded} ->
          CodexPooler.Dev.GatewayPerfFakeUpstream.record_websocket_client_metadata(
            wire_key,
            decoded
          )

        {:error, _reason} ->
          :ok
      end
    end

    defp record_client_metadata(_state, _payload), do: :ok

    @impl WebSock
    def handle_info({:gateway_perf_close_websocket, code, reason}, state) do
      {:stop, :normal, {code, reason}, state}
    end

    defp push_profile(
           %{"close_mode" => "timeout", "first_event_delay_ms" => delay_ms},
           _payload,
           state
         ) do
      receive do
      after
        delay_ms -> :ok
      end

      {:ok, state}
    end

    defp push_profile(profile, payload, state) do
      messages =
        profile
        |> GatewayPerfFakeUpstream.stream_event_payloads(payload)
        |> Enum.map(&Jason.encode!/1)

      messages = maybe_limit_failure_messages(messages, profile)

      case profile["close_mode"] do
        "client_disconnect" ->
          send(self(), {:gateway_perf_close_websocket, 1001, "synthetic profile disconnect"})
          {:push, Enum.map(messages, &{:text, &1}), state}

        "upstream_error" ->
          {:push, Enum.map(messages ++ [Jason.encode!(websocket_error_payload())], &{:text, &1}),
           state}

        _mode ->
          {:push, Enum.map(messages, &{:text, &1}), state}
      end
    end

    defp maybe_limit_failure_messages(messages, %{"failure_phase" => "after_event_5"}),
      do: Enum.take(messages, 5)

    defp maybe_limit_failure_messages(messages, _profile), do: messages

    defp websocket_error_payload do
      %{
        "type" => "error",
        "status" => 502,
        "error" => %{"code" => "server_error", "message" => "synthetic upstream profile failure"}
      }
    end
  end
end
