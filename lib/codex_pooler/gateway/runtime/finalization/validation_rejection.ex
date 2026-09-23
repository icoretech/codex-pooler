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

  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.OpenAICompatibility.Error, as: OpenAICompatibilityError
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
  # The provider's own vocabulary, used only to recognise the rejection. It is
  # deliberately not the type Codex Pooler then writes: the relayed envelope is
  # Codex Pooler-authored, so its type comes from the shared classification
  # (findings#191). The two agree today only because a relayed rejection is
  # always a 400.
  @provider_error_type "invalid_request_error"
  @rejection_status 400
  @relayed_code_by_type %{"invalid_request_error" => "invalid_request"}
  @invalid_request_code "invalid_request"
  @previous_response_not_found_code "previous_response_not_found"
  @previous_response_param "previous_response_id"
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
  def fetch(%Req.Response{} = response, %RequestOptions{} = request_options) do
    cond do
      bridged_public_anchor_miss?(response, request_options) -> previous_response_not_found()
      Metadata.ordinary_responses_route?(request_options) -> fetch_ordinary_route(response)
      true -> nil
    end
  end

  def fetch(_response, _request_options), do: nil

  # A public `/v1` turn bridged onto its session's upstream websocket and
  # anchored on `previous_response_id` whose anchor the connection cannot
  # resolve: the provider's codeless `Invalid previous_response_id` refusal
  # (a reused connection that did not produce the response) or the local
  # `previous_response_not_found` refusal of a fresh connection. Both answer
  # the typed error a public request anchored over HTTP receives before
  # dispatch, so SDK fallbacks resend the complete input (findings#232 row
  # 232-277).
  defp bridged_public_anchor_miss?(%Req.Response{status: @rejection_status} = response, %RequestOptions{
         continuity: %{upstream_previous_response_id?: true},
         transport: %{upstream_websocket_bridge?: true},
         openai_compatibility: %{source_endpoint: source_endpoint}
       })
       when is_binary(source_endpoint),
       do: Metadata.previous_response_miss?(response)

  defp bridged_public_anchor_miss?(_response, _request_options), do: false

  defp previous_response_not_found do
    %{code: @previous_response_not_found_code, param: @previous_response_param, supported_values: nil, supported_values_state: nil}
  end

  @doc """
  `fetch/2` for a response already known to answer an ordinary Responses
  request, such as a provider refusal on the public `/v1/responses` websocket,
  whose socket holds no per-turn request options (findings#254 row 254-15).
  """
  @spec fetch_ordinary_route(Req.Response.t() | term()) :: rejection() | nil
  def fetch_ordinary_route(%Req.Response{status: @rejection_status} = response) do
    case Metadata.rejection_error(response) do
      %{code: code, type: @provider_error_type} = rejection when code in @relayable_codes ->
        outcome = response_supported_values_outcome(code, response)

        %{
          code: code,
          param: Map.get(rejection, :param),
          supported_values: outcome_values(outcome),
          supported_values_state: outcome_state(outcome)
        }

      _other ->
        nil
    end
  end

  def fetch_ordinary_route(_response), do: nil

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

  @doc """
  Renders the rejection's `input[N]` param in the client's input positions for
  the relay (findings#254 row 254-61). The persisted attempt metadata keeps
  the provider's own path; only what the client reads is mapped. An index the
  map places on a Pooler-inserted item, and every index under an unknown map
  (including a surface that holds no per-turn map, such as a websocket event
  built in the socket), is dropped (`input[]...`), never guessed.
  """
  @spec for_client(map() | nil, term()) :: map() | nil
  def for_client(%{param: param} = rejection, index_map) when is_binary(param),
    do: %{rejection | param: client_input_param(param, index_map)}

  def for_client(rejection, _index_map), do: rejection

  @spec client_input_param(String.t() | nil, term()) :: String.t() | nil
  def client_input_param("input[" <> rest = param, index_map) do
    case Integer.parse(rest) do
      {index, "]" <> path} when index >= 0 -> client_input_index(index, index_map, path) || param
      _other -> param
    end
  end

  def client_input_param(param, _index_map), do: param

  defp client_input_index(_index, :identity, _path), do: nil

  defp client_input_index(index, {:shift, leading, inserted}, path)
       when is_integer(leading) and is_integer(inserted) do
    cond do
      index < leading -> nil
      index < leading + inserted -> "input[]" <> path
      true -> "input[#{index - inserted}]" <> path
    end
  end

  defp client_input_index(_index, _index_map, path), do: "input[]" <> path

  @spec error(rejection(), param_mapper()) :: relayed_error()
  def error(%{code: code} = rejection, param_mapper \\ &Function.identity/1)
      when is_function(param_mapper, 1) do
    param = public_param(Map.get(rejection, :param), param_mapper)

    %{
      "type" => ErrorClassification.error_type(code, @rejection_status),
      "code" => code,
      "param" => param,
      "message" => message(code, param, Map.get(rejection, :supported_values))
    }
  end

  @doc """
  The client-visible code of a sanitized provider rejection (`Metadata.rejection_error/1`):
  the provider code when one survived sanitization, otherwise a code derived
  from the type (the observed `tools.defer_loading` rejection carried a type
  and a param but no code). `invalid_request_error` becomes `invalid_request`, the code
  Codex Pooler emits for its own pre-dispatch rejections of that type, and any
  other type is reused verbatim rather than inventing a code the provider
  never used. A rejection without either is the client's `invalid_request`,
  because only a refused 4xx reaches this projection.
  """
  @spec relayed_code(map()) :: String.t()
  def relayed_code(%{code: code}) when is_binary(code), do: code
  def relayed_code(%{type: type}) when is_binary(type), do: Map.get(@relayed_code_by_type, type, type)
  def relayed_code(_rejection_error), do: @invalid_request_code

  @doc """
  The Codex Pooler-authored error for a provider 4xx refusal that is not a
  relayable parameter-validation rejection, built only from its sanitized
  tokens (`Metadata.rejection_error/1`): the relayed code, the bounded param
  and the message this module authors. Provider message text never travels.

  Options:

    * `:index_map` - how an `input[N]` param is rendered (`for_client/2`). The
      default `:unknown` drops the index, for a caller that holds no per-turn
      map (the native websocket socket); `:identity` keeps a param the caller
      already mapped.
    * `:upstream_status` - the provider's status (default 400). Any other
      status is named in the message, because the caller answers the refusal
      as a 400: the native websocket sends a final 4xx as the wrapped 400 the
      released client reads as a final invalid request (row 254-71), and
      native HTTP answers it as an HTTP 400 (row 254-80).

  The native websocket sends it for a refusal the released client would
  otherwise retry (findings#254 row 254-52), and native HTTP for a 400 it used
  to answer with an empty body (row 254-70).
  """
  @spec refusal_error(map(), keyword()) :: relayed_error()
  def refusal_error(rejection_error, opts \\ []) when is_map(rejection_error) and is_list(opts) do
    error =
      %{code: relayed_code(rejection_error), param: Map.get(rejection_error, :param), supported_values: nil, supported_values_state: nil}
      |> for_client(Keyword.get(opts, :index_map, :unknown))
      |> error()

    case Keyword.get(opts, :upstream_status, @rejection_status) do
      @rejection_status -> error
      status -> Map.update!(error, "message", &(&1 <> "; upstream status #{status}"))
    end
  end

  @doc """
  True for a provider 4xx other than 400 that a native client should read as
  final: the released Codex client retries every status but 400 as an
  unexpected status, over HTTP and as a wrapped websocket event, so the native
  surfaces answer these refusals as a 400 naming the provider status
  (`refusal_error/2` `:upstream_status`; findings#254 rows 254-71 and 254-80).
  401 is the upstream credential the Pooler refreshes, 408 a timeout and 429 a
  throttle; each caller also keeps a 403 that demotes the account retryable.
  """
  @spec final_refusal_status?(term()) :: boolean()
  def final_refusal_status?(status) when is_integer(status), do: status in 402..499 and status not in [408, 429]
  def final_refusal_status?(_status), do: false

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

  defp base_message(@previous_response_not_found_code, _param),
    do: OpenAICompatibilityError.previous_response_not_found().message

  defp base_message(code, nil), do: "upstream rejected the request (#{code})"
  defp base_message(code, param), do: "upstream rejected parameter #{param} (#{code})"

  defp supported_values_suffix([_value | _rest] = values),
    do: "; supported values: " <> Enum.join(values, ", ")

  defp supported_values_suffix(_values), do: ""
end
