defmodule CodexPooler.Upstreams.Auth.CodexAuthJson do
  @moduledoc false

  @safe_onboarding_metadata %{
    "onboarding_method" => "auth_json_import",
    "auth_json_imported" => true
  }

  @type parse_error_code ::
          :expired_token
          | :invalid_auth_json
          | :invalid_token
          | :missing_account_identifier
          | :missing_refresh_token
          | :missing_token
          | :missing_tokens
          | :unsupported_auth_json
  @type parse_error :: %{required(:code) => parse_error_code(), required(:message) => String.t()}
  @type import_attrs :: %{
          required(:account_identifier) => String.t(),
          required(:account_email) => String.t() | nil,
          required(:account_label) => String.t(),
          required(:workspace_id) => String.t() | nil,
          required(:workspace_label) => String.t() | nil,
          required(:seat_type) => String.t() | nil,
          required(:plan_label) => String.t() | nil,
          required(:token) => String.t(),
          required(:refresh_token) => String.t(),
          required(:access_token_expires_at) => DateTime.t() | nil,
          required(:import_metadata) => map()
        }
  @type parse_result :: {:ok, import_attrs()} | {:error, parse_error()}

  @spec parse(term(), DateTime.t()) :: parse_result()
  def parse(content, now \\ DateTime.utc_now())

  def parse(content, now) when is_binary(content) do
    with {:ok, payload} <- decode_json(content),
         :ok <- ensure_chatgpt_auth(payload),
         {:ok, tokens} <- token_data(payload),
         {:ok, id_claims} <- token_claims(tokens["id_token"], :id_token),
         {:ok, access_claims} <- token_claims(tokens["access_token"], :access_token),
         :ok <- ensure_not_expired(access_claims, now),
         {:ok, account_identifier} <- account_identifier(tokens, id_claims),
         {:ok, refresh_token} <- required_token(tokens, "refresh_token", :missing_refresh_token) do
      {:ok,
       %{
         account_identifier: account_identifier,
         account_email: account_email(id_claims),
         account_label: account_label(id_claims),
         workspace_id: workspace_id(id_claims),
         workspace_label: workspace_label(id_claims),
         seat_type: seat_type(id_claims),
         plan_label: plan_label(id_claims),
         token: tokens["access_token"],
         refresh_token: refresh_token,
         access_token_expires_at: expires_at(access_claims),
         import_metadata: import_metadata(id_claims)
       }}
    end
  end

  def parse(_content, _now), do: parse_error(:invalid_auth_json, "Codex auth.json is required")

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, %{} = payload} -> {:ok, payload}
      {:ok, _value} -> parse_error(:invalid_auth_json, "Codex auth.json must be a JSON object")
      {:error, _reason} -> parse_error(:invalid_auth_json, "Codex auth.json is malformed")
    end
  end

  defp ensure_chatgpt_auth(%{"OPENAI_API_KEY" => key}) when is_binary(key) and key != "" do
    parse_error(:unsupported_auth_json, "Codex API-key auth.json is not supported")
  end

  defp ensure_chatgpt_auth(%{"personalAccessToken" => token}) when is_binary(token) do
    if present_string(token) do
      parse_error(:unsupported_auth_json, personal_access_token_unsupported_message())
    else
      :ok
    end
  end

  defp ensure_chatgpt_auth(%{"personal_access_token" => token}) when is_binary(token) do
    if present_string(token) do
      parse_error(:unsupported_auth_json, personal_access_token_unsupported_message())
    else
      :ok
    end
  end

  defp ensure_chatgpt_auth(%{"auth_mode" => mode}) when is_binary(mode) do
    case String.downcase(mode) do
      mode when mode in ["chatgpt", "chat_gpt"] ->
        :ok

      mode
      when mode in ["personalaccesstoken", "personal_access_token", "personal-access-token"] ->
        parse_error(:unsupported_auth_json, personal_access_token_unsupported_message())

      _mode ->
        parse_error(:unsupported_auth_json, "Codex auth.json must contain ChatGPT token auth")
    end
  end

  defp ensure_chatgpt_auth(%{"tokens" => %{"access_token" => access_token}})
       when is_binary(access_token) do
    if personal_access_token?(access_token) do
      parse_error(:unsupported_auth_json, personal_access_token_unsupported_message())
    else
      :ok
    end
  end

  defp ensure_chatgpt_auth(_payload), do: :ok

  defp token_data(%{"tokens" => %{} = tokens}), do: {:ok, tokens}

  defp token_data(_payload),
    do: parse_error(:missing_tokens, "Codex auth.json is missing ChatGPT token data")

  defp token_claims(token, token_name) when is_binary(token) and token != "" do
    case decode_jwt_payload(token) do
      {:ok, claims} ->
        {:ok, claims}

      {:error, _reason} ->
        parse_error(:invalid_token, "Codex auth.json contains an invalid #{token_name}")
    end
  end

  defp token_claims(_token, token_name),
    do: parse_error(:missing_token, "Codex auth.json is missing #{token_name}")

  defp decode_jwt_payload(jwt) do
    with [_header, payload, _signature] <- String.split(jwt, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      {:ok, claims}
    else
      _invalid -> {:error, :invalid_jwt}
    end
  end

  defp ensure_not_expired(claims, now) do
    case expires_at(claims) do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, now) == :gt do
          :ok
        else
          parse_error(:expired_token, "Codex auth.json access token is expired")
        end

      nil ->
        :ok
    end
  end

  defp account_identifier(tokens, id_claims) do
    identifier =
      present_string(tokens["account_id"]) || auth_claim(id_claims, "chatgpt_account_id")

    case identifier do
      nil ->
        parse_error(:missing_account_identifier, "Codex auth.json is missing account identity")

      value ->
        {:ok, value}
    end
  end

  defp required_token(tokens, key, code) do
    case present_string(tokens[key]) do
      nil -> parse_error(code, "Codex auth.json is missing #{key}")
      value -> {:ok, value}
    end
  end

  defp account_label(id_claims) do
    account_email(id_claims) || "Codex account"
  end

  defp account_email(id_claims) do
    present_string(id_claims["email"]) ||
      id_claims
      |> Map.get("https://api.openai.com/profile", %{})
      |> case do
        %{} = profile -> present_string(profile["email"])
        _profile -> nil
      end
  end

  defp import_metadata(id_claims) do
    case account_email(id_claims) do
      nil -> @safe_onboarding_metadata
      email -> Map.put(@safe_onboarding_metadata, "account_email", email)
    end
  end

  defp plan_label(id_claims), do: auth_claim(id_claims, "chatgpt_plan_type")

  defp workspace_id(id_claims),
    do: claim_from_auth_or_top_level(id_claims, workspace_id_claim_keys())

  defp workspace_label(id_claims),
    do: claim_from_auth_or_top_level(id_claims, workspace_label_claim_keys())

  defp seat_type(id_claims), do: claim_from_auth_or_top_level(id_claims, seat_type_claim_keys())

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

  defp auth_claim(id_claims, key) do
    id_claims
    |> Map.get("https://api.openai.com/auth", %{})
    |> case do
      %{} = auth -> present_string(auth[key])
      _auth -> nil
    end
  end

  defp expires_at(%{"exp" => exp}) when is_integer(exp) do
    exp
    |> DateTime.from_unix(:second)
    |> case do
      {:ok, datetime} -> DateTime.truncate(datetime, :microsecond)
      {:error, _reason} -> nil
    end
  end

  defp expires_at(%{"exp" => exp}) when is_binary(exp) do
    case Integer.parse(exp) do
      {seconds, ""} -> expires_at(%{"exp" => seconds})
      _invalid -> nil
    end
  end

  defp expires_at(_claims), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp personal_access_token?(token) when is_binary(token) do
    token
    |> String.trim()
    |> String.starts_with?("at-")
  end

  defp personal_access_token_unsupported_message,
    do: "Codex personal access token auth.json is not supported in this cycle"

  defp parse_error(code, message), do: {:error, %{code: code, message: message}}
end
