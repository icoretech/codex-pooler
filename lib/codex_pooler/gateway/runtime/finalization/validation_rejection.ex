defmodule CodexPooler.Gateway.Runtime.Finalization.ValidationRejection do
  @moduledoc """
  Classifies a provider HTTP 400 parameter-validation rejection that may be
  relayed to the requesting client.

  Only a direct string-keyed `"error"` map whose type is exactly
  `invalid_request_error` and whose code is in a fixed allowlist qualifies.
  The relayed error carries the validated code, the bounded param path (or
  `nil`), and a Pooler-authored message built from them. Provider message
  text is never reused because validation messages quote submitted values,
  which can be Pooler-rewritten or Pooler-injected request fields. The only
  message-derived facts are identifier-shaped supported values taken from a
  strictly shaped trailing `Supported values are: ...` list, with every value
  quoted earlier in the message (such as the rejected value) excluded.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata

  @relayable_codes ~w(
    unsupported_value
    invalid_value
    unsupported_parameter
    missing_required_parameter
    invalid_type
    string_above_max_length
  )
  @supported_values_codes ~w(unsupported_value invalid_value)
  @error_type "invalid_request_error"
  @body_max_bytes 65_536
  @message_max_bytes 2_048
  @supported_values_max 12
  @supported_marker "Supported values are:"
  @supported_list ~r/Supported values are: ('[A-Za-z0-9_.-]{1,32}'(?:(?:, and |, | and )'[A-Za-z0-9_.-]{1,32}')*)\.?\z/
  @quoted_token ~r/'([^']*)'/

  @type rejection :: %{
          required(:code) => String.t(),
          required(:param) => String.t() | nil,
          required(:supported_values) => [String.t()] | nil
        }
  @type relayed_error :: %{required(String.t()) => String.t() | nil}
  @type param_mapper :: (String.t() -> String.t())

  @spec relayable_codes() :: [String.t()]
  def relayable_codes, do: @relayable_codes

  @spec fetch(Req.Response.t(), RequestOptions.t() | term()) :: rejection() | nil
  def fetch(%Req.Response{status: 400} = response, %RequestOptions{} = request_options) do
    with true <- Metadata.ordinary_responses_route?(request_options),
         %{code: code, type: @error_type} = rejection when code in @relayable_codes <-
           Metadata.rejection_error(response) do
      %{
        code: code,
        param: Map.get(rejection, :param),
        supported_values: response_supported_values(code, response)
      }
    else
      _other -> nil
    end
  end

  def fetch(_response, _request_options), do: nil

  @spec error(rejection(), param_mapper()) :: relayed_error()
  def error(%{code: code} = rejection, param_mapper \\ &Function.identity/1)
      when is_function(param_mapper, 1) do
    param = public_param(Map.get(rejection, :param), param_mapper)

    %{
      "type" => @error_type,
      "code" => code,
      "param" => param,
      "message" => message(code, param, Map.get(rejection, :supported_values))
    }
  end

  @doc """
  Extracts identifier-shaped supported values from a provider validation
  message, or returns `nil` when the list is absent, repeated, malformed,
  oversized, or empty after excluding every value quoted before it.
  """
  @spec supported_values(term()) :: [String.t()] | nil
  def supported_values(message)
      when is_binary(message) and byte_size(message) <= @message_max_bytes do
    with [prefix, _rest] <- String.split(message, @supported_marker),
         [_match, list] <- Regex.run(@supported_list, message) do
      excluded = quoted_tokens(prefix)

      list
      |> quoted_tokens()
      |> Enum.reject(&(&1 in excluded))
      |> Enum.uniq()
      |> bounded_supported_values()
    else
      _other -> nil
    end
  end

  def supported_values(_message), do: nil

  defp response_supported_values(code, response) when code in @supported_values_codes do
    with body when is_binary(body) and byte_size(body) <= @body_max_bytes <-
           Metadata.rejection_body(response),
         {:ok, %{"error" => %{"message" => message}}} <- CodexPooler.JSON.decode(body) do
      supported_values(message)
    else
      _other -> nil
    end
  end

  defp response_supported_values(_code, _response), do: nil

  defp quoted_tokens(text) do
    @quoted_token
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp bounded_supported_values(values)
       when values != [] and length(values) <= @supported_values_max,
       do: values

  defp bounded_supported_values(_values), do: nil

  defp public_param(nil, _param_mapper), do: nil

  defp public_param(param, param_mapper) do
    case param_mapper.(param) do
      mapped when is_binary(mapped) and mapped != "" -> mapped
      _other -> param
    end
  end

  defp message(code, param, supported_values) do
    base_message(code, param) <> supported_values_suffix(supported_values)
  end

  defp base_message(code, nil), do: "upstream rejected the request (#{code})"
  defp base_message(code, param), do: "upstream rejected parameter #{param} (#{code})"

  defp supported_values_suffix([_value | _rest] = values),
    do: "; supported values: " <> Enum.join(values, ", ")

  defp supported_values_suffix(_values), do: ""
end
