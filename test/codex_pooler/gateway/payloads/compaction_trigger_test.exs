defmodule CodexPooler.Gateway.Payloads.CompactionTriggerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.CompactionTrigger

  @fixture_path Path.expand(
                  "../../../fixtures/codex/rust-v0.149.1-ff29a44391deccde0aba0f8390337d7f3c319ea4/remote_compaction_v2_request.json",
                  __DIR__
                )
  @external_resource @fixture_path

  describe "V2 compaction result transport" do
    test "keeps the historical minimal V2 marker streaming and buffers malformed or nonmatching metadata" do
      assert result_transport(%{
               "client_metadata" => %{
                 "x-codex-turn-metadata" =>
                   Jason.encode!(%{
                     "compaction" => %{"implementation" => "responses_compaction_v2"}
                   })
               }
             }) == :sse

      for payload <- [
            %{"client_metadata" => %{"x-codex-turn-metadata" => "not-json"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => "[]"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => "true"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => Jason.encode!(%{})}},
            %{
              "client_metadata" => %{
                "x-codex-turn-metadata" =>
                  Jason.encode!(%{"compaction" => %{"implementation" => "other"}})
              }
            },
            %{"client_metadata" => ["not", "a", "map"]},
            %{}
          ] do
        assert result_transport(payload) == :buffered
      end
    end

    test "streams the version-pinned rich RemoteCompactionV2 request with additive auto metadata" do
      fixture = load_fixture!()

      assert fixture["fixture_source"] == %{
               "tag" => "rust-v0.149.1",
               "annotated_tag_object" => "980a6d12110b110d29ec13bdcbe14011100b3566",
               "peeled_commit" => "ff29a44391deccde0aba0f8390337d7f3c319ea4",
               "source_paths" => [
                 "codex-rs/core/src/compact_remote_v2_attempt.rs",
                 "codex-rs/core/src/client.rs",
                 "codex-rs/core/src/responses_metadata.rs",
                 "codex-rs/core/src/turn_metadata_tests.rs"
               ]
             }

      assert result_transport(fixture["request"]) == :sse
    end

    test "streams V2 metadata with pre-turn phase and unrelated prompt-like additive metadata" do
      turn_metadata = %{
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "auto",
          "implementation" => "responses_compaction_v2",
          "phase" => "pre_turn"
        },
        "unrelated_additive_metadata" => "synthetic instruction-like content"
      }

      assert result_transport(%{
               "client_metadata" => %{
                 "x-codex-turn-metadata" => Jason.encode!(turn_metadata)
               }
             }) == :sse
    end
  end

  defp result_transport(payload), do: CompactionTrigger.compaction_result_transport(payload)

  defp load_fixture! do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end
end
