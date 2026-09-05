defmodule CodexPooler.FakeOpenAIAuthProvider do
  @moduledoc """
  Local fake for OpenAI auth-provider protocol tests.

  It wraps the shared FakeUpstream Plug/Bandit server so tests exercise real
  HTTP requests and captured form/json payloads instead of stubbing Req.
  """

  alias CodexPooler.FakeUpstream

  @type route_payload :: {non_neg_integer(), term()}
  @type routes :: %{String.t() => route_payload()}

  @spec start_link(routes()) :: {:ok, FakeUpstream.t()}
  def start_link(routes) when is_map(routes) do
    FakeUpstream.start_link({:path_json, routes})
  end

  @spec stop(FakeUpstream.t()) :: :ok
  def stop(provider), do: FakeUpstream.stop(provider)

  @spec url(FakeUpstream.t()) :: String.t()
  def url(provider), do: FakeUpstream.url(provider)

  @spec requests(FakeUpstream.t()) :: [map()]
  def requests(provider), do: FakeUpstream.requests(provider)

  @spec decode_form_request(map()) :: %{String.t() => String.t()}
  def decode_form_request(%{body: body}) when is_binary(body), do: URI.decode_query(body)

  @spec token_response(keyword()) :: map()
  def token_response(opts \\ []) do
    %{
      "access_token" => Keyword.get(opts, :access_token, "access-token-example"),
      "refresh_token" => Keyword.get(opts, :refresh_token, "refresh-token-example"),
      "id_token" => Keyword.get(opts, :id_token, id_token())
    }
    |> maybe_put("expires_in", Keyword.get(opts, :expires_in))
  end

  @spec device_code_response(keyword()) :: map()
  def device_code_response(opts \\ []) do
    %{
      "device_auth_id" => Keyword.get(opts, :device_auth_id, "device-auth-example"),
      "user_code" => Keyword.get(opts, :user_code, "ABCD-EFGH"),
      "expires_at" => Keyword.get(opts, :expires_at, "2026-06-10T21:00:00Z"),
      "interval" => Keyword.get(opts, :interval, 5)
    }
  end

  @spec authorization_code_response(keyword()) :: map()
  def authorization_code_response(opts \\ []) do
    %{
      "authorization_code" =>
        Keyword.get(opts, :authorization_code, "authorization-code-example"),
      "code_verifier" => Keyword.get(opts, :code_verifier, "code-verifier-example")
    }
  end

  @spec id_token(map()) :: String.t()
  def id_token(claim_overrides \\ %{}) when is_map(claim_overrides) do
    claims =
      Map.merge(
        %{
          "email" => "example-user@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_example",
            "chatgpt_user_id" => "user_example",
            "chatgpt_plan_type" => "team",
            "workspace_id" => "workspace-example",
            "workspace_label" => "Example Workspace"
          }
        },
        claim_overrides
      )

    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".signature"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
