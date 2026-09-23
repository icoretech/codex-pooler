defmodule CodexPoolerWeb.Runtime.BackendCodexTestSupportDecodeTest do
  @moduledoc """
  A TCP read can end inside a websocket frame. The public receive helpers must
  hand the decoder state back unchanged for such a read, so the next read
  completes the frame (findings#232 row 232-262: the state came back wrapped
  twice and the next decode crashed with a large frame split across reads).
  """
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport

  @text ~s({"type":"response.output_text.delta","delta":"split across two reads"})

  test "a read that holds no complete text frame returns the decoder state for the next read" do
    {head, tail} = split_server_text_frame(@text)

    assert {:cont, %Mint.WebSocket{} = websocket} = BackendCodexTestSupport.decode_public_websocket_data!(%Mint.WebSocket{}, head)
    assert {:ok, %Mint.WebSocket{}, [@text]} = BackendCodexTestSupport.decode_public_websocket_data!(websocket, tail)
  end

  test "a frame split across two data parts of one stream decodes to its text" do
    ref = make_ref()
    {head, tail} = split_server_text_frame(@text)

    assert {:ok, %Mint.WebSocket{}, @text} =
             BackendCodexTestSupport.decode_public_websocket_text(%Mint.WebSocket{}, ref, [{:data, ref, head}, {:data, ref, tail}])
  end

  test "a frame split across two streams decodes to its text on the second" do
    ref = make_ref()
    {head, tail} = split_server_text_frame(@text)

    assert {:cont, %Mint.WebSocket{} = websocket} =
             BackendCodexTestSupport.decode_public_websocket_text(%Mint.WebSocket{}, ref, [{:data, ref, head}])

    assert {:ok, %Mint.WebSocket{}, @text} = BackendCodexTestSupport.decode_public_websocket_text(websocket, ref, [{:data, ref, tail}])
  end

  # An unmasked server text frame (FIN, opcode 1, 7-bit length), cut in the
  # middle of its payload.
  defp split_server_text_frame(text) when byte_size(text) < 126 do
    frame = <<1::1, 0::3, 1::4, 0::1, byte_size(text)::7, text::binary>>
    cut = div(byte_size(frame), 2)
    {binary_part(frame, 0, cut), binary_part(frame, cut, byte_size(frame) - cut)}
  end
end
