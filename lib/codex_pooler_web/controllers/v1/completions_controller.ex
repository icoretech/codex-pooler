defmodule CodexPoolerWeb.V1.CompletionsController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.OpenAICompatibility.Completions
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  @backend_responses_endpoint "/backend-api/codex/responses"

  def create(conn, %{"prompt" => prompts} = params) when is_list(prompts) do
    PublicGatewayDispatch.coerced_batch(
      conn,
      fn -> Completions.coerce_many(params, request_opts(conn, params)) end,
      &combine_batch/2,
      local_endpoint: "/v1/completions"
    )
  end

  def create(conn, params) do
    PublicGatewayDispatch.coerced(
      conn,
      fn -> Completions.coerce(params, request_opts(conn, params)) end,
      fn decoded, %{completion_payload: completion_payload} ->
        Completions.normalize_response(decoded, completion_payload)
      end,
      local_endpoint: "/v1/completions"
    )
  end

  defp request_opts(conn, params) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, @backend_responses_endpoint)
    |> Map.put(:openai_completion_payload, params)
    |> maybe_mark_public_stream(params)
  end

  defp maybe_mark_public_stream(opts, %{"stream" => true}),
    do: Map.put(opts, :public_openai_completions_stream, true)

  defp maybe_mark_public_stream(opts, _params),
    do: Map.put(opts, :collect_openai_response_stream, true)

  defp combine_batch(results, %{completion_payload: completion_payload}) do
    with {:ok, decoded} <- Completions.decode_gateway_results(results) do
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: Completions.normalize_responses(decoded, completion_payload)
       }}
    end
  end
end
