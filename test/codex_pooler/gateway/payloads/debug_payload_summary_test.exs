defmodule CodexPooler.Gateway.Payloads.DebugPayloadSummaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary

  setup do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)
    previous_config = previous_env || []
    previous_logger_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)

      Logger.configure(level: previous_logger_level)
    end)

    %{previous_config: previous_config}
  end

  test "logs only the first twelve safe suffix characters for a valid response id", context do
    enable_gateway_debug(context.previous_config)
    response_id = "resp_abcdefghijklZ"

    {summary, log} = record_with_log(response_id)

    assert log =~ "response_id_preview=resp_abcdefghijkl"
    refute log =~ response_id
    assert_hash_only_summary(summary, response_id, "resp_abcdefghijkl")
  end

  test "logs none for response ids that cannot safely omit a suffix character", context do
    enable_gateway_debug(context.previous_config)

    for response_id <- [
          "resp_abcdefghijkl",
          "resp_abcdefghijk!Z",
          "resp_abcdefghijkéZ",
          "resp_" <> String.duplicate("a", 1_021),
          "arbitrary-response-id"
        ] do
      {summary, log} = record_with_log(response_id)

      assert log =~ "response_id_preview=none"
      refute log =~ response_id
      assert_hash_only_summary(summary, response_id, nil)
    end
  end

  test "debug-disabled recording emits neither a line nor a clear fragment", context do
    disable_gateway_debug(context.previous_config)
    response_id = "resp_abcdefghijklZ"

    {summary, log} = record_with_log(response_id)

    assert is_nil(summary)
    assert log == ""
    refute log =~ "resp_abcdefghijkl"
  end

  defp record_with_log(response_id) do
    with_log([level: :info], fn ->
      payload = %{
        "model" => "gpt-fixture-text",
        "previous_response_id" => response_id,
        "input" => "synthetic"
      }

      DebugPayloadSummary.record(
        "/backend-api/codex/responses",
        payload,
        payload,
        %{request_id: "req_response_preview"},
        "websocket"
      )
    end)
  end

  defp assert_hash_only_summary(summary, response_id, clear_preview) do
    hash_preview = get_in(summary, ["previous_response_id_summary", "preview"])

    assert hash_preview =~ ~r/\A[0-9a-f]{16}\z/
    refute hash_preview == response_id
    refute Map.has_key?(summary, "response_id_preview")

    persisted = DebugPayloadSummary.attempt_metadata(%{gateway_debug_payload: summary})
    persisted_text = inspect(persisted)

    assert get_in(persisted, ["gateway_debug", "previous_response_id_summary", "preview"]) ==
             hash_preview

    refute Map.has_key?(persisted["gateway_debug"], "response_id_preview")
    refute persisted_text =~ response_id

    if clear_preview do
      refute inspect(summary) =~ clear_preview
      refute persisted_text =~ clear_preview
    end
  end

  defp enable_gateway_debug(previous_config) do
    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_config
      |> Keyword.put(:settings, %OperationalSettings{gateway_debug?: true})
      |> Keyword.put(:use_instance_settings?, false)
    )
  end

  defp disable_gateway_debug(previous_config) do
    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_config
      |> Keyword.put(:settings, %OperationalSettings{gateway_debug?: false})
      |> Keyword.put(:use_instance_settings?, false)
    )
  end
end
