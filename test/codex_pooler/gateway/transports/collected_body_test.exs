defmodule CodexPooler.Gateway.Transports.Streaming.CollectedBodyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.CollectedBody

  test "keeps a collected turn whole up to its bound" do
    body =
      CollectedBody.empty()
      |> CollectedBody.append("data: first\n\n")
      |> CollectedBody.append(["data: ", "second", "\n\n"])

    refute CollectedBody.overflow?(body)
    assert CollectedBody.read(body) == "data: first\n\ndata: second\n\n"
  end

  test "latches an explicit overflow instead of returning a truncated suffix" do
    body =
      CollectedBody.empty()
      |> CollectedBody.append("data: head\n\n")
      |> CollectedBody.append(:binary.copy("x", CollectedBody.max_bytes()))
      |> CollectedBody.append("data: tail\n\n")

    assert CollectedBody.overflow?(body)

    read = CollectedBody.read(body)

    refute read =~ "head"
    refute read =~ "tail"
    assert byte_size(read) < 256

    assert %{"type" => type, "max_bytes" => max_bytes} =
             read
             |> String.replace_prefix("data: ", "")
             |> String.trim()
             |> CodexPooler.JSON.decode!()

    assert type == CollectedBody.overflow_event_type()
    assert max_bytes == CollectedBody.max_bytes()
  end

  test "a disabled accumulator retains nothing" do
    body = CollectedBody.append(CollectedBody.disabled(), "data: ignored\n\n")

    assert body == :disabled
    assert CollectedBody.read(body) == ""
    refute CollectedBody.overflow?(body)
    assert CollectedBody.bytes(body) == 0
  end
end
