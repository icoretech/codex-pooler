defmodule CodexPooler.Gateway.Transports.Streaming.RetainedBodyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  @property_seed {20_260_730, 91, 37}

  test "matches the bounded suffix reference across seeded binary and iodata appends" do
    rng = :rand.seed_s(:exsss, @property_seed)

    Enum.reduce(1..120, {rng, RetainedBody.empty(), ""}, fn _iteration,
                                                            {rng, retained, reference} ->
      {data, rng} = random_iodata(rng)
      retained = RetainedBody.append(retained, data)
      reference = reference_append(reference, data)

      assert RetainedBody.read(retained) == reference
      {rng, retained, reference}
    end)
  end

  test "owns the bounded suffix instead of retaining an oversized parent" do
    parent = :binary.copy(<<7>>, RetainedBody.max_bytes() * 128)
    retained = RetainedBody.append(RetainedBody.empty(), parent)

    retained = RetainedBody.read(retained)
    assert byte_size(retained) == RetainedBody.max_bytes()
    assert :binary.referenced_byte_size(retained) == byte_size(retained)
  end

  test "emits telemetry when a retained body first crosses the truncation limit" do
    attach_stream_buffer_telemetry()

    body =
      RetainedBody.append(
        RetainedBody.empty(),
        String.duplicate("x", RetainedBody.max_bytes() - 8)
      )

    data = String.duplicate("y", 16)

    retained = RetainedBody.append(body, data)

    assert byte_size(RetainedBody.read(retained)) == RetainedBody.max_bytes()

    assert_receive {[:codex_pooler, :gateway, :stream_buffer, :truncated],
                    %{bytes: bytes, count: 1, max_bytes: 65_536},
                    %{buffer: "retained_body", endpoint: "unknown", route_class: "unknown"}}

    assert bytes > 65_536
  end

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :truncated],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp random_iodata(rng) do
    {size, rng} = uniform(rng, RetainedBody.max_bytes() * 3)
    {byte, rng} = uniform(rng, 256)
    binary = :binary.copy(<<byte - 1>>, size - 1)

    case rem(size, 3) do
      0 ->
        {binary, rng}

      1 ->
        {[
           binary_part(binary, 0, div(byte_size(binary), 2)),
           binary_part(
             binary,
             div(byte_size(binary), 2),
             byte_size(binary) - div(byte_size(binary), 2)
           )
         ], rng}

      2 ->
        {[[], [binary]], rng}
    end
  end

  defp reference_append(body, data) do
    appended = IO.iodata_to_binary([body, data])
    max_bytes = RetainedBody.max_bytes()

    if byte_size(appended) <= max_bytes do
      appended
    else
      binary_part(appended, byte_size(appended) - max_bytes, max_bytes)
    end
  end

  defp uniform(rng, max) do
    {value, rng} = :rand.uniform_s(max, rng)
    {value, rng}
  end
end
