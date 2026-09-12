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

  The parsed list is a fact about the rejection, so it is persisted as bounded
  attempt metadata next to the sanitized code and param rather than being read
  out of a live response body by whichever projection happens to need it
  (codex-pooler-findings#177). Persisting it is what lets both the Full and the
  non-Full projection render one sentence from one constructor.

  Four outcomes stay distinct, because one shared `nil` would erase which one
  happened (codex-pooler-findings#165):

    * not applicable — the code cannot carry a list, so no state is recorded
    * `"present"` — a bounded list was parsed
    * `"none"` — the provider message was read and stated no list
    * `"unparseable"` — a list may exist but this parser would not produce it:
      an unreadable or oversized body or message, a non-binary message, a
      repeated marker, a value the grammar refuses, more than the cap, or
      nothing left once the rejected value is excluded

  `"none"` is the only definitive negative. Everything the bounds refused is
  `"unparseable"`, so an operator reading the metadata can never mistake a
  Pooler-side limit for a provider that offered no alternatives.
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

  @type supported_values_state :: String.t() | nil
  @type rejection :: %{
          required(:code) => String.t(),
          required(:param) => String.t() | nil,
          required(:supported_values) => [String.t()] | nil,
          required(:supported_values_state) => supported_values_state()
        }
  @type relayed_error :: %{required(String.t()) => String.t() | nil}
  @type param_mapper :: (String.t() -> String.t())

  @spec relayable_codes() :: [String.t()]
  def relayable_codes, do: @relayable_codes

  @spec supported_values_codes() :: [String.t()]
  def supported_values_codes, do: @supported_values_codes

  @spec fetch(Req.Response.t(), RequestOptions.t() | term()) :: rejection() | nil
  def fetch(%Req.Response{status: 400} = response, %RequestOptions{} = request_options) do
    with true <- Metadata.ordinary_responses_route?(request_options),
         %{code: code, type: @error_type} = rejection when code in @relayable_codes <-
           Metadata.rejection_error(response) do
      outcome = response_supported_values_outcome(code, response)

      %{
        code: code,
        param: Map.get(rejection, :param),
        supported_values: outcome_values(outcome),
        supported_values_state: outcome_state(outcome)
      }
    else
      _other -> nil
    end
  end

  def fetch(_response, _request_options), do: nil

  @doc """
  Projects the bounded supported-values fact of a fetched rejection as attempt
  metadata.

  The state key is written exactly when `fetch/2` admitted the rejection and
  its code can carry a list, so a code outside that pair, a non-400, a
  non-ordinary route, and an unrecognized rejection all leave the field out
  entirely. The list key is written only for `"present"`, which keeps an
  absent list readable as its own recorded reason rather than as a missing row.
  """
  @spec attempt_metadata(rejection() | term()) :: %{optional(String.t()) => term()}
  def attempt_metadata(%{supported_values_state: state} = rejection) when is_binary(state) do
    %{"rejection_supported_values_state" => state}
    |> put_supported_values(Map.get(rejection, :supported_values))
  end

  def attempt_metadata(_rejection), do: %{}

  defp put_supported_values(metadata, [_value | _rest] = values),
    do: Map.put(metadata, "rejection_supported_values", values)

  defp put_supported_values(metadata, _values), do: metadata

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
  def supported_values(message), do: outcome_values(supported_values_outcome(message))

  @doc """
  Classifies the trailing supported-values list of a provider validation
  message without ever returning its surrounding text.

  `:none` means the message was read and carried no list marker, which is a
  fact about the provider. Every other negative is `:unparseable`: the bounds
  refused what was there, so the list may exist and this parser simply will not
  produce it. Collapsing the two would report a Pooler-side limit as a provider
  that offered no alternatives.
  """
  @spec supported_values_outcome(term()) :: {:present, [String.t()]} | :none | :unparseable
  def supported_values_outcome(message) when is_binary(message) do
    cond do
      not String.contains?(message, @supported_marker) -> :none
      byte_size(message) > @message_max_bytes -> :unparseable
      true -> parse_supported_values(message)
    end
  end

  def supported_values_outcome(_message), do: :unparseable

  defp parse_supported_values(message) do
    with [prefix, _rest] <- String.split(message, @supported_marker),
         [_match, list] <- Regex.run(@supported_list, message),
         [_value | _rest] = values <- excluded_supported_values(list, prefix),
         true <- length(values) <= @supported_values_max do
      {:present, values}
    else
      _other -> :unparseable
    end
  end

  defp excluded_supported_values(list, prefix) do
    excluded = quoted_tokens(prefix)

    list
    |> quoted_tokens()
    |> Enum.reject(&(&1 in excluded))
    |> Enum.uniq()
  end

  defp response_supported_values_outcome(code, response) when code in @supported_values_codes do
    case rejection_message(response) do
      {:ok, message} -> supported_values_outcome(message)
      :no_message -> :none
      :unreadable -> :unparseable
    end
  end

  defp response_supported_values_outcome(_code, _response), do: :not_applicable

  # An `"error"` object with no `"message"` key stated no list, which is the
  # same definitive negative as a message without the marker. A body or message
  # the bounds refuse is not: it is read as unparseable above.
  defp rejection_message(response) do
    with body when is_binary(body) and byte_size(body) <= @body_max_bytes <-
           Metadata.rejection_body(response),
         {:ok, %{"error" => error}} when is_map(error) <- CodexPooler.JSON.decode(body) do
      case Map.fetch(error, "message") do
        {:ok, message} when is_binary(message) -> {:ok, message}
        :error -> :no_message
        _non_binary -> :unreadable
      end
    else
      _other -> :unreadable
    end
  end

  defp outcome_values({:present, values}), do: values
  defp outcome_values(_outcome), do: nil

  defp outcome_state({:present, _values}), do: "present"
  defp outcome_state(:none), do: "none"
  defp outcome_state(:unparseable), do: "unparseable"
  defp outcome_state(:not_applicable), do: nil

  defp quoted_tokens(text) do
    @quoted_token
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

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
