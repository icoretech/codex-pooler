defmodule CodexPoolerWeb.Anthropic.MessagesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Facade.Anthropic.{Messages, Response, TokenCount}
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  @anthropic_version "2023-06-01"
  @max_beta_header_bytes 4_096
  @max_beta_tokens 64
  @max_beta_token_bytes 128
  @http_token ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  def create(conn, params) do
    payload = request_payload(conn, params)

    PublicGatewayDispatch.coerced(
      conn,
      fn ->
        with :ok <- validate_headers(conn) do
          Messages.coerce(payload, request_opts(conn))
        end
      end,
      fn decoded, %{anthropic_formatting: formatting} ->
        Response.message(decoded, formatting)
      end,
      local_endpoint: "/v1/messages"
    )
  end

  def count_tokens(conn, params) do
    payload = request_payload(conn, params)

    case GatewayHelpers.authenticate_facade(conn) do
      {:ok, _auth} ->
        with :ok <- validate_headers(conn),
             {:ok, result} <- TokenCount.count(payload) do
          json(conn, result)
        else
          {:error, reason} -> GatewayHelpers.send_error(conn, reason)
        end

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp request_opts(conn) do
    conn
    |> GatewayHelpers.request_opts()
    |> Map.put(:upstream_endpoint, Messages.backend_endpoint())
    |> Map.put(:collect_openai_response_stream, true)
  end

  defp request_payload(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}, params), do: params

  defp request_payload(%Plug.Conn{body_params: body_params}, _params) when is_map(body_params),
    do: body_params

  defp validate_headers(conn) do
    with :ok <- validate_version(Plug.Conn.get_req_header(conn, "anthropic-version")) do
      validate_beta(Plug.Conn.get_req_header(conn, "anthropic-beta"))
    end
  end

  defp validate_version([@anthropic_version]), do: :ok

  defp validate_version(_versions) do
    {:error,
     Error.invalid_request(
       "anthropic-version must be #{@anthropic_version}",
       "anthropic-version"
     )}
  end

  defp validate_beta([]), do: :ok

  defp validate_beta([value])
       when is_binary(value) and byte_size(value) <= @max_beta_header_bytes do
    tokens = value |> String.split(",", trim: false) |> Enum.map(&String.trim/1)

    if tokens != [] and length(tokens) <= @max_beta_tokens and
         Enum.all?(tokens, &valid_beta_token?/1) do
      :ok
    else
      invalid_beta()
    end
  end

  defp validate_beta(_values), do: invalid_beta()

  defp valid_beta_token?(token) do
    token != "" and byte_size(token) <= @max_beta_token_bytes and Regex.match?(@http_token, token)
  end

  defp invalid_beta do
    {:error,
     Error.invalid_request(
       "anthropic-beta must be a comma-separated list of valid beta tokens",
       "anthropic-beta"
     )}
  end
end
