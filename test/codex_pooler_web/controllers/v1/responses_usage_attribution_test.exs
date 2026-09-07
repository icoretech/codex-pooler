defmodule CodexPoolerWeb.V1.ResponsesUsageAttributionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @usage %{
    "input_tokens" => 123,
    "input_tokens_details" => %{"cached_tokens" => 17},
    "output_tokens" => 45,
    "output_tokens_details" => %{"reasoning_tokens" => 6},
    "total_tokens" => 168
  }

  setup do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)

        :error ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      end
    end)

    :ok
  end

  for transport <- [:http, :websocket], position <- [:before, :after] do
    test "#{transport} SSE preserves aggregate usage with attribution #{position} counters", %{
      conn: conn
    } do
      attribution =
        CodexPooler.JSON.encode!(%{
          "items" => List.duplicate(%{"bytes" => String.duplicate("x", 200)}, 500)
        })

      counters =
        @usage
        |> CodexPooler.JSON.encode!()
        |> String.trim_leading("{")
        |> String.trim_trailing("}")

      usage =
        case unquote(position) do
          :before -> ~s({"attribution":#{attribution},#{counters}})
          :after -> ~s({#{counters},"attribution":#{attribution}})
        end

      terminal =
        ~s({"type":"response.completed","response":{"id":"resp_usage_attribution","status":"completed","usage":#{usage},"output":[]}})

      assert byte_size(terminal) > 65_536

      upstream = start_upstream(FakeUpstream.sse_stream(["data: " <> terminal <> "\n\n"]))
      setup = gateway_setup(upstream)
      session_key = Ecto.UUID.generate()
      conn = conn |> auth(setup)

      conn =
        if unquote(transport) == :websocket,
          do: put_req_header(conn, "x-session-id", session_key),
          else: conn

      try do
        response =
          post(conn, "/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic accounting request",
            "stream" => true
          })

        assert response.status == 200
        assert length(FakeUpstream.requests(upstream)) == 1
        received = completed_data(response.resp_body)
        decoded = CodexPooler.JSON.decode!(received)
        assert is_integer(decoded["sequence_number"])

        assert digest(CodexPooler.JSON.encode!(Map.delete(decoded, "sequence_number"))) ==
                 digest(CodexPooler.JSON.encode!(CodexPooler.JSON.decode!(terminal)))

        assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
        assert request.status == "succeeded"
        assert request.retry_count == 0
        assert request.usage_status == "usage_known"
        assert attempt.usage_status == "usage_known"

        assert attempt.transport ==
                 if(unquote(transport) == :http, do: "http_sse", else: "websocket")

        assert [settlement] =
                 Repo.all(
                   from(e in LedgerEntry,
                     where:
                       e.request_id == ^request.id and e.entry_kind == "settlement" and
                         e.amount_status == "recorded"
                   )
                 )

        assert {settlement.input_tokens, settlement.cached_input_tokens, settlement.output_tokens,
                settlement.reasoning_tokens, settlement.total_tokens} == {123, 17, 45, 6, 168}

        # Standard input 106*10, cached input 17*1, standard output 39*20, reasoning 6*30.
        assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(2_037))
        assert %{items: [log]} = RequestLogs.list(setup.pool, filters: %{request_id: request.id})
        assert log.usage_status == "usage_known"
        assert log.token_counts.cached_input_tokens == 17
        assert log.cost.status == "priced"

        refute inspect({request.request_metadata, attempt.response_metadata, settlement.details}) =~
                 "attribution"
      after
        for session <- Repo.all(from(s in CodexSession, where: s.api_key_id == ^setup.api_key.id)) do
          case WebsocketOwnerSession.lookup(session.id) do
            {:ok, owner} -> GenServer.stop(owner, :normal, 15_000)
            _absent -> :ok
          end
        end
      end
    end
  end

  defp completed_data(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> json ->
        case CodexPooler.JSON.decode(json) do
          {:ok, %{"type" => "response.completed"}} -> json
          _other -> nil
        end

      _line ->
        nil
    end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
end
