defmodule CodexPooler.Gateway.Facade.FaultInjectionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.FacadeAssertions

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      deterministic_rotation_seed: 2,
      gateway_setup: 2,
      gateway_upstream: 4,
      prime_routing_quota!: 1,
      put_model_source_assignments!: 2,
      start_upstream: 1,
      use_deterministic_rotation!: 2
    ]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Facade.Anthropic.Stream, as: AnthropicStream
  alias CodexPooler.Gateway.Facade.Ollama.Chat
  alias CodexPooler.Gateway.Facade.Ollama.Stream, as: OllamaStream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Repo

  defmodule RecordingClosedAdapter do
    def chunk(owner, chunk) do
      send(owner, {:facade_closed_chunk, IO.iodata_to_binary(chunk)})
      {:error, :closed}
    end
  end

  test "a connection-stage failure retries before visibility and changes only the account", %{
    conn: conn
  } do
    setup =
      two_upstream_setup(
        FakeUpstream.close_before_headers(),
        success_stream("connected fallback")
      )

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/chat", ollama_payload("connect-stage retry"))

    assert response.status == 200
    assert text_lines(response.resp_body) == ["connected fallback"]
    assert terminal_lines(response.resp_body) |> length() == 1
    assert_cloaked_ndjson(response.resp_body)
    assert FakeUpstream.count(setup.first_upstream) == 1
    assert FakeUpstream.count(setup.second_upstream) == 1
    assert_fixed_target_attempts(setup.pool.id, ["retryable_failed", "succeeded"])
  end

  test "a receive timeout before headers retries without publishing the stalled response", %{
    conn: conn
  } do
    release_ref = make_ref()
    setup_receive_timeout(40)

    setup =
      two_upstream_setup(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref),
        success_stream("timeout fallback")
      )

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/chat", ollama_payload("receive-stage retry"))

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref}

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert response.status == 200
    assert text_lines(response.resp_body) == ["timeout fallback"]
    assert terminal_lines(response.resp_body) |> length() == 1
    assert_cloaked_ndjson(response.resp_body)
    assert FakeUpstream.count(setup.first_upstream) == 1
    assert FakeUpstream.count(setup.second_upstream) == 1
    assert_fixed_target_attempts(setup.pool.id, ["retryable_failed", "succeeded"])
  end

  test "an idle timeout after visible output never retries or duplicates text", %{conn: conn} do
    release_ref = make_ref()
    setup_receive_timeout(40)

    first =
      FakeUpstream.timeout_mid_stream(
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "visible exactly once"
        }),
        notify: self(),
        release_ref: release_ref
      )

    setup = two_upstream_setup(first, success_stream("must not replay"))

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> auth(setup)
      |> post("/api/chat", ollama_payload("idle timeout"))

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref}
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert response.status == 200
    assert text_lines(response.resp_body) == ["visible exactly once"]

    assert terminal_lines(response.resp_body) == [
             %{"done" => true, "error" => "request failed"}
           ]

    refute response.resp_body =~ "must not replay"
    assert_cloaked_ndjson(response.resp_body)
    assert FakeUpstream.count(setup.first_upstream) == 1
    assert FakeUpstream.count(setup.second_upstream) == 0

    assert [attempt] = attempts_for_pool(setup.pool.id)
    assert attempt.status == "failed"
    assert attempt.network_error_code == "stream_idle_timeout"
    assert attempt.upstream_model_id == "gpt-5.6-sol"
  end

  test "partial frames and a missing terminal emit each text and tool exactly once" do
    source =
      IO.iodata_to_binary([
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "one answer"
        }),
        event("response.output_item.added", %{
          "type" => "response.output_item.added",
          "output_index" => 1,
          "item" => %{
            "type" => "function_call",
            "id" => "facade-provider-tool-id",
            "name" => "read_file",
            "arguments" => ""
          }
        }),
        event("response.function_call_arguments.done", %{
          "type" => "response.function_call_arguments.done",
          "output_index" => 1,
          "item_id" => "facade-provider-tool-id",
          "arguments" => ~s({"path":"README.md"})
        })
      ])

    chunks = split_every(source, 7)

    {ollama_output, ollama_state} =
      normalize_chunks(OllamaStream, OllamaStream.new(ollama_formatting()), chunks)

    {ollama_terminal, ollama_state} = OllamaStream.synthetic_terminal_failure(ollama_state)
    ollama_lines = ndjson(ollama_output <> ollama_terminal)

    assert Enum.map(text_lines_from_lines(ollama_lines), &get_in(&1, ["message", "content"])) == [
             "one answer"
           ]

    assert [ollama_tool] =
             Enum.filter(ollama_lines, &is_list(get_in(&1, ["message", "tool_calls"])))

    assert [
             %{
               "function" => %{
                 "name" => "read_file",
                 "arguments" => %{"path" => "README.md"}
               }
             }
           ] = get_in(ollama_tool, ["message", "tool_calls"])

    assert terminal_lines_from_lines(ollama_lines) == [
             %{"done" => true, "error" => "request failed"}
           ]

    assert {:failed, _failure} = OllamaStream.terminal_outcome(ollama_state)
    assert {nil, ^ollama_state} = OllamaStream.synthetic_terminal_failure(ollama_state)
    assert_cloaked_ndjson(Enum.map_join(ollama_lines, "\n", &Jason.encode!/1) <> "\n")

    {anthropic_output, anthropic_state} =
      normalize_chunks(AnthropicStream, AnthropicStream.new(anthropic_formatting()), chunks)

    {anthropic_terminal, anthropic_state} =
      AnthropicStream.synthetic_terminal_failure(anthropic_state)

    anthropic_sse = anthropic_output <> anthropic_terminal
    anthropic_events = sse_events(anthropic_sse)

    assert ["one answer"] ==
             anthropic_events
             |> Enum.filter(&(get_in(&1, ["data", "delta", "type"]) == "text_delta"))
             |> Enum.map(&get_in(&1, ["data", "delta", "text"]))

    assert [tool_start] =
             Enum.filter(
               anthropic_events,
               &(get_in(&1, ["data", "content_block", "type"]) == "tool_use")
             )

    assert get_in(tool_start, ["data", "content_block", "name"]) == "read_file"

    assert [tool_delta] =
             Enum.filter(
               anthropic_events,
               &(get_in(&1, ["data", "delta", "type"]) == "input_json_delta")
             )

    assert Jason.decode!(get_in(tool_delta, ["data", "delta", "partial_json"])) == %{
             "path" => "README.md"
           }

    assert Enum.count(anthropic_events, &(&1["event"] == "error")) == 1
    assert {:failed, _failure} = AnthropicStream.terminal_outcome(anthropic_state)
    assert {nil, ^anthropic_state} = AnthropicStream.synthetic_terminal_failure(anthropic_state)
    assert_cloaked_sse(anthropic_sse)
  end

  test "oversized incomplete blocks terminate safely once and retain no private tail" do
    private_tail = "facade-provider-private-sentinel"

    for {adapter, state} <- [
          {OllamaStream, OllamaStream.new(ollama_formatting())},
          {AnthropicStream, AnthropicStream.new(anthropic_formatting())}
        ] do
      prefix = "event: response.output_text.delta\ndata: "

      oversized =
        prefix <>
          String.duplicate("x", adapter.max_incomplete_frame_bytes() - byte_size(prefix) + 1) <>
          private_tail

      {output, state} = adapter.normalize_data(oversized, state)
      assert {:failed, _failure} = adapter.terminal_outcome(state)
      assert {nil, ^state} = adapter.synthetic_terminal_failure(state)
      refute output =~ private_tail

      if adapter == OllamaStream do
        assert ndjson(output) == [%{"done" => true, "error" => "request failed"}]
        assert_cloaked_ndjson(output)
      else
        assert [%{"event" => "error"}] = sse_events(output)
        assert_cloaked_sse(output)
      end
    end
  end

  test "a downstream disconnect cancels the active stream without retrying another account" do
    release_ref = make_ref()
    setup_receive_timeout(40)

    upstream =
      start_upstream(
        FakeUpstream.timeout_mid_stream(
          event("response.output_text.delta", %{
            "type" => "response.output_text.delta",
            "delta" => "client saw this once"
          }),
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = facade_gateway_setup(upstream)
    {:ok, authenticated} = Access.authenticate_authorization_header(setup.authorization)

    client_payload = ollama_payload("disconnect after first visible chunk")

    assert {:ok, coerced} =
             Chat.coerce(client_payload, %{
               persona: Persona.fixed(:ollama_chat),
               upstream_endpoint: "/backend-api/codex/responses"
             })

    assert {:ok, %{stream: stream}} =
             Gateway.execute(
               authenticated,
               coerced.endpoint,
               coerced.payload,
               coerced.request_options
             )

    closed_conn = %{
      Phoenix.ConnTest.build_conn()
      | adapter: {RecordingClosedAdapter, self()},
        state: :chunked
    }

    result = stream.(closed_conn)

    assert_receive {:fake_upstream_timeout_barrier, :mid_stream, upstream_pid, ^release_ref}
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert {:ok, %Plug.Conn{}} = result
    assert_receive {:facade_closed_chunk, first_chunk}
    assert Jason.decode!(String.trim(first_chunk))["done"] == false

    assert get_in(Jason.decode!(String.trim(first_chunk)), ["message", "content"]) ==
             "client saw this once"

    assert_receive {:facade_closed_chunk, terminal_chunk}

    assert Jason.decode!(String.trim(terminal_chunk)) == %{
             "done" => true,
             "error" => "request failed"
           }

    refute_receive {:facade_closed_chunk, _duplicate}
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert request.retry_count == 0

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
    assert attempt.upstream_model_id == "gpt-5.6-sol"
  end

  test "an Anthropic stream interruption after visibility emits one sanitized error and no replay",
       %{conn: conn} do
    setup =
      two_upstream_setup(
        FakeUpstream.abrupt_close_mid_stream([
          {"response.output_text.delta",
           %{
             "type" => "response.output_text.delta",
             "delta" => "anthropic once"
           }}
        ]),
        success_stream("must not replay anthropic")
      )

    response =
      conn
      |> put_req_header("x-request-id", deterministic_rotation_seed(2, 0))
      |> put_req_header("anthropic-version", "2023-06-01")
      |> auth(setup)
      |> post("/v1/messages", %{
        "model" => "gemma3",
        "max_tokens" => 128,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "interrupt"}]
      })

    assert response.status == 200
    events = sse_events(response.resp_body)

    assert ["anthropic once"] ==
             events
             |> Enum.filter(&(get_in(&1, ["data", "delta", "type"]) == "text_delta"))
             |> Enum.map(&get_in(&1, ["data", "delta", "text"]))

    assert Enum.count(events, &(&1["event"] == "error")) == 1
    refute response.resp_body =~ "must not replay anthropic"
    assert_cloaked_sse(response.resp_body)
    assert FakeUpstream.count(setup.first_upstream) == 1
    assert FakeUpstream.count(setup.second_upstream) == 0
  end

  defp two_upstream_setup(first_mode, second_mode) do
    first_upstream = start_upstream(first_mode)
    second_upstream = start_upstream(second_mode)
    setup = facade_gateway_setup(first_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        second_upstream,
        "facade-upstream-credential-sentinel",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_deterministic_rotation!(setup.pool, 2)

    model = put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    setup
    |> Map.put(:model, model)
    |> Map.put(:first_upstream, first_upstream)
    |> Map.put(:second_upstream, second_upstream)
  end

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: "gpt-5.6-sol",
      upstream_model_id: "gpt-5.6-sol",
      pricing_ref: "gpt-5.6-sol",
      display_name: "Facade fixed target",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max",
        "input_modalities" => ["text", "image"]
      }
    )
  end

  defp setup_receive_timeout(timeout_ms) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{upstream_receive_timeout_ms: timeout_ms})
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp assert_fixed_target_attempts(pool_id, statuses) do
    attempts = attempts_for_pool(pool_id)
    assert Enum.map(attempts, & &1.status) == statuses
    assert Enum.all?(attempts, &(&1.upstream_model_id == "gpt-5.6-sol"))
  end

  defp attempts_for_pool(pool_id) do
    Repo.all(
      from(a in Attempt,
        join: r in Request,
        on: r.id == a.request_id,
        where: r.pool_id == ^pool_id,
        order_by: [asc: a.attempt_number]
      )
    )
  end

  defp ollama_payload(content) do
    %{
      "stream" => true,
      "messages" => [%{"role" => "user", "content" => content}]
    }
  end

  defp success_stream(text) do
    FakeUpstream.sse_stream([
      {"response.output_text.delta",
       %{
         "type" => "response.output_text.delta",
         "delta" => text
       }},
      {"response.completed",
       %{
         "type" => "response.completed",
         "provider" => "facade-provider-private-sentinel",
         "response" => %{
           "id" => "facade-provider-request-id-sentinel",
           "status" => "completed",
           "model" => "facade-provider-private-sentinel",
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => text}]
             }
           ],
           "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
         }
       }}
    ])
  end

  defp ollama_formatting do
    %{
      surface: :chat,
      stream?: true,
      think?: false,
      stops: [],
      started_at: System.monotonic_time()
    }
  end

  defp anthropic_formatting do
    %{stream?: true, think?: false, stops: [], max_tokens: 128}
  end

  defp normalize_chunks(adapter, state, chunks) do
    Enum.reduce(chunks, {[], state}, fn chunk, {output, state} ->
      {data, state} = adapter.normalize_data(chunk, state)
      {[output, data], state}
    end)
    |> then(fn {output, state} -> {IO.iodata_to_binary(output), state} end)
  end

  defp split_every(binary, size), do: do_split_every(binary, size, [])
  defp do_split_every("", _size, chunks), do: Enum.reverse(chunks)

  defp do_split_every(binary, size, chunks) do
    take = min(byte_size(binary), size)
    <<chunk::binary-size(^take), rest::binary>> = binary
    do_split_every(rest, size, [chunk | chunks])
  end

  defp text_lines(body), do: body |> ndjson() |> text_lines_from_lines() |> Enum.map(&text/1)

  defp text_lines_from_lines(lines) do
    Enum.filter(lines, fn
      %{"done" => false, "message" => %{"content" => content}} when content != "" -> true
      %{"done" => false, "response" => content} when content != "" -> true
      _line -> false
    end)
  end

  defp text(%{"message" => %{"content" => content}}), do: content
  defp text(%{"response" => content}), do: content

  defp terminal_lines(body), do: body |> ndjson() |> terminal_lines_from_lines()
  defp terminal_lines_from_lines(lines), do: Enum.filter(lines, &(&1["done"] == true))

  defp ndjson(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp sse_events(body) do
    body
    |> String.split(~r/\r?\n\r?\n/, trim: true)
    |> Enum.map(fn block ->
      fields =
        block
        |> String.split(~r/\r?\n/)
        |> Map.new(fn line ->
          case String.split(line, ":", parts: 2) do
            [key, " " <> value] -> {key, value}
            [key, value] -> {key, value}
            [key] -> {key, ""}
          end
        end)

      %{"event" => fields["event"], "data" => Jason.decode!(fields["data"])}
    end)
  end

  defp event(name, payload) do
    "event: #{name}\ndata: #{Jason.encode!(payload)}\n\n"
  end
end
