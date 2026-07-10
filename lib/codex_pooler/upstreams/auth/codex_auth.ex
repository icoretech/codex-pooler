defmodule CodexPooler.Upstreams.Auth.CodexAuth do
  @moduledoc """
  Codex OAuth/device authorization client used by invite onboarding.
  """

  alias CodexPooler.Upstreams.CodexClientIdentity

  @issuer "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @browser_redirect_uri "http://localhost:1455/auth/callback"
  @authorization_scope "openid profile email offline_access api.connectors.read api.connectors.invoke"

  @type auth_error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:retry_after_seconds) => pos_integer(),
          optional(:status) => pos_integer()
        }

  @type device_code_result :: %{
          required(String.t()) => String.t() | pos_integer() | nil
        }

  @type token_info :: %{
          email: String.t() | nil,
          chatgpt_account_id: String.t() | nil,
          chatgpt_user_id: String.t() | nil,
          workspace_id: String.t() | nil,
          workspace_label: String.t() | nil,
          seat_type: String.t() | nil,
          plan_family: String.t() | nil,
          plan_label: String.t() | nil
        }

  @type token_result :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          id_token: String.t()
        }

  @type refresh_result :: %{
          required(:access_token) => String.t(),
          optional(:refresh_token) => String.t() | nil,
          optional(:expires_in) => pos_integer() | String.t() | nil
        }

  @type client_error :: auth_error() | term()
  @type device_code_response :: {:ok, device_code_result()} | {:error, client_error()}
  @type token_response :: {:ok, token_result()} | {:error, client_error()}
  @type refresh_response :: {:ok, refresh_result()} | {:error, client_error()}
  @type token_info_response :: {:ok, token_info()} | {:error, auth_error()}
  @type refresh_opts :: keyword()
  @type auth_client :: module()
  @type pkce_pair :: %{
          required(:code_verifier) => String.t(),
          required(:code_challenge) => String.t()
        }

  @spec generate_pkce_pair() :: pkce_pair()
  def generate_pkce_pair do
    verifier = 64 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    %{code_verifier: verifier, code_challenge: pkce_challenge(verifier)}
  end

  @spec pkce_challenge(String.t()) :: String.t()
  def pkce_challenge(verifier) when is_binary(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @spec build_browser_authorization_url(String.t(), String.t()) :: String.t()
  def build_browser_authorization_url(state, code_challenge)
      when is_binary(state) and is_binary(code_challenge) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id(),
        "redirect_uri" => browser_redirect_uri(),
        "scope" => authorization_scope(),
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => oauth_originator()
      })

    issuer() <> "/oauth/authorize?#{query}"
  end

  @spec exchange_authorization_code(String.t(), String.t(), String.t()) :: token_response()
  def exchange_authorization_code(code, code_verifier, redirect_uri \\ browser_redirect_uri()) do
    cond do
      blank_string?(code) ->
        auth_error(
          :codex_oauth_invalid_authorization_code,
          "Codex OAuth authorization code is invalid",
          400
        )

      blank_string?(code_verifier) ->
        auth_error(
          :codex_oauth_invalid_code_verifier,
          "Codex OAuth code verifier is invalid",
          400
        )

      blank_string?(redirect_uri) ->
        auth_error(:codex_oauth_invalid_redirect_uri, "Codex OAuth redirect URI is invalid", 400)

      true ->
        client().exchange_authorization_code(code, code_verifier, redirect_uri)
    end
  end

  @spec request_device_code() :: device_code_response()
  def request_device_code do
    client().request_device_code()
  end

  @spec poll_device_authorization(map()) :: token_response()
  def poll_device_authorization(state) when is_map(state) do
    client().poll_device_authorization(state)
  end

  @spec refresh_token(String.t(), refresh_opts()) :: refresh_response()
  def refresh_token(refresh_token, opts \\ []) when is_binary(refresh_token) do
    client().refresh_token(refresh_token, opts)
  end

  @spec token_info(term()) :: token_info_response()
  def token_info(id_token) when is_binary(id_token) do
    with [_header, payload, _signature] <- String.split(id_token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(json) do
      auth_claims = claims["https://api.openai.com/auth"] || %{}

      {:ok,
       %{
         email: claims["email"],
         chatgpt_account_id: auth_claims["chatgpt_account_id"],
         chatgpt_user_id: auth_claims["chatgpt_user_id"],
         workspace_id: claim_from_auth_or_top_level(claims, workspace_id_claim_keys()),
         workspace_label: claim_from_auth_or_top_level(claims, workspace_label_claim_keys()),
         seat_type: claim_from_auth_or_top_level(claims, seat_type_claim_keys()),
         plan_family: normalize_plan(auth_claims["chatgpt_plan_type"]),
         plan_label: auth_claims["chatgpt_plan_type"]
       }}
    else
      _invalid -> {:error, %{code: :codex_id_token_invalid, message: "Codex id token is invalid"}}
    end
  end

  def token_info(_id_token),
    do: {:error, %{code: :codex_id_token_invalid, message: "Codex id token is invalid"}}

  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @spec authorization_scope() :: String.t()
  def authorization_scope, do: @authorization_scope

  @spec browser_redirect_uri() :: String.t()
  def browser_redirect_uri, do: @browser_redirect_uri

  @spec device_redirect_uri() :: String.t()
  def device_redirect_uri, do: issuer() <> "/deviceauth/callback"

  @spec oauth_originator() :: String.t()
  def oauth_originator, do: CodexClientIdentity.originator()

  @spec issuer() :: String.t()
  def issuer do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:issuer, @issuer)
    |> String.trim_trailing("/")
  end

  @spec client() :: auth_client()
  defp client do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, __MODULE__.HTTPClient)
  end

  defp blank_string?(value), do: !is_binary(value) or String.trim(value) == ""

  defp auth_error(code, message, status),
    do: {:error, %{code: code, message: message, status: status}}

  defp workspace_id_claim_keys,
    do: ~w(workspace_id chatgpt_workspace_id organization_id org_id tenant_id)

  defp workspace_label_claim_keys,
    do: ~w(workspace_label workspace_name organization_name org_name tenant_name)

  defp seat_type_claim_keys, do: ~w(seat_type chatgpt_seat_type entitlement_type)

  defp claim_from_auth_or_top_level(claims, keys) do
    auth_claims = auth_claims(claims)

    first_present_claim(auth_claims, keys) || first_present_claim(claims, keys)
  end

  defp auth_claims(%{} = claims) do
    case Map.get(claims, "https://api.openai.com/auth") do
      %{} = auth_claims -> auth_claims
      _value -> %{}
    end
  end

  defp first_present_claim(claims, keys) when is_map(claims) do
    Enum.find_value(keys, &present_string(Map.get(claims, &1)))
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp normalize_plan(nil), do: nil

  defp normalize_plan(plan) do
    plan
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defmodule HTTPClient do
    @moduledoc false

    alias CodexPooler.Upstreams.Auth.CodexAuth
    alias CodexPooler.Upstreams.CloudflareCookies

    @browser_user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    @browser_sec_ch_ua ~S("Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99")

    @spec exchange_authorization_code(String.t(), String.t(), String.t()) ::
            CodexAuth.token_response()
    def exchange_authorization_code(code, verifier, redirect_uri) do
      request_tokens_for_authorization_code(code, verifier, redirect_uri)
    end

    @spec browser_request_headers() :: [{String.t(), String.t()}]
    defp browser_request_headers do
      origin = browser_origin()

      [
        {"accept", "*/*"},
        {"accept-language", "en-US,en;q=0.9"},
        {"cache-control", "no-cache"},
        {"origin", origin},
        {"pragma", "no-cache"},
        {"referer", origin <> "/"},
        {"sec-ch-ua", @browser_sec_ch_ua},
        {"sec-ch-ua-mobile", "?0"},
        {"sec-ch-ua-platform", "\"Windows\""},
        {"sec-fetch-dest", "empty"},
        {"sec-fetch-mode", "cors"},
        {"sec-fetch-site", "same-origin"},
        {"user-agent", @browser_user_agent}
      ]
    end

    @spec browser_origin() :: String.t()
    defp browser_origin, do: CodexAuth.issuer()

    @spec request_device_code() :: CodexAuth.device_code_response()
    def request_device_code do
      case Req.post(
             CodexAuth.issuer() <> "/api/accounts/deviceauth/usercode",
             headers: browser_request_headers(),
             json: %{client_id: CodexAuth.client_id()},
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          decode_device_code(body)

        {:ok, %{status: status}} when status >= 500 ->
          auth_error(
            :codex_auth_transient,
            "Codex authorization service returned a temporary error",
            502
          )

        {:ok, _response} ->
          auth_error(:codex_auth_unavailable, "Codex device authorization is unavailable", 503)

        {:error, reason} ->
          auth_error(:codex_auth_transient, Exception.message(reason), 502)
      end
    end

    @spec poll_device_authorization(map()) :: CodexAuth.token_response()
    def poll_device_authorization(state) do
      body = %{device_auth_id: state["device_auth_id"], user_code: state["user_code"]}

      case Req.post(CodexAuth.issuer() <> "/api/accounts/deviceauth/token",
             headers: browser_request_headers(),
             json: body,
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case body do
            %{"authorization_code" => code, "code_verifier" => verifier} ->
              request_tokens_for_authorization_code(
                code,
                verifier,
                CodexAuth.device_redirect_uri()
              )

            _invalid ->
              auth_error(:codex_auth_malformed, "Codex device response was incomplete", 502)
          end

        {:ok, %{status: status, body: body}} when status >= 400 ->
          poll_error(body, state, status)

        {:error, reason} ->
          auth_error(:codex_auth_transient, Exception.message(reason), 502)
      end
    end

    defp request_tokens_for_authorization_code(code, verifier, redirect_uri) do
      form = [
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: CodexAuth.client_id(),
        code_verifier: verifier
      ]

      case Req.post(CodexAuth.issuer() <> "/oauth/token",
             headers: browser_request_headers(),
             form: form,
             retry: false,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: %{"access_token" => access, "id_token" => id} = body}}
        when status in 200..299 ->
          {:ok, %{access_token: access, refresh_token: body["refresh_token"], id_token: id}}

        {:ok, %{status: status}} when status >= 500 ->
          auth_error(
            :codex_auth_transient,
            "Codex token exchange returned a temporary error",
            502
          )

        {:ok, _response} ->
          auth_error(:codex_oauth_exchange_failed, "Codex token exchange failed", 502)

        {:error, _reason} ->
          auth_error(:codex_auth_transient, "Codex token exchange failed", 502)
      end
    end

    @spec refresh_token(String.t(), CodexAuth.refresh_opts()) :: CodexAuth.refresh_response()
    def refresh_token(refresh_token, opts \\ []) do
      token_url =
        Keyword.get(opts, :token_url, CodexAuth.issuer() <> "/oauth/token")

      form = [
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: CodexAuth.client_id()
      ]

      receive_timeout = refresh_receive_timeout(opts)

      case post_with_cloudflare(token_url,
             form: form,
             retry: false,
             receive_timeout: receive_timeout
           ) do
        {:ok, %{status: status, body: %{"access_token" => access} = body}}
        when status in 200..299 ->
          {:ok,
           %{
             access_token: access,
             refresh_token: body["refresh_token"],
             expires_in: body["expires_in"]
           }}

        {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
          refresh_error(body, status)

        {:ok, %{status: status}} when status >= 500 ->
          auth_error(:codex_auth_transient, "Codex token refresh returned a temporary error", 502)

        {:ok, _response} ->
          auth_error(:codex_oauth_refresh_failed, "Codex token refresh failed", 502)

        {:error, reason} ->
          auth_error(:codex_auth_transient, Exception.message(reason), 502)
      end
    end

    defp post_with_cloudflare(url, opts) do
      headers =
        opts
        |> Keyword.get(:headers, browser_request_headers())
        |> then(&CloudflareCookies.request_headers(url, &1))

      opts =
        Keyword.put(opts, :headers, headers)

      result = Req.post(url, opts)
      CloudflareCookies.store_from_result(url, result)
      result
    end

    defp refresh_receive_timeout(opts) do
      opts
      |> Keyword.get(:receive_timeout, 30_000)
      |> case do
        value when is_integer(value) and value > 0 -> value
        _value -> 30_000
      end
    end

    defp refresh_error(%{} = body, _status) do
      if refresh_token_reauth_error?(body) do
        auth_error(
          :codex_refresh_token_revoked,
          "Codex refresh token requires reauthorization",
          401
        )
      else
        auth_error(:codex_oauth_refresh_failed, "Codex token refresh failed", 502)
      end
    end

    defp refresh_error(_body, _status),
      do: auth_error(:codex_oauth_refresh_failed, "Codex token refresh failed", 502)

    defp refresh_token_reauth_error?(%{"error" => error})
         when error in [
                "invalid_grant",
                "revoked",
                "invalid_refresh_token",
                "token_expired",
                "refresh_token_reused"
              ],
         do: true

    defp refresh_token_reauth_error?(%{"error" => %{"code" => code}})
         when code in [
                "invalid_grant",
                "revoked",
                "invalid_refresh_token",
                "token_expired",
                "refresh_token_reused"
              ],
         do: true

    defp refresh_token_reauth_error?(%{} = body) do
      body
      |> refresh_error_texts()
      |> Enum.any?(&refresh_token_reauth_text?/1)
    end

    defp refresh_error_texts(%{"error" => %{} = error} = body),
      do: refresh_error_texts(error) ++ refresh_error_texts(Map.delete(body, "error"))

    defp refresh_error_texts(%{} = body) do
      body
      |> Map.take(["error", "error_description", "error_message", "message"])
      |> Map.values()
      |> Enum.filter(&is_binary/1)
    end

    defp refresh_token_reauth_text?(text) when is_binary(text) do
      normalized = String.downcase(text)

      String.contains?(normalized, "refresh") and
        String.contains?(normalized, "token") and
        Enum.any?(["revoked", "expired", "invalid"], &String.contains?(normalized, &1))
    end

    defp refresh_token_reauth_text?(_text), do: false

    defp decode_device_code(%{} = body) do
      user_code = body["user_code"] || body["usercode"]

      with device_auth_id when is_binary(device_auth_id) <- body["device_auth_id"],
           user_code when is_binary(user_code) <- user_code do
        {:ok,
         %{
           "device_auth_id" => device_auth_id,
           "user_code" => user_code,
           "verification_url" => CodexAuth.issuer() <> "/codex/device",
           "expires_at" => body["expires_at"],
           "poll_interval_seconds" => parse_interval(body["interval"])
         }}
      else
        _invalid ->
          auth_error(:codex_auth_malformed, "Codex authorization response was incomplete", 502)
      end
    end

    defp poll_error(%{"error" => "authorization_pending"}, state, _status) do
      {:error,
       %{
         code: :codex_device_authorization_pending,
         message: "Codex device authorization is still pending",
         retry_after_seconds: parse_interval(state["poll_interval_seconds"])
       }}
    end

    defp poll_error(%{"error" => "slow_down"}, state, _status) do
      {:error,
       %{
         code: :codex_device_authorization_slow_down,
         message: "Codex device authorization polling should slow down",
         retry_after_seconds: parse_interval(state["poll_interval_seconds"]) + 5
       }}
    end

    defp poll_error(%{"error" => "expired_token"}, _state, _status),
      do: auth_error(:codex_device_code_expired, "Codex device authorization expired", 410)

    defp poll_error(%{"error" => "access_denied"}, _state, _status),
      do:
        auth_error(
          :codex_device_authorization_denied,
          "Codex device authorization was denied",
          403
        )

    defp poll_error(_body, _state, status) when status in [403, 404],
      do:
        auth_error(
          :codex_device_authorization_pending,
          "Codex device authorization is still pending",
          200
        )

    defp poll_error(_body, _state, status) when status >= 500,
      do:
        auth_error(
          :codex_auth_transient,
          "Codex authorization service returned a temporary error",
          502
        )

    defp poll_error(_body, _state, _status),
      do:
        auth_error(
          :codex_auth_malformed,
          "Codex authorization service returned an unexpected device status",
          502
        )

    defp parse_interval(value) when is_integer(value) and value > 0, do: value

    defp parse_interval(value) when is_binary(value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _invalid -> 5
      end
    end

    defp parse_interval(_value), do: 5

    defp auth_error(code, message, status),
      do: {:error, %{code: code, message: message, status: status}}
  end
end
