defmodule CodexPooler.Upstreams.ResponsesAPIHistory do
  @moduledoc """
  Bounded, volatile continuation history for stateless API upstreams.
  Entries are isolated by Pool and downstream key and expire after 30 minutes.
  Nothing is persisted. Missing history requires a full-history client retry.
  """
  use GenServer

  @max_entry_bytes 32 * 1024 * 1024

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :sweep, 60_000)

    {:ok,
     %{
       entries: %{},
       clock: 0,
       max_bytes: Keyword.get(opts, :max_bytes, 256 * 1024 * 1024),
       max_entries: Keyword.get(opts, :max_entries, 128),
       ttl: Keyword.get(opts, :ttl_ms, 30 * 60_000)
     }}
  end

  def context(auth, payload), do: %{scope: {auth.pool.id, auth.api_key.id}, payload: payload}

  def expand(payload, _auth, false), do: {:ok, payload}

  def expand(payload, auth, true) do
    case payload["previous_response_id"] do
      id when is_binary(id) and id != "" ->
        case get({auth.pool.id, auth.api_key.id}, id) do
          {:ok, previous} ->
            input = input_items(previous["input"]) ++ input_items(payload["input"])

            {:ok,
             previous
             |> Map.merge(payload)
             |> Map.put("input", input)
             |> Map.delete("previous_response_id")}

          :missing ->
            {:error,
             %{
               status: 400,
               code: "previous_response_not_found",
               message:
                 "API continuation history expired or is unavailable; resend the full conversation."
             }}
        end

      _none ->
        {:ok, payload}
    end
  end

  def remember(nil, _response), do: :ok

  def remember(
        %{scope: scope, payload: payload},
        %{"id" => id, "status" => "completed", "output" => output} = response
      )
      when is_binary(id) and is_list(output) do
    input = input_items(payload["input"])

    input =
      if response["object"] == "response.compaction",
        do: Enum.filter(input, &match?(%{"type" => "additional_tools"}, &1)) ++ output,
        else: input ++ output

    put(scope, id, Map.put(payload, "input", input))
  end

  def remember(_context, _response), do: :ok

  def remember_json(response, nil), do: response

  def remember_json(%Req.Response{body: body} = response, context) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = result} -> remember(context, result)
      _other -> :ok
    end

    response
  end

  def remember_json(response, _context), do: response

  def put(scope, id, payload, server \\ __MODULE__) do
    bytes = :erlang.external_size(payload)

    if bytes <= @max_entry_bytes,
      do: GenServer.call(server, {:put, {scope, id}, payload, bytes}),
      else: :not_cached
  end

  def get(scope, id, server \\ __MODULE__), do: GenServer.call(server, {:get, {scope, id}})

  @impl true
  def handle_call({:put, key, payload, bytes}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = prune(state, now)
    entry = %{payload: payload, bytes: bytes, touched: now, order: state.clock + 1}

    state =
      %{state | entries: Map.put(state.entries, key, entry), clock: state.clock + 1} |> trim()

    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    state = prune(state, now)

    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        entry = %{entry | touched: now, order: state.clock + 1}

        {:reply, {:ok, entry.payload},
         %{state | entries: Map.put(state.entries, key, entry), clock: state.clock + 1}}

      :error ->
        {:reply, :missing, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, prune(state, System.monotonic_time(:millisecond))}
  end

  defp prune(state, now),
    do: %{
      state
      | entries: Map.reject(state.entries, fn {_key, e} -> now - e.touched >= state.ttl end)
    }

  defp trim(state) do
    bytes = Enum.sum(Enum.map(state.entries, fn {_key, e} -> e.bytes end))

    if map_size(state.entries) > state.max_entries or bytes > state.max_bytes do
      {oldest, _entry} = Enum.min_by(state.entries, fn {_key, e} -> e.order end)
      trim(%{state | entries: Map.delete(state.entries, oldest)})
    else
      state
    end
  end

  defp input_items(items) when is_list(items), do: items

  defp input_items(text) when is_binary(text),
    do: [%{"type" => "message", "role" => "user", "content" => text}]

  defp input_items(_input), do: []
end
