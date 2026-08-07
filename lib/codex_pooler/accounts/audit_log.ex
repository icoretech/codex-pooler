defmodule CodexPooler.Accounts.AuditLog do
  @moduledoc false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Postgres.INET

  @type audit_result :: Audit.audit_result() | {:ok, nil}

  @type event_attrs :: %{
          required(:action) => String.t(),
          required(:target_type) => String.t(),
          optional(:target_id) => Ecto.UUID.t() | nil,
          optional(:metadata) => map(),
          optional(:details) => map()
        }

  @spec record_user_event(User.t() | Scope.t() | term(), event_attrs()) :: audit_result()
  def record_user_event(actor, attrs)

  def record_user_event(%User{} = user, attrs) when is_map(attrs) do
    metadata = Map.get(attrs, :metadata, %{})
    details = merge_ingress_peer_provenance(Map.get(attrs, :details, %{}), metadata)

    Audit.record_user_event(user, %{
      action: Map.fetch!(attrs, :action),
      target_type: Map.fetch!(attrs, :target_type),
      target_id: Map.get(attrs, :target_id),
      correlation_id: Map.get(attrs, :correlation_id) || metadata_value(metadata, :request_id),
      ip_address: Map.get(attrs, :ip_address) || inet(metadata_value(metadata, :ip_address)),
      details: details
    })
  end

  def record_user_event(%Scope{user: %User{} = user}, attrs) when is_map(attrs) do
    record_user_event(user, attrs)
  end

  def record_user_event(_actor, attrs) when is_map(attrs), do: {:ok, nil}

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  defp metadata_value(_metadata, _key), do: nil

  defp merge_ingress_peer_provenance(details, metadata) when is_map(details) do
    case normalize_ingress_peer_provenance(metadata_value(metadata, :ingress_peer_provenance)) do
      nil -> details
      provenance -> Map.put(details, :ingress_peer_provenance, provenance)
    end
  end

  defp merge_ingress_peer_provenance(details, _metadata), do: details

  defp normalize_ingress_peer_provenance(provenance) when is_map(provenance) do
    source = metadata_value(provenance, :client_ip_source)
    peer_ip = metadata_value(provenance, :immediate_peer_ip)
    inspected_hops = metadata_value(provenance, :inspected_hops)

    with source when source in [:x_forwarded_for, :x_real_ip, "x_forwarded_for", "x_real_ip"] <-
           source,
         {:ok, address} <- parse_ip(peer_ip),
         true <- is_integer(inspected_hops) and inspected_hops >= 0 do
      %{
        immediate_peer_ip: address |> :inet.ntoa() |> to_string(),
        client_ip_source: to_string(source),
        inspected_hops: min(inspected_hops, 32)
      }
    else
      _invalid -> nil
    end
  end

  defp normalize_ingress_peer_provenance(_provenance), do: nil

  defp parse_ip(value) when is_binary(value) do
    case :inet.parse_address(:binary.bin_to_list(value)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_value), do: :error

  defp inet(value) do
    case INET.cast(value) do
      {:ok, inet} -> inet
      :error -> nil
    end
  end
end
