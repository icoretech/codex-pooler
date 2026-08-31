defmodule CodexPooler.Gateway.Transports.MisalignmentPolicyViolation do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @code "misalignment_policy_violation"
  @fallback_message "This request was blocked due to a misalignment policy violation."
  @private_key :codex_pooler_misalignment_policy_violation
  @detail_max_bytes 65_536
  @detail_routes [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses"
  ]
  @eligible_routes [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses",
    "/backend-api/codex/responses/compact",
    "/backend-api/codex/v1/responses/compact",
    "/v1/responses",
    "/v1/chat/completions",
    "/backend-api/codex/v1/chat/completions"
  ]

  @type misalignment :: %{
          required(String.t()) => String.t() | %{required(String.t()) => String.t()}
        }
  @type summary :: %{
          required(:code) => String.t(),
          required(:message) => String.t(),
          optional(:misalignment) => misalignment()
        }

  @spec code() :: String.t()
  def code, do: @code

  @spec fallback_message() :: String.t()
  def fallback_message, do: @fallback_message

  @spec normalize_message(term()) :: String.t()
  def normalize_message(message) when is_binary(message) do
    if String.trim(message) == "", do: @fallback_message, else: message
  end

  def normalize_message(_message), do: @fallback_message

  @spec eligible_route?(RequestOptions.t()) :: boolean()
  def eligible_route?(%RequestOptions{} = request_options) do
    effective_route(request_options) in @eligible_routes
  end

  @spec classify_http(integer(), binary(), RequestOptions.t()) :: {:ok, summary()} | :no_match
  def classify_http(status, body, %RequestOptions{} = request_options)
      when status in [400, 403] and is_binary(body) do
    with true <- eligible_route?(request_options),
         {:ok, %{"error" => error}} when is_map(error) <- Jason.decode(body),
         @code <- Map.get(error, "code") do
      summary = %{code: @code, message: normalize_message(Map.get(error, "message"))}

      {:ok, maybe_put_misalignment(summary, error, request_options)}
    else
      _no_match -> :no_match
    end
  end

  def classify_http(_status, _body, %RequestOptions{}), do: :no_match

  @spec put_summary(Req.Response.t(), summary()) :: Req.Response.t()
  def put_summary(%Req.Response{} = response, %{code: @code, message: message} = summary)
      when is_binary(message) do
    private_summary =
      %{code: @code, message: message}
      |> maybe_put_private_misalignment(summary)

    Req.Response.put_private(response, @private_key, private_summary)
  end

  @spec fetch_summary(Req.Response.t()) :: summary() | nil
  def fetch_summary(%Req.Response{} = response) do
    Req.Response.get_private(response, @private_key)
  end

  @spec details_allowed?(RequestOptions.t()) :: boolean()
  def details_allowed?(%RequestOptions{} = request_options), do: detail_route?(request_options)

  @spec normalize_details(term()) :: misalignment() | nil
  def normalize_details(misalignment) do
    case normalize_misalignment(misalignment) do
      {:ok, normalized} -> normalized
      :omit -> nil
    end
  end

  defp effective_route(%RequestOptions{
         openai_compatibility: %{source_endpoint: source_endpoint},
         transport: %{upstream_endpoint: upstream_endpoint}
       }) do
    source_endpoint || upstream_endpoint
  end

  defp maybe_put_misalignment(summary, error, request_options) do
    if detail_route?(request_options) do
      case normalize_misalignment(Map.get(error, "misalignment")) do
        {:ok, misalignment} -> Map.put(summary, :misalignment, misalignment)
        :omit -> summary
      end
    else
      summary
    end
  end

  defp detail_route?(%RequestOptions{transport: %{transport: transport}} = request_options)
       when transport in ["http_json", "http_sse"],
       do: effective_route(request_options) in @detail_routes

  defp detail_route?(%RequestOptions{}), do: false

  defp maybe_put_private_misalignment(private_summary, %{misalignment: misalignment}) do
    case normalize_misalignment(misalignment) do
      {:ok, normalized} -> Map.put(private_summary, :misalignment, normalized)
      :omit -> private_summary
    end
  end

  defp maybe_put_private_misalignment(private_summary, _summary), do: private_summary

  defp normalize_misalignment(%{} = misalignment) when map_size(misalignment) > 0 do
    with {:ok, error_type} <- optional_detail(misalignment, "error_type"),
         {:ok, detailed_explanation} <- optional_detail(misalignment, "detailed_explanation"),
         {:ok, steer} <- optional_steer(misalignment),
         normalized when map_size(normalized) > 0 <-
           %{}
           |> maybe_put_detail("error_type", error_type)
           |> maybe_put_detail("detailed_explanation", detailed_explanation)
           |> maybe_put_detail("steer", steer) do
      {:ok, normalized}
    else
      _invalid_or_empty -> :omit
    end
  end

  defp normalize_misalignment(_misalignment), do: :omit

  defp optional_detail(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and byte_size(value) <= @detail_max_bytes -> {:ok, value}
      {:ok, _invalid} -> :error
    end
  end

  defp optional_steer(misalignment) do
    case Map.fetch(misalignment, "steer") do
      :error ->
        {:ok, nil}

      {:ok, %{} = steer} ->
        case Map.fetch(steer, "message") do
          {:ok, message} when is_binary(message) and byte_size(message) <= @detail_max_bytes ->
            {:ok, %{"message" => message}}

          _missing_or_invalid ->
            :error
        end

      {:ok, _invalid} ->
        :error
    end
  end

  defp maybe_put_detail(details, _key, nil), do: details
  defp maybe_put_detail(details, key, value), do: Map.put(details, key, value)
end
