defmodule CodexPooler.Upstreams.SavedResets.CreditLocatorTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Upstreams.SavedResets.CreditLocator

  @identity_id "018f47c2-15ec-7fc0-b767-5f8131eed403"
  @attempt_id "018f47c2-15ec-7fc0-b767-5f8131eed404"
  @consume_url "https://example.com/backend-api/wham/rate-limit-reset-credits/consume"
  @account_scope "acct_example"
  @known_fingerprint "ed4242f9be9aa9062c50c6f3035adec49000f342be79532001d3452da004f31c"

  setup do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "credit-locator-test-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn -> restore_upstream_config(previous) end)
  end

  describe "scope_fingerprint/3" do
    test "freezes the v1 length-prefixed serialization" do
      assert CreditLocator.scope_fingerprint("chatgpt_api", @consume_url, @account_scope) ==
               @known_fingerprint

      assert CreditLocator.scope_fingerprint("chatgpt_api", @consume_url, "") ==
               "3958539fa4065175406bb943d5f9749b968e2113f88310d0fe5d78aac8ec6582"
    end

    test "binds every literal outbound scope value without normalization" do
      baseline = CreditLocator.scope_fingerprint("chatgpt_api", @consume_url, @account_scope)

      for {family, url, scope} <- [
            {"ChatGPT_api", @consume_url, @account_scope},
            {"chatgpt_api", @consume_url <> "/", @account_scope},
            {"chatgpt_api", String.replace(@consume_url, "consume", "Consume"), @account_scope},
            {"chatgpt_api", String.replace(@consume_url, "rate-limit", "rate%2Dlimit"),
             @account_scope},
            {"chatgpt_api", @consume_url, String.upcase(@account_scope)},
            {"chatgpt_api", @consume_url, ""}
          ] do
        fingerprint = CreditLocator.scope_fingerprint(family, url, scope)
        refute fingerprint == baseline
        assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      end
    end
  end

  describe "seal/2 and open/2" do
    test "returns the credit only for the exact expected binding" do
      binding = locator_binding()

      assert {:ok, locator} = CreditLocator.seal("credit_example", binding)
      assert {:ok, "credit_example"} = CreditLocator.open(locator, binding)

      refute locator =~ "credit_example"
      refute locator =~ @consume_url
      refute locator =~ @account_scope
    end

    test "fails closed for every expected-field drift and tampering" do
      binding = locator_binding()
      assert {:ok, locator} = CreditLocator.seal("credit_example", binding)

      for changed <- [
            %{binding | identity_id: "018f47c2-15ec-7fc0-b767-5f8131eed405"},
            %{binding | attempt_id: "018f47c2-15ec-7fc0-b767-5f8131eed406"},
            %{binding | generation: 8},
            %{binding | endpoint_family: "codex_api"},
            %{binding | scope_fingerprint: String.duplicate("0", 64)}
          ] do
        assert {:error, %{code: :saved_reset_credit_locator_invalid}} =
                 CreditLocator.open(locator, changed)
      end

      assert {:error, %{code: :saved_reset_credit_locator_invalid}} =
               CreditLocator.open(locator <> "tampered", binding)
    end

    test "fails closed when the authenticated envelope AAD is changed" do
      binding = locator_binding()
      assert {:ok, locator} = CreditLocator.seal("credit_example", binding)

      tampered =
        locator
        |> Jason.decode!()
        |> put_in(["aad", "endpoint_family"], "codex_api")
        |> Jason.encode!()

      assert {:error, %{code: :saved_reset_credit_locator_invalid}} =
               CreditLocator.open(tampered, binding)
    end

    test "fails closed when the encryption key rotates" do
      binding = locator_binding()
      assert {:ok, locator} = CreditLocator.seal("credit_example", binding)

      Application.put_env(:codex_pooler, CodexPooler.Upstreams,
        upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "rotated-credit-locator-key")),
        upstream_secret_key_version: "test-v2"
      )

      assert {:error, %{code: :saved_reset_credit_locator_invalid}} =
               CreditLocator.open(locator, binding)
    end

    test "rejects malformed bindings before encryption" do
      for invalid <- [
            %{locator_binding() | identity_id: "not-a-uuid"},
            %{locator_binding() | attempt_id: nil},
            %{locator_binding() | generation: -1},
            %{locator_binding() | endpoint_family: ""},
            %{locator_binding() | scope_fingerprint: String.duplicate("A", 64)}
          ] do
        assert {:error, %{code: :saved_reset_credit_locator_invalid}} =
                 CreditLocator.seal("credit_example", invalid)
      end
    end
  end

  defp locator_binding do
    %{
      identity_id: @identity_id,
      attempt_id: @attempt_id,
      generation: 7,
      endpoint_family: "chatgpt_api",
      scope_fingerprint: @known_fingerprint
    }
  end

  defp restore_upstream_config(nil),
    do: Application.delete_env(:codex_pooler, CodexPooler.Upstreams)

  defp restore_upstream_config(previous),
    do: Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
end
