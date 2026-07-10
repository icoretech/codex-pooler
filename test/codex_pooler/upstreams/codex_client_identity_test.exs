defmodule CodexPooler.Upstreams.CodexClientIdentityTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Upstreams.CodexClientIdentity

  setup do
    previous = Application.get_env(:codex_pooler, CodexPooler.Catalog)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, CodexPooler.Catalog, previous),
        else: Application.delete_env(:codex_pooler, CodexPooler.Catalog)
    end)
  end

  test "uses one configured version for User-Agent and trusted identity headers" do
    Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: "9.8.7")

    assert CodexClientIdentity.headers() == [
             {"user-agent", "codex_cli_rs/9.8.7"},
             {"originator", "codex_cli_rs"},
             {"version", "9.8.7"}
           ]
  end

  test "keeps custom User-Agent overrides separate from trusted originator and version" do
    Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: "9.8.7")

    assert CodexClientIdentity.headers(" custom-client/1.2.3 ") == [
             {"user-agent", "custom-client/1.2.3"},
             {"originator", "codex_cli_rs"},
             {"version", "9.8.7"}
           ]
  end

  test "treats the legacy synthetic User-Agent as automatic during rolling upgrades" do
    Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: "9.8.7")

    assert CodexClientIdentity.user_agent("codex_cli_rs/0.0.0") == "codex_cli_rs/9.8.7"
  end
end
