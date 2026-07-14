defmodule CodexPooler.Gateway.Payloads.RequestOptions.WebsocketOwnerContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions.Normalization

  defstruct [
    :session,
    :lease_token,
    :downstream,
    :downstream_epoch,
    :proxy_instance_id,
    :owner_instance_id,
    enabled?: false,
    reject_if_busy?: false,
    forwarder_opts: []
  ]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          reject_if_busy?: boolean(),
          session: term(),
          lease_token: String.t() | nil,
          downstream: map() | nil,
          downstream_epoch: pos_integer() | nil,
          proxy_instance_id: String.t() | nil,
          owner_instance_id: String.t() | nil,
          forwarder_opts: keyword()
        }

  @spec build(map() | keyword()) :: t()
  def build(opts), do: update(%__MODULE__{}, opts)

  @spec update(t(), map() | keyword()) :: t()
  def update(%__MODULE__{} = current_owner, opts) do
    opts = Map.new(opts)

    current_owner
    |> maybe_replace_context(Map.get(opts, :websocket_owner))
    |> struct!(updates(opts))
  end

  defp maybe_replace_context(_current_owner, %__MODULE__{} = owner), do: owner

  defp maybe_replace_context(current_owner, owner_opts) when is_map(owner_opts),
    do: update(current_owner, owner_opts)

  defp maybe_replace_context(current_owner, _owner_opts), do: current_owner

  defp updates(opts) do
    %{}
    |> maybe_put_update(
      :enabled?,
      Map.get(opts, :websocket_owner_forwarding_enabled?, Map.get(opts, :enabled?)),
      &(&1 == true)
    )
    |> maybe_put_update(
      :reject_if_busy?,
      Map.get(opts, :websocket_owner_reject_if_busy?, Map.get(opts, :reject_if_busy?)),
      &(&1 == true)
    )
    |> maybe_put_update(
      :session,
      Map.get(opts, :websocket_owner_session, Map.get(opts, :session))
    )
    |> maybe_put_update(
      :lease_token,
      Map.get(opts, :websocket_owner_lease_token, Map.get(opts, :lease_token))
    )
    |> maybe_put_update(
      :downstream,
      Map.get(opts, :websocket_owner_downstream, Map.get(opts, :downstream))
    )
    |> maybe_put_update(
      :downstream_epoch,
      Map.get(opts, :websocket_owner_downstream_epoch, Map.get(opts, :downstream_epoch)),
      &Normalization.optional_positive_integer/1
    )
    |> maybe_put_update(
      :proxy_instance_id,
      Map.get(opts, :websocket_owner_proxy_instance_id, Map.get(opts, :proxy_instance_id))
    )
    |> maybe_put_update(
      :owner_instance_id,
      Map.get(opts, :websocket_owner_instance_id, Map.get(opts, :owner_instance_id))
    )
    |> maybe_put_update(
      :forwarder_opts,
      Map.get(opts, :websocket_owner_forwarder_opts, Map.get(opts, :forwarder_opts)),
      &forwarder_opts/1
    )
  end

  defp maybe_put_update(updates, key, value, normalizer \\ & &1)
  defp maybe_put_update(updates, _key, nil, _normalizer), do: updates

  defp maybe_put_update(updates, key, value, normalizer) do
    case normalizer.(value) do
      nil -> updates
      value -> Map.put(updates, key, value)
    end
  end

  defp forwarder_opts(values) when is_list(values), do: values
  defp forwarder_opts(_value), do: nil
end
