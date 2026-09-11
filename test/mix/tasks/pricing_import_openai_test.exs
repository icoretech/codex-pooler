defmodule Mix.Tasks.Pricing.ImportOpenaiTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.{Catalog, Release}
  alias Mix.Tasks.Pricing.ImportOpenai

  test "release-safe entrypoint uses the app priv path" do
    assert {:ok, result} = Catalog.import_openai_pricing_from_priv()
    assert result.source == "openai-json-pricing"
    assert String.ends_with?(result.price_version, ":importer-format-2")
    assert result.total > 0
    assert result.inserted >= 0
  end

  test "release helper returns the pricing import result" do
    repo_config = Application.get_env(:codex_pooler, CodexPooler.Repo)

    assert [%{source: "openai-json-pricing", total: total, inserted: inserted}] =
             Release.import_openai_pricing_from_priv()

    # The task names its own connections but must not leave that name on the
    # application's Repo config for everything that runs after it.
    assert Application.get_env(:codex_pooler, CodexPooler.Repo) == repo_config

    assert total > 0
    assert inserted >= 0
  end

  test "missing file raises a controlled Mix error" do
    assert_raise Mix.Error,
                 ~r/pricing import failed for .*missing\.json.*file_read_failed/i,
                 fn ->
                   ImportOpenai.run(["priv/pricing/openai/missing.json"])
                 end
  end
end
