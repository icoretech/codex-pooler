defmodule CodexPooler.Accounting.RequestLifecycle.IdentitySnapshot do
  @moduledoc false

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @spec persist_request_identity_snapshot(Request.t(), PoolUpstreamAssignment.t()) :: :ok
  def persist_request_identity_snapshot(
        %Request{} = request,
        %PoolUpstreamAssignment{} = assignment
      ) do
    snapshot = upstream_identity_snapshot(assignment.upstream_identity_id)
    persisted = Repo.get(Request, request.id)

    attrs =
      %{}
      |> maybe_put_snapshot_attr(
        :upstream_account_label,
        persisted && persisted.upstream_account_label,
        snapshot.upstream_account_label
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_email,
        persisted && persisted.upstream_account_email,
        snapshot.upstream_account_email
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_plan_label,
        persisted && persisted.upstream_account_plan_label,
        snapshot.upstream_account_plan_label
      )
      |> maybe_put_snapshot_attr(
        :upstream_account_plan_family,
        persisted && persisted.upstream_account_plan_family,
        snapshot.upstream_account_plan_family
      )

    if persisted && attrs != %{} do
      persisted
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()
    end

    :ok
  end

  @spec persist_finalized_request_snapshot!(Request.t(), Attempt.t(), map()) :: Request.t()
  def persist_finalized_request_snapshot!(%Request{} = request, %Attempt{} = attempt, pricing) do
    request_metadata =
      PricingResolution.update_request_metadata(request.request_metadata, pricing)

    request
    |> Ecto.Changeset.change(
      Map.merge(
        %{request_metadata: request_metadata},
        request_snapshot_updates(request, attempt, request_metadata, pricing)
      )
    )
    |> Repo.update!()
  end

  defp request_snapshot_updates(request, _attempt, request_metadata, pricing) do
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

  defp upstream_identity_snapshot(nil), do: %{}

  defp upstream_identity_snapshot(upstream_identity_id) do
    case Repo.get(UpstreamIdentity, upstream_identity_id) do
      %UpstreamIdentity{} = identity ->
        %{
          upstream_account_label: normalize_snapshot_value(identity.account_label),
          upstream_account_email: normalize_snapshot_email(identity.account_email),
          upstream_account_plan_label: normalize_snapshot_value(identity.plan_label),
          upstream_account_plan_family: normalize_snapshot_value(identity.plan_family)
        }

      nil ->
        %{}
    end
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
