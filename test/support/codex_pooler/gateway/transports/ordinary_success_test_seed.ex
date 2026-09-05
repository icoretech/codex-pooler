defmodule CodexPooler.Gateway.Transports.OrdinarySuccessTestSeed do
  @moduledoc false
  import ExUnit.Assertions
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession, as: Upstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession, as: Owner

  def boundary(original) do
    {:ok, server} =
      FakeUpstream.start_link(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{"id" => "resp_seed_authority", "status" => "completed"}
          })
        ])
      )

    {:ok, store} = Agent.start_link(fn -> %{} end)

    boundary = %{
      start: fn ->
        {:ok, real} = Upstream.start_link([])
        {:ok, fake} = original.start.()
        Agent.update(store, &Map.put(&1, real, fake))
        {:ok, real}
      end,
      send: fn real, payload, writer ->
        case payload do
          %Upstream.Request{payload: encoded} = request ->
            if String.contains?(encoded, "ordinary-authority-seed") do
              Upstream.request(real, %{request | writer: writer})
            else
              original.send.(Agent.get(store, &Map.fetch!(&1, real)), payload, writer)
            end

          _ ->
            original.send.(Agent.get(store, &Map.fetch!(&1, real)), payload, writer)
        end
      end,
      close: fn real ->
        fake = Agent.get(store, &Map.get(&1, real))
        if fake && Process.alive?(fake), do: original.close.(fake)
        if Process.alive?(real), do: Upstream.close(real)
      end,
      invalidate: fn real ->
        if original[:invalidate],
          do: original.invalidate.(Agent.get(store, &Map.fetch!(&1, real))),
          else: :ok
      end
    }

    ExUnit.Callbacks.on_exit(fn ->
      FakeUpstream.stop(server)
      if Process.alive?(store), do: Agent.stop(store)
    end)

    {boundary, FakeUpstream.url(server)}
  end

  def request(owner, downstream, binding, url) do
    request = %Upstream.Request{
      url: url <> "/backend-api/codex/responses",
      headers: [],
      payload: Jason.encode!(%{"model" => "ordinary-authority-seed", "input" => []}),
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      effective_serving_mode: "full",
      timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
      writer: nil,
      message_mapper: & &1
    }

    assert {:ok, result} = Owner.submit_request(owner, downstream, request)
    receipt = result.ordinary_success_result

    binding = %{
      binding
      | lifecycle_id: receipt.lifecycle.lifecycle_id,
        generation: receipt.lifecycle.generation,
        previous_response_digest: receipt.response_digest,
        serving_mode: receipt.serving_mode
    }

    {binding, receipt}
  end
end
