defmodule CodexPooler.Gateway.Transports.MisalignmentPolicyViolation do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @code "misalignment_policy_violation"
  @fallback_message "This request was blocked due to a misalignment policy violation."
  @private_key :codex_pooler_misalignment_policy_violation
  @eligible_routes [
    "/backend-api/codex/responses",
    "/backend-api/codex/v1/responses",
    "/backend-api/codex/responses/compact",
    "/backend-api/codex/v1/responses/compact",
    "/v1/responses",
    "/v1/chat/completions",
    "/backend-api/codex/v1/chat/completions"
  ]

  @type summary :: %{required(:code) => String.t(), required(:message) => String.t()}

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
      {:ok, %{code: @code, message: normalize_message(Map.get(error, "message"))}}
    else
      _no_match -> :no_match
    end
  end

  def classify_http(_status, _body, %RequestOptions{}), do: :no_match

  @spec put_summary(Req.Response.t(), summary()) :: Req.Response.t()
  def put_summary(%Req.Response{} = response, %{code: @code, message: message})
      when is_binary(message) do
    Req.Response.put_private(response, @private_key, %{code: @code, message: message})
  end

  @spec fetch_summary(Req.Response.t()) :: summary() | nil
  def fetch_summary(%Req.Response{} = response) do
    Req.Response.get_private(response, @private_key)
  end

  defp effective_route(%RequestOptions{
         openai_compatibility: %{source_endpoint: source_endpoint},
         transport: %{upstream_endpoint: upstream_endpoint}
       }) do
    source_endpoint || upstream_endpoint
  end
end
