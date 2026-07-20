defmodule CodexPooler.Pools.ModelServingModeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Pools.ModelServingMode

  describe "resolve/3" do
    test "explicit Lite and Full take precedence over catalog evidence" do
      metadata = %{
        "use_responses_lite" => false,
        "source_assignment_models" => %{
          "source-a" => %{"use_responses_lite" => true}
        }
      }

      assert {:ok, %{configured_mode: "lite", effective_mode: "lite", source: "override"}} =
               ModelServingMode.resolve("lite", metadata, ["source-a"])

      assert {:ok, %{configured_mode: "full", effective_mode: "full", source: "override"}} =
               ModelServingMode.resolve("full", metadata, ["source-a"])
    end

    test "Auto uses only literal true from routable source metadata" do
      source_values = [
        {true, "lite"},
        {false, "full"},
        {nil, "full"},
        {"true", "full"},
        {1, "full"},
        {%{"nested" => true}, "full"}
      ]

      for {value, expected_mode} <- source_values do
        metadata = %{
          "use_responses_lite" => false,
          "source_assignment_models" => %{
            "source-a" => %{"use_responses_lite" => value}
          }
        }

        assert {:ok,
                %{
                  configured_mode: "auto",
                  effective_mode: ^expected_mode,
                  source: "catalog"
                }} = ModelServingMode.resolve(nil, metadata, ["source-a"])
      end

      mixed = %{
        "source_assignment_models" => %{
          "source-a" => %{"use_responses_lite" => false},
          "source-b" => %{"use_responses_lite" => true},
          "source-c" => %{"use_responses_lite" => "true"}
        }
      }

      assert {:ok, %{effective_mode: "lite"}} =
               ModelServingMode.resolve(nil, mixed, ["source-a", "source-b"])

      assert {:ok, %{effective_mode: "full"}} =
               ModelServingMode.resolve(nil, mixed, ["source-a", "source-c"])
    end

    test "Auto falls back to aggregate evidence only when the source map is absent or malformed" do
      for metadata <- [
            %{"use_responses_lite" => true},
            %{"use_responses_lite" => true, "source_assignment_models" => nil},
            %{"use_responses_lite" => true, "source_assignment_models" => ["source-a"]}
          ] do
        assert {:ok, %{effective_mode: "lite", source: "catalog"}} =
                 ModelServingMode.resolve(nil, metadata, ["source-a"])
      end

      assert {:ok, %{effective_mode: "full"}} =
               ModelServingMode.resolve(
                 nil,
                 %{
                   "use_responses_lite" => true,
                   "source_assignment_models" => %{"source-a" => %{}}
                 },
                 ["source-a"]
               )
    end

    test "zero routable sources is not a runtime model" do
      assert :no_runtime_model =
               ModelServingMode.resolve(
                 nil,
                 %{"use_responses_lite" => true},
                 []
               )
    end
  end
end
