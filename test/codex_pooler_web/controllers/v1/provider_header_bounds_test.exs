defmodule CodexPoolerWeb.V1.ProviderHeaderBoundsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  # findings#238: a provider response header value that reaches the attempt
  # row or a quota window is bounded, never erased. A plain ASCII value inside
  # its class pattern and byte length persists in cleartext, anything else as
  # a 12-character SHA-256 fingerprint, and a blank value is absent. These run
  # end to end so the bound is proven on the persisted row, not on the writer
  # in isolation.

  # Failure-detection budget for the asynchronously written quota window: a
  # green run returns as soon as the row exists.
  @detection_timeout_ms 15_000

  @completed_response %{
    "id" => "resp_provider_header_bounds",
    "object" => "response",
    "status" => "completed",
    "output" => [],
    "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
  }

  test "an overlong request id and an oversized content type persist as fingerprints", %{
    conn: conn
  } do
    overlong_request_id = "req_" <> String.duplicate("a", 140)
    parameter_tail = Enum.map_join(1..30, "; ", &"p#{&1}=1")
    content_type = "application/json; charset=utf-8; " <> parameter_tail

    upstream =
      start_upstream(
        FakeUpstream.raw_response(CodexPooler.JSON.encode!(@completed_response),
          headers: [{"content-type", content_type}, {"x-oai-request-id", overlong_request_id}]
        )
      )

    attempt = dispatch_and_fetch_attempt!(conn, upstream)

    assert attempt.response_metadata["upstream_request_id"] == fingerprint(overlong_request_id)
    assert attempt.response_metadata["content_type"] == fingerprint(content_type)

    metadata_text = inspect(attempt.response_metadata)
    refute metadata_text =~ overlong_request_id
    refute metadata_text =~ parameter_tail
  end

  test "a request id and a content type inside their bounds persist in cleartext", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response_with_headers(@completed_response, [
          {"x-oai-request-id", "req_clear.01:abc-XYZ"}
        ])
      )

    attempt = dispatch_and_fetch_attempt!(conn, upstream)

    assert attempt.response_metadata["upstream_request_id"] == "req_clear.01:abc-XYZ"
    assert attempt.response_metadata["content_type"] == "application/json; charset=utf-8"
  end

  test "a blank request id is absent rather than fingerprinted", %{conn: conn} do
    upstream =
      start_upstream(FakeUpstream.json_response_with_headers(@completed_response, [{"x-oai-request-id", ""}]))

    attempt = dispatch_and_fetch_attempt!(conn, upstream)

    refute Map.has_key?(attempt.response_metadata, "upstream_request_id")
  end

  test "a quota limit name outside the identifier bound is stored as a fingerprint", %{conn: conn} do
    reset_at =
      DateTime.utc_now()
      |> DateTime.add(600, :second)
      |> DateTime.to_unix()
      |> Integer.to_string()

    hostile_name = "Synthetic Limit Name " <> String.duplicate("z", 80)

    headers =
      window_headers("codex-bounded-clear", reset_at, "synthetic-limit-model.v2") ++
        window_headers("codex-bounded-hostile", reset_at, hostile_name) ++
        window_headers("codex-bounded-blank", reset_at, "")

    upstream = start_upstream(FakeUpstream.json_response_with_headers(@completed_response, headers))
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic quota limit name bounds"
      })

    assert response.status == 200

    clear = await_header_window!(setup.identity, "codex_bounded_clear")
    assert clear.limit_name == "synthetic-limit-model.v2"
    assert clear.raw_limit_name == "synthetic-limit-model.v2"
    assert clear.model == "synthetic-limit-model.v2"

    hostile = await_header_window!(setup.identity, "codex_bounded_hostile")
    assert hostile.limit_name == fingerprint(hostile_name)
    assert hostile.raw_limit_name == fingerprint(hostile_name)
    assert hostile.model == fingerprint(hostile_name)
    refute inspect(hostile) =~ "Synthetic Limit Name"

    blank = await_header_window!(setup.identity, "codex_bounded_blank")
    assert is_nil(blank.limit_name)
    assert is_nil(blank.raw_limit_name)
  end

  defp window_headers(limit, reset_at, limit_name) do
    [
      {"x-#{limit}-primary-used-percent", "12"},
      {"x-#{limit}-primary-window-minutes", "300"},
      {"x-#{limit}-primary-reset-at", reset_at},
      {"x-#{limit}-limit-name", limit_name}
    ]
  end

  defp dispatch_and_fetch_attempt!(conn, upstream) do
    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic provider header bounds"
      })

    assert response.status == 200
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    attempt
  end

  # Header quota evidence is written during finalization; the window is read
  # back with a bounded poll of the authoritative rows.
  defp await_header_window!(identity, raw_limit_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_response_headers" and &1.raw_limit_id == raw_limit_id))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> await_header_window!(identity, raw_limit_id, deadline)
          end
        else
          flunk("expected a Codex response header quota window for #{raw_limit_id}")
        end

      window ->
        window
    end
  end

  defp fingerprint(value) do
    "sha256_" <>
      (:crypto.hash(:sha256, value)
       |> Base.encode16(case: :lower)
       |> String.slice(0, 12))
  end
end
