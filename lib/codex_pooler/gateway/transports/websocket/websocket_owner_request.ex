defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.{ResetProbe, TimeoutConfig}
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot

  @version 1
  @mappers [:public_openai_responses, :native_codex_responses, :codex_responses]
  @fields [
    :version,
    :url,
    :headers,
    :payload,
    :timeouts,
    :mapper,
    :upstream_identity_id,
    :observation,
    :reset_probe,
    :native_codex_response_control,
    :assignment_advertised?,
    :connection_bound_continuation?,
    :forward_error_body?,
    :submission_notification?
  ]
  @observation_fields [:request_id, :client_request_id, :attempt_id, :mode]
  @max_headers 128
  @max_header_name_bytes 256
  @max_header_value_bytes 16_384
  @max_observation_id_bytes 256
  @max_models_etag_bytes 1_024

  @enforce_keys @fields
  defstruct @fields

  @type mapper ::
          :public_openai_responses | :native_codex_responses | :codex_responses
  @type observation :: %{
          required(:request_id) => Ecto.UUID.t() | nil,
          required(:client_request_id) => String.t() | nil,
          required(:attempt_id) => Ecto.UUID.t() | nil,
          required(:mode) => String.t()
        }
  @type t :: %__MODULE__{
          version: 1,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          payload: binary(),
          timeouts: TimeoutConfig.t(),
          mapper: mapper(),
          upstream_identity_id: Ecto.UUID.t(),
          observation: observation(),
          reset_probe: ResetProbe.t() | nil,
          native_codex_response_control: TurnSnapshot.t() | nil,
          assignment_advertised?: boolean(),
          connection_bound_continuation?: boolean(),
          forward_error_body?: boolean(),
          submission_notification?: boolean()
        }
  @type validation_error ::
          {:unknown_fields, [atom() | String.t()]} | {:invalid_field, atom()}

  @spec new(map()) :: {:ok, t()} | {:error, validation_error()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- reject_unknown_fields(attrs),
         :ok <- require_fields(attrs) do
      request = struct!(__MODULE__, attrs)

      case validate(request) do
        :ok -> {:ok, request}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :envelope}}

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = request) do
    with :ok <- reject_unknown_fields(Map.delete(request, :__struct__)) do
      validators = [
        version: &(&1 == @version),
        url: &valid_url?/1,
        headers: &valid_headers?/1,
        payload: &is_binary/1,
        timeouts: &valid_timeouts?/1,
        mapper: &(&1 in @mappers),
        upstream_identity_id: &valid_uuid?/1,
        observation: &valid_observation?/1,
        reset_probe: &valid_reset_probe?/1,
        native_codex_response_control: &valid_native_control?/1,
        assignment_advertised?: &is_boolean/1,
        connection_bound_continuation?: &is_boolean/1,
        forward_error_body?: &is_boolean/1,
        submission_notification?: &is_boolean/1
      ]

      Enum.reduce_while(validators, :ok, fn {field, validator}, :ok ->
        if validator.(Map.fetch!(request, field)) do
          {:cont, :ok}
        else
          {:halt, {:error, {:invalid_field, field}}}
        end
      end)
    end
  end

  def validate(_request), do: {:error, {:invalid_field, :envelope}}

  defp reject_unknown_fields(attrs) do
    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @fields))
      |> Enum.map(&safe_unknown_field/1)
      |> Enum.uniq()
      |> Enum.sort_by(&to_string/1)

    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp safe_unknown_field(field) when is_atom(field) or is_binary(field), do: field
  defp safe_unknown_field(_field), do: :unsupported

  defp require_fields(attrs) do
    case Enum.find(@fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:invalid_field, field}}
    end
  end

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_url?(_url), do: false

  defp valid_headers?(headers) when is_list(headers) and length(headers) <= @max_headers do
    proper_list?(headers) and Enum.all?(headers, &valid_header?/1)
  end

  defp valid_headers?(_headers), do: false

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    byte_size(name) in 1..@max_header_name_bytes and
      byte_size(value) <= @max_header_value_bytes and
      String.valid?(name) and String.valid?(value) and
      Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, name) and
      not contains_forbidden_header_value_byte?(value)
  end

  defp valid_header?(_header), do: false

  defp contains_forbidden_header_value_byte?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&((&1 < 32 and &1 != 9) or &1 == 127))
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp valid_timeouts?(%TimeoutConfig{} = timeouts) do
    Enum.all?(
      [timeouts.connect_timeout_ms, timeouts.pool_timeout_ms, timeouts.receive_timeout_ms],
      &(is_integer(&1) and &1 >= 0)
    )
  end

  defp valid_timeouts?(_timeouts), do: false

  defp valid_observation?(observation)
       when is_map(observation) and not is_struct(observation) do
    MapSet.new(Map.keys(observation)) == MapSet.new(@observation_fields) and
      valid_optional_uuid?(observation.request_id) and
      valid_observation_id?(observation.client_request_id) and
      valid_optional_uuid?(observation.attempt_id) and
      observation.mode in ["full", "lite"]
  end

  defp valid_observation?(_observation), do: false

  defp valid_observation_id?(nil), do: true

  defp valid_observation_id?(value) when is_binary(value) do
    byte_size(value) in 1..@max_observation_id_bytes and String.valid?(value) and
      String.trim(value) == value
  end

  defp valid_observation_id?(_value), do: false

  defp valid_reset_probe?(nil), do: true

  defp valid_reset_probe?(%ResetProbe{} = probe),
    do: ResetProbe.unbound?(probe) or ResetProbe.bound?(probe)

  defp valid_reset_probe?(_probe), do: false

  defp valid_native_control?(nil), do: true

  defp valid_native_control?(%TurnSnapshot{models_etag: models_etag})
       when is_binary(models_etag) do
    byte_size(models_etag) in 1..@max_models_etag_bytes and String.valid?(models_etag) and
      not contains_ascii_control?(models_etag)
  end

  defp valid_native_control?(_control), do: false

  defp contains_ascii_control?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 <= 31 or &1 == 127))
  end

  defp valid_optional_uuid?(nil), do: true
  defp valid_optional_uuid?(value), do: valid_uuid?(value)

  defp valid_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp valid_uuid?(_value), do: false
end

defimpl Inspect,
  for: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest do
  import Inspect.Algebra

  def inspect(_request, _opts), do: concat(["#WebsocketOwnerRequest<version: 1>"])
end
