defmodule CodexPooler.Gateway.Runtime.CommittedGatewayFixtureCleanupTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport, as: Support
  alias Ecto.Adapters.SQL.Sandbox

  test "committed gateway cleanup deletes its exact pricing and preserves same-model fixtures" do
    {:ok, fake} = FakeUpstream.start_link({:json, 200, %{}})

    Sandbox.unboxed_run(Repo, fn ->
      fixture = Support.gateway_setup(fake)
      other = Support.gateway_setup(fake)
      on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> Support.cleanup_unboxed_pool!(other) end) end)
      assert fixture.pricing.model_identifier == other.pricing.model_identifier
      refute fixture.pricing.price_version == other.pricing.price_version
      Support.cleanup_unboxed_pool!(fixture)
      refute Repo.get(PricingSnapshot, fixture.pricing.id)
      assert Repo.get!(PricingSnapshot, other.pricing.id)
      assert Repo.get!(UpstreamIdentity, other.identity.id)
      Support.cleanup_unboxed_pool!(fixture)
    end)
  end
end
