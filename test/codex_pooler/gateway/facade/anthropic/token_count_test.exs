defmodule CodexPooler.Gateway.Facade.Anthropic.TokenCountTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Anthropic.TokenCount

  @png Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>)

  test "counts the same normalized system, message, image, and tool representation locally" do
    payload = %{
      "model" => "ignored-client-alias",
      "system" => [%{"type" => "text", "text" => "System fixture"}],
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Inspect"},
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => @png
              }
            }
          ]
        },
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_count",
              "name" => "lookup",
              "input" => %{"q" => "weather"}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_count",
              "content" => "cloudy"
            }
          ]
        }
      ],
      "tools" => [
        %{
          "name" => "lookup",
          "description" => "Lookup fixture",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}}
          }
        }
      ],
      "thinking" => %{"type" => "adaptive"}
    }

    assert {:ok, %{"input_tokens" => count}} = TokenCount.count(payload)
    assert is_integer(count) and count > 0

    assert {:ok, %{"input_tokens" => ^count}} =
             TokenCount.count(Map.put(payload, "model", "another-arbitrary-alias"))

    refute inspect(TokenCount.count(payload)) =~ "o200k"
    refute inspect(TokenCount.count(payload)) =~ "gpt-5.6-sol"
  end

  test "uses a fixed image placeholder instead of tokenizing base64 bytes" do
    base = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => @png
              }
            }
          ]
        }
      ]
    }

    larger_png =
      @png
      |> Base.decode64!()
      |> Kernel.<>(String.duplicate(<<0>>, 3_000))
      |> Base.encode64()

    assert {:ok, %{"input_tokens" => count}} = TokenCount.count(base)

    assert {:ok, %{"input_tokens" => ^count}} =
             TokenCount.count(
               put_in(
                 base,
                 ["messages", Access.at(0), "content", Access.at(0), "source", "data"],
                 larger_png
               )
             )
  end

  test "adds explicit framing for additional roles, blocks, and tools" do
    one = %{"messages" => [%{"role" => "user", "content" => "same text"}]}

    two = %{
      "messages" => [
        %{"role" => "user", "content" => "same text"},
        %{"role" => "assistant", "content" => "same text"}
      ]
    }

    with_tool = %{
      "messages" => [%{"role" => "user", "content" => "same text"}],
      "tools" => [
        %{
          "name" => "fixture",
          "input_schema" => %{"type" => "object", "properties" => %{}}
        }
      ]
    }

    assert {:ok, %{"input_tokens" => one_count}} = TokenCount.count(one)
    assert {:ok, %{"input_tokens" => two_count}} = TokenCount.count(two)
    assert {:ok, %{"input_tokens" => tool_count}} = TokenCount.count(with_tool)
    assert two_count > one_count
    assert tool_count > one_count
  end

  test "fails closed when a normalized segment exceeds the bounded local tokenizer" do
    payload = %{
      "messages" => [
        %{"role" => "user", "content" => String.duplicate("x", 8_193)}
      ]
    }

    assert {:error, %{status: 400, code: "invalid_request", param: "messages"}} =
             TokenCount.count(payload)
  end
end
