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

  @spec stream_event_payloads(profile()) :: [map()]
  def stream_event_payloads(profile) when is_map(profile) do
    profile
    |> stream_events()
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

  defp serve_http_stream(conn) do
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
    case selected_profile(conn) do
      {:ok, profile} ->
        conn
        |> WebSockAdapter.upgrade(Websocket, %{profile: profile}, [])
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

    stream_profile(conn, profile)
  end

  defp stream_profile(conn, %{"close_mode" => "timeout", "first_event_delay_ms" => delay_ms}) do
    wait_ms(delay_ms)
    conn
  end

  defp stream_profile(conn, profile) do
    profile
    |> stream_events()
    |> Enum.reduce_while(conn, fn {index, event, payload}, conn ->
      maybe_wait_for_event(index, profile)

      case chunk(conn, sse_chunk(event, payload)) do
        {:ok, conn} -> maybe_finish_after_event(conn, index, profile)
        {:error, _reason} -> {:halt, conn}
      end
    end)
    |> maybe_send_done(profile)
  end

  defp stream_events(%{"name" => "opencode-text-ok"}) do
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

  defp stream_events(%{"event_count" => count} = profile) do
    count = max(count, 0)

    if count == 0 do
      []
    else
      Enum.map(1..count, fn index -> event_payload(index, profile) end)
    end
  end

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
    def handle_in({_payload, [opcode: :text]}, %{profile: profile} = state) do
      case profile["http_status"] do
        200 ->
          push_profile(profile, state)

        status ->
          {:push,
           {:text,
            Jason.encode!(%{
              "type" => "error",
              "status" => status,
              "error" => %{"code" => "rate_limit_exceeded"}
            })}, state}
      end
    end

    def handle_in({_payload, [opcode: :binary]}, state), do: {:stop, :unsupported_binary, state}

    @impl WebSock
    def handle_info({:gateway_perf_close_websocket, code, reason}, state) do
      {:stop, :normal, {code, reason}, state}
    end

    defp push_profile(%{"close_mode" => "timeout", "first_event_delay_ms" => delay_ms}, state) do
      receive do
      after
        delay_ms -> :ok
      end

      {:ok, state}
    end

    defp push_profile(profile, state) do
      messages =
        profile
        |> GatewayPerfFakeUpstream.stream_event_payloads()
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
