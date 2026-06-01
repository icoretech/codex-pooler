defmodule CodexPooler.Accounting.RequestLifecycle.IdentitySnapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @spec persist_request_identity_snapshot(Request.t(), PoolUpstreamAssignment.t(), map()) :: :ok
  def persist_request_identity_snapshot(
        %Request{} = request,
        %PoolUpstreamAssignment{} = assignment,
        attrs \\ %{}
      ) do
    snapshot = upstream_identity_snapshot(assignment, attrs)

    attrs =
      %{}
      |> maybe_put_snapshot_attr(
        :upstream_account_label,
        request.upstream_account_label,
        snapshot.upstream_account_label
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_email,
        request.upstream_account_email,
        snapshot.upstream_account_email
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_plan_label,
        request.upstream_account_plan_label,
        snapshot.upstream_account_plan_label
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_plan_family,
        request.upstream_account_plan_family,
        snapshot.upstream_account_plan_family
      )

    if attrs != %{}, do: persist_missing_snapshot_attrs!(request, attrs)

    :ok
  end

  @spec finalized_request_snapshot_attrs(Request.t(), map()) :: map()
  def finalized_request_snapshot_attrs(%Request{} = request, pricing) do
    request_metadata =
      PricingResolution.update_request_metadata(request.request_metadata, pricing)

    Map.merge(
      %{request_metadata: request_metadata},
      request_snapshot_updates(request, request_metadata, pricing)
    )
  end

  defp request_snapshot_updates(request, request_metadata, pricing) do
    settings_snapshot =
      PricingResolution.request_settings_snapshot(%{}, request_metadata, pricing)

    %{
      upstream_account_label: request.upstream_account_label,
      upstream_account_email: request.upstream_account_email,
      upstream_account_plan_label: request.upstream_account_plan_label,
      upstream_account_plan_family: request.upstream_account_plan_family,
      reasoning_effort: settings_snapshot.reasoning_effort || request.reasoning_effort,
      requested_service_tier:
        settings_snapshot.requested_service_tier || request.requested_service_tier,
      actual_service_tier: settings_snapshot.actual_service_tier || request.actual_service_tier,
      service_tier:
        settings_snapshot.service_tier ||
          settings_snapshot.actual_service_tier ||
          settings_snapshot.requested_service_tier || request.service_tier
    }
  end

  defp upstream_identity_snapshot(_assignment, %{
         upstream_identity: %UpstreamIdentity{} = identity
       }) do
    upstream_identity_snapshot(identity)
  end

  defp upstream_identity_snapshot(
         %PoolUpstreamAssignment{upstream_identity_id: upstream_identity_id},
         _attrs
       ) do
    upstream_identity_snapshot(upstream_identity_id)
  end

  defp upstream_identity_snapshot(%UpstreamIdentity{} = identity) do
    %{
      upstream_account_label: normalize_snapshot_value(identity.account_label),
      upstream_account_email: normalize_snapshot_email(identity.account_email),
      upstream_account_plan_label: normalize_snapshot_value(identity.plan_label),
      upstream_account_plan_family: normalize_snapshot_value(identity.plan_family)
    }
  end

  defp upstream_identity_snapshot(nil), do: %{}

  defp upstream_identity_snapshot(upstream_identity_id) do
    case Repo.get(UpstreamIdentity, upstream_identity_id) do
      %UpstreamIdentity{} = identity ->
        upstream_identity_snapshot(identity)

      nil ->
        %{}
    end
  end

  defp persist_missing_snapshot_attrs!(%Request{id: request_id}, attrs) do
    Repo.update_all(
      from(request in Request,
        where: request.id == ^request_id,
        update: [
          set: [
            upstream_account_label:
              fragment(
                "COALESCE(?, ?)",
                request.upstream_account_label,
                ^Map.get(attrs, :upstream_account_label)
              ),
            upstream_account_email:
              fragment(
                "COALESCE(?, ?)",
                request.upstream_account_email,
                ^Map.get(attrs, :upstream_account_email)
              ),
            upstream_account_plan_label:
              fragment(
                "COALESCE(?, ?)",
                request.upstream_account_plan_label,
                ^Map.get(attrs, :upstream_account_plan_label)
              ),
            upstream_account_plan_family:
              fragment(
                "COALESCE(?, ?)",
                request.upstream_account_plan_family,
                ^Map.get(attrs, :upstream_account_plan_family)
              )
          ]
        ]
      ),
      []
    )
  end

  defp normalize_snapshot_email(email) when is_binary(email) do
    email
    |> normalize_snapshot_value()
    |> case do
      nil -> nil
      normalized -> if(String.contains?(normalized, "@"), do: normalized, else: nil)
    end
  end

  defp normalize_snapshot_email(_email), do: nil

  defp maybe_put_snapshot_attr(attrs, _key, existing, _incoming)
       when is_binary(existing) and existing != "",
       do: attrs

  defp maybe_put_snapshot_attr(attrs, key, _existing, incoming)
       when is_binary(incoming) and incoming != "",
       do: Map.put(attrs, key, incoming)

  defp maybe_put_snapshot_attr(attrs, _key, _existing, _incoming), do: attrs

  defp normalize_snapshot_value(nil), do: nil

  defp normalize_snapshot_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_snapshot_value(value), do: value |> to_string() |> normalize_snapshot_value()
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
end
