defmodule CodexPoolerWeb.Mcp.Protocol do
  @moduledoc false

  alias CodexPooler.MCP.ProtocolVersions

  @type params :: %{optional(String.t()) => term()}
  @type protocol_header :: nil | String.t()
  @type era :: :legacy | {:modern, String.t()}
  @type detection_error :: :header_mismatch | :unsupported_protocol_version

  @spec legacy_protocol_versions() :: [String.t()]
  def legacy_protocol_versions, do: ProtocolVersions.legacy()

  @spec modern_protocol_versions() :: [String.t()]
  def modern_protocol_versions, do: ProtocolVersions.modern()

  @spec supported_protocol_versions() :: [String.t()]
  def supported_protocol_versions, do: ProtocolVersions.supported()

  @spec detect_era(String.t(), params(), protocol_header()) ::
          {:ok, era()} | {:error, detection_error()}
  def detect_era("initialize", _params, _protocol_header), do: {:ok, :legacy}

  def detect_era(_method, params, protocol_header) do
    protocol_version = protocol_version(params)

    cond do
      unsupported_meta_protocol_version?(protocol_version) ->
        {:error, :unsupported_protocol_version}

      unsupported_protocol_header?(protocol_header) ->
        {:error, :unsupported_protocol_version}

      protocol_version in ProtocolVersions.modern() and protocol_header == protocol_version ->
        {:ok, {:modern, protocol_version}}

      protocol_version in ProtocolVersions.modern() or
          protocol_header in ProtocolVersions.modern() ->
        {:error, :header_mismatch}

      true ->
        {:ok, :legacy}
    end
  end

  @spec validate_modern_meta(params()) :: :ok | {:error, :invalid_params}
  def validate_modern_meta(%{"_meta" => meta}) when is_map(meta) do
    if Map.has_key?(meta, "io.modelcontextprotocol/clientCapabilities") do
      :ok
    else
      {:error, :invalid_params}
    end
  end

  def validate_modern_meta(_params), do: {:error, :invalid_params}

  @spec protocol_version(params()) :: :missing | term()
  defp protocol_version(%{"_meta" => meta}) when is_map(meta) do
    Map.get(meta, "io.modelcontextprotocol/protocolVersion", :missing)
  end

  defp protocol_version(_params), do: :missing

  @spec unsupported_meta_protocol_version?(:missing | term()) :: boolean()
  defp unsupported_meta_protocol_version?(:missing), do: false
  defp unsupported_meta_protocol_version?(version), do: version not in ProtocolVersions.modern()

  @spec unsupported_protocol_header?(protocol_header()) :: boolean()
  defp unsupported_protocol_header?(nil), do: false
  defp unsupported_protocol_header?(version), do: version not in ProtocolVersions.supported()
end
