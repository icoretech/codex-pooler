defmodule CodexPoolerWeb.Plugs.RuntimeIngress.Path do
  @moduledoc false

  import Plug.Conn, only: [put_private: 3]

  @private_key :codex_pooler_runtime_ingress_path

  @runtime_prefixes [
    ["backend-api", "codex"],
    ["backend-api", "files"],
    ["backend-api", "transcribe"],
    ["api", "codex", "usage"],
    ["wham", "usage"],
    ["backend-api", "wham", "usage"],
    ["v1"],
    ["api"]
  ]

  @pruned_runtime_paths [
    ["backend-api", "codex", "agent-identities", "jwks"],
    ["backend-api", "wham", "agent-identities", "jwks"],
    ["api", "codex", "rate-limit-reset-credits", "consume"],
    ["wham", "rate-limit-reset-credits", "consume"],
    ["backend-api", "wham", "rate-limit-reset-credits", "consume"],
    ["backend-api", "codex", "thread", "goal", "get"],
    ["backend-api", "codex", "thread", "goal", "set"],
    ["backend-api", "codex", "thread", "goal", "clear"],
    ["backend-api", "codex", "analytics-events", "events"],
    ["backend-api", "codex", "memories", "trace_summarize"],
    ["backend-api", "codex", "alpha", "search"],
    ["backend-api", "codex", "realtime", "calls"],
    ["backend-api", "codex", "safety", "arc"]
  ]

  @type scope :: :runtime | :mcp | :passthrough
  @type protocol :: :ollama | :anthropic | :openai | :codex | :runtime_metadata

  @type t :: %__MODULE__{
          decoded_segments: [String.t()],
          candidate_segments: [String.t()],
          scope: scope(),
          unsafe_segment?: boolean()
        }

  @enforce_keys [:decoded_segments, :candidate_segments, :scope, :unsafe_segment?]
  defstruct [:decoded_segments, :candidate_segments, :scope, :unsafe_segment?]

  @spec populate(Plug.Conn.t()) :: Plug.Conn.t()
  def populate(%Plug.Conn{private: %{@private_key => %__MODULE__{}}} = conn), do: conn

  def populate(%Plug.Conn{} = conn) do
    put_private(conn, @private_key, build(conn.path_info))
  end

  @spec fetch(Plug.Conn.t()) :: t()
  def fetch(%Plug.Conn{private: %{@private_key => %__MODULE__{} = path}}), do: path
  def fetch(%Plug.Conn{} = conn), do: build(conn.path_info)

  @spec decoded_segments(Plug.Conn.t() | t()) :: [String.t()]
  def decoded_segments(%__MODULE__{decoded_segments: segments}), do: segments
  def decoded_segments(%Plug.Conn{} = conn), do: conn |> fetch() |> decoded_segments()

  @spec protocol(Plug.Conn.t() | t()) :: protocol()
  def protocol(%Plug.Conn{} = conn), do: conn |> fetch() |> protocol()

  def protocol(%__MODULE__{candidate_segments: segments}) do
    classify_protocol(segments)
  end

  defp build(raw_segments) do
    decoded_segments = Enum.map(raw_segments, &URI.decode/1)
    candidate_segments = Enum.flat_map(decoded_segments, &candidate_segments/1)

    %__MODULE__{
      decoded_segments: decoded_segments,
      candidate_segments: candidate_segments,
      scope: classify(candidate_segments),
      unsafe_segment?: Enum.any?(decoded_segments, &unsafe_segment?/1)
    }
  end

  defp candidate_segments(segment) do
    segment
    |> truncate_at_nul()
    |> String.split(["/", "\\"], trim: false)
  end

  defp truncate_at_nul(segment) do
    case :binary.match(segment, <<0>>) do
      {index, 1} -> binary_part(segment, 0, index)
      :nomatch -> segment
    end
  end

  defp classify(["mcp"]), do: :mcp

  defp classify(candidate_segments) do
    if candidate_segments in @pruned_runtime_paths or
         Enum.any?(@runtime_prefixes, &List.starts_with?(candidate_segments, &1)) do
      :runtime
    else
      :passthrough
    end
  end

  # Runtime metadata helpers must win before the general Ollama `/api/*`
  # classification. Candidate segments are derived from one URI decode, so an
  # unsafe encoded path receives the same protocol-shaped local error as its
  # unencoded route family.
  defp classify_protocol(["api", "codex" | _rest]), do: :runtime_metadata
  defp classify_protocol(["wham", "usage" | _rest]), do: :runtime_metadata
  defp classify_protocol(["backend-api", "wham" | _rest]), do: :runtime_metadata
  defp classify_protocol(["api" | _rest]), do: :ollama
  defp classify_protocol(["v1", "messages" | _rest]), do: :anthropic
  defp classify_protocol(["v1" | _rest]), do: :openai
  defp classify_protocol(["backend-api", "codex" | _rest]), do: :codex
  defp classify_protocol(["backend-api", "files" | _rest]), do: :codex
  defp classify_protocol(["backend-api", "transcribe" | _rest]), do: :codex
  defp classify_protocol(_segments), do: :runtime_metadata

  defp unsafe_segment?(segment) do
    :binary.match(segment, "/") != :nomatch or
      :binary.match(segment, "\\") != :nomatch or
      :binary.match(segment, <<0>>) != :nomatch
  end
end
