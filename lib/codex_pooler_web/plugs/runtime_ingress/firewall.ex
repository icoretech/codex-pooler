defmodule CodexPoolerWeb.Plugs.RuntimeIngress.Firewall do
  @moduledoc false

  import Plug.Conn
  require Logger

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @denial_event [:codex_pooler, :ingress, :firewall, :denied]
  @denial_reasons [
    :invalid_trusted_proxy_rules,
    :invalid_forwarded_bytes,
    :forwarded_entry_too_long,
    :invalid_forwarded_entry,
    :forwarded_hop_limit_exceeded,
    :forwarded_chain_unresolved,
    :forwarded_header_missing,
    :forwarded_depth_unsatisfied,
    :duplicate_x_real_ip,
    :invalid_allowlist_rules,
    :not_allowed,
    :settings_unavailable,
    :websocket_revoked
  ]
  @scopes [:runtime, :mcp]
  @denial_reason_values Enum.map(@denial_reasons, &Atom.to_string/1)
  @scope_values Enum.map(@scopes, &Atom.to_string/1)

  @type conn :: Plug.Conn.t()
  @type denial_reason ::
          :invalid_trusted_proxy_rules
          | :invalid_forwarded_bytes
          | :forwarded_entry_too_long
          | :invalid_forwarded_entry
          | :forwarded_hop_limit_exceeded
          | :forwarded_chain_unresolved
          | :forwarded_header_missing
          | :forwarded_depth_unsatisfied
          | :duplicate_x_real_ip
          | :invalid_allowlist_rules
          | :not_allowed
          | :settings_unavailable
          | :websocket_revoked
  @type scope :: :runtime | :mcp
  @type settings :: OperationalSettings.t()

  defmodule Decision do
    @moduledoc false

    @enforce_keys [:outcome, :reason, :client_ip]
    defstruct [:outcome, :reason, :client_ip]

    @type t :: %__MODULE__{
            outcome: :allow | :deny,
            reason: nil | CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.denial_reason(),
            client_ip: :inet.ip_address() | nil
          }
  end

  @spec denial_reasons() :: [denial_reason()]
  def denial_reasons, do: @denial_reasons

  @spec evaluate(conn(), settings()) :: {conn(), Decision.t()}
  def evaluate(conn, settings) do
    if OperationalSettings.firewall_enabled?(settings) do
      case settings.firewall_allowlist_compiled do
        {:ok, allowlist} -> evaluate_resolved_client(conn, settings, allowlist)
        {:error, :invalid_rule} -> {conn, denied(:invalid_allowlist_rules, conn.remote_ip)}
      end
    else
      {conn, allowed(conn.remote_ip)}
    end
  end

  @spec evaluate_client_ip(:inet.ip_address(), settings()) :: Decision.t()
  def evaluate_client_ip(client_ip, settings) do
    if OperationalSettings.firewall_enabled?(settings) do
      case settings.firewall_allowlist_compiled do
        {:ok, allowlist} -> evaluate_compiled_client_ip(client_ip, allowlist)
        {:error, :invalid_rule} -> denied(:invalid_allowlist_rules, client_ip)
      end
    else
      allowed(client_ip)
    end
  end

  @spec denied(denial_reason(), :inet.ip_address() | nil) :: Decision.t()
  def denied(reason, client_ip \\ nil) when reason in @denial_reasons do
    %Decision{outcome: :deny, reason: reason, client_ip: client_ip}
  end

  @spec observe_denial(Decision.t(), scope()) :: :ok
  def observe_denial(%Decision{outcome: :deny, reason: reason}, scope)
      when reason in @denial_reasons and scope in @scopes do
    metadata = %{scope: Atom.to_string(scope), reason: Atom.to_string(reason)}

    :telemetry.execute(@denial_event, %{count: 1}, metadata)
    log_denial(metadata)
  end

  @spec telemetry_tag_values(map()) :: %{scope: String.t(), reason: String.t()}
  def telemetry_tag_values(metadata) do
    %{
      scope: bounded_tag(metadata[:scope], @scope_values),
      reason: bounded_tag(metadata[:reason], @denial_reason_values)
    }
  end

  defp evaluate_resolved_client(conn, settings, allowlist) do
    case client_ip_resolution(conn, settings) do
      {conn, %Resolution{status: :ok, client_ip: client_ip}} ->
        decision = evaluate_compiled_client_ip(client_ip, allowlist)
        conn = if decision.outcome == :allow, do: %{conn | remote_ip: client_ip}, else: conn
        {conn, decision}

      {conn, %Resolution{status: :error, client_ip: client_ip, reason: reason}} ->
        {conn, denied(reason, client_ip)}
    end
  end

  defp evaluate_compiled_client_ip(client_ip, allowlist) do
    if IPRules.allowed?(client_ip, allowlist) do
      allowed(client_ip)
    else
      denied(:not_allowed, client_ip)
    end
  end

  defp allowed(client_ip), do: %Decision{outcome: :allow, reason: nil, client_ip: client_ip}

  defp log_denial(metadata) do
    previous_metadata = Logger.metadata()

    try do
      Logger.reset_metadata(scope: metadata.scope, reason: metadata.reason)
      Logger.warning("ingress firewall denied")
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp client_ip_resolution(
         %Plug.Conn{private: %{codex_pooler_client_ip_resolution: %Resolution{} = resolution}} =
           conn,
         _settings
       ) do
    {conn, resolution}
  end

  defp client_ip_resolution(conn, settings) do
    peer_ip = conn.private[:codex_pooler_peer_ip] || conn.remote_ip
    resolution = ForwardedClientIP.resolve(%{conn | remote_ip: peer_ip}, settings)

    conn =
      conn
      |> put_private(:codex_pooler_peer_ip, peer_ip)
      |> put_private(:codex_pooler_client_ip_resolution, resolution)

    {conn, resolution}
  end

  defp bounded_tag(value, allowed_values) when is_atom(value) do
    value
    |> Atom.to_string()
    |> bounded_tag(allowed_values)
  end

  defp bounded_tag(value, allowed_values) when is_binary(value),
    do: if(value in allowed_values, do: value, else: "unknown")

  defp bounded_tag(_value, _allowed_values), do: "unknown"
end
