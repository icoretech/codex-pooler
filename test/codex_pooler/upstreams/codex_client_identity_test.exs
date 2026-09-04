defmodule CodexPooler.Upstreams.CodexClientIdentityTest do
  use ExUnit.Case, async: false

  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.Upstreams.CodexClientIdentity

  setup do
    previous = Application.get_env(:codex_pooler, CodexPooler.Catalog)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, CodexPooler.Catalog, previous),
        else: Application.delete_env(:codex_pooler, CodexPooler.Catalog)
    end)
  end

  test "defaults to the released client that owns the native compatibility contract" do
    Application.delete_env(:codex_pooler, CodexPooler.Catalog)

    version =
      CompatibilityMatrix.fixture!(:responses_chat)
      |> get_in([:compaction_recovery_boundary, :harness_applicability, :codex, :version])
      |> String.trim_leading("rust-v")

    assert CodexClientIdentity.version() == version
    assert CodexClientIdentity.user_agent() == "codex_cli_rs/#{version}"

    assert CodexClientIdentity.headers() == [
             {"user-agent", "codex_cli_rs/#{version}"},
             {"originator", "codex_cli_rs"},
             {"version", version}
           ]
  end

  test "uses one configured version for User-Agent and trusted identity headers" do
    Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: "9.8.7")

    assert CodexClientIdentity.user_agent() == "codex_cli_rs/9.8.7"

    assert CodexClientIdentity.headers() == [
             {"user-agent", "codex_cli_rs/9.8.7"},
             {"originator", "codex_cli_rs"},
             {"version", "9.8.7"}
           ]
  end
end
