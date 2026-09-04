defmodule CodexPooler.Gateway.Runtime.ReplayPreparationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch.ReplayPreparation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Pools.RoutingSettings

  test "original native preparation survives metadata sanitization and replaces replay defaults" do
    original = original_context()
    metadata = original |> ReplayPreparation.attempt_metadata() |> Accounting.sanitize_metadata()

    assert {:ok, restored, settings} =
             ReplayPreparation.restore(RequestOptions.for_websocket(%{}, %{}), metadata)

    assert RequestOptions.model_serving_mode_snapshot(restored) ==
             RequestOptions.model_serving_mode_snapshot(original.request_options)

    assert restored.routing.reasoning_effort_decision ==
             original.request_options.routing.reasoning_effort_decision

    assert restored.routing.supports_reasoning_summary_parameter? == false
    assert %RoutingSettings{request_compression_enabled: true} = settings
    assert restored.continuity.request_claim_key == nil
    assert restored.transport.websocket_owner.enabled? == false
  end

  test "snapshot rejects malformed policy and drops arbitrary fields" do
    metadata = ReplayPreparation.attempt_metadata(original_context())
    snapshot = metadata["native_replay_preparation"]

    sanitized =
      Accounting.sanitize_metadata(%{
        "native_replay_preparation" =>
          Map.merge(snapshot, %{"unknown" => "synthetic", "instructions" => "synthetic"})
      })

    assert sanitized == metadata

    for malformed <- ["synthetic", ["synthetic"], 1, nil] do
      assert Accounting.sanitize_metadata(%{"native_replay_preparation" => malformed}) ==
               %{"native_replay_preparation" => %{}}
    end

    for {key, value} <- [
          {"version", 2},
          {"effective_mode", "invalid"},
          {"reasoning_mode", "invalid"},
          {"applied_effort", "invalid"},
          {"supports_reasoning_summary", "true"},
          {"request_compression_enabled", "true"}
        ] do
      invalid = %{"native_replay_preparation" => Map.put(snapshot, key, value)}

      assert Accounting.sanitize_metadata(invalid) == %{"native_replay_preparation" => %{}}

      assert {:error, :invalid_replay_preparation} =
               ReplayPreparation.restore(RequestOptions.for_websocket(%{}, %{}), invalid)
    end
  end

  test "ordinary and public translated requests do not receive native replay preparation" do
    original = original_context()

    ordinary = RequestOptions.for_websocket(%{websocket_owner_forwarding_enabled?: true}, %{})

    assert ReplayPreparation.attempt_metadata(%{original | request_options: ordinary}) == %{}

    translated =
      RequestOptions.mark_openai_compatibility_origin(
        original.request_options,
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert ReplayPreparation.attempt_metadata(%{original | request_options: translated}) == %{}
  end

  test "restored preparation retains real normalization and token-proven compression" do
    payload = %{
      "model" => "gpt-4o",
      "instructions" => "synthetic instructions",
      "reasoning" => %{"summary" => "auto"},
      "input" => [
        %{
          "type" => "function_call",
          "name" => "sample_tool",
          "call_id" => "call_sample",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_sample",
          "output" => Jason.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)
        }
      ],
      "stream" => true
    }

    original = original_context()
    original = %{original | payload: payload}
    metadata = ReplayPreparation.attempt_metadata(original)

    assert {:ok, restored, settings} =
             ReplayPreparation.restore(RequestOptions.for_websocket(%{}, payload), metadata)

    replay = %{
      original
      | request_options: restored,
        route_state: %{original.route_state | routing_settings: settings}
    }

    {original_bytes, original_compressed, original_opts} = prepared_payload(original)
    {_replay_bytes, replay_compressed, replay_opts} = prepared_payload(replay)

    assert byte_size(original_compressed) < byte_size(original_bytes)
    byte_identical? = original_compressed == replay_compressed
    assert byte_identical?
    assert original_opts.runtime.payload_compression["status"] == "compressed"
    assert replay_opts.runtime.payload_compression["status"] == "compressed"
  end

  defp prepared_payload(context) do
    assert {:ok, bytes, options} =
             PayloadNormalizer.prepare_upstream_payload(
               context.payload,
               context.model,
               context.endpoint,
               context.request_options
             )

    {compressed, options} = RequestCompression.maybe_compress(bytes, context, options)
    {bytes, compressed, options}
  end

  defp original_context do
    options =
      RequestOptions.for_websocket(
        %{
          websocket_owner_forwarding_enabled?: true,
          request_claim_key: "codex-request:" <> Base.url_encode64(<<0::256>>, padding: false),
          replay_claim_digest: <<0::256>>
        },
        %{}
      )
      |> RequestOptions.put_model_serving_mode(%{
        configured_mode: "lite",
        effective_mode: "lite",
        source: "override"
      })
      |> RequestOptions.put_routing(
        reasoning_effort_decision: %Decision{
          mode: :allow_up_to,
          configured_effort: "medium",
          requested_effort: nil,
          applied_effort: "medium"
        },
        supports_reasoning_summary_parameter?: false
      )

    %SelectedCandidateContext{
      model: %Model{exposed_model_id: "gpt-4o", upstream_model_id: "gpt-4o"},
      endpoint: "/backend-api/codex/responses",
      route_class: "proxy_websocket",
      request_options: options,
      route_state:
        RouteState.new(%{
          visible_model: %Model{},
          candidates: [],
          routing_settings: %RoutingSettings{request_compression_enabled: true}
        })
    }
  end
end
