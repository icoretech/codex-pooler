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

  test "defaults to one managed release pin and keeps its identity headers consistent" do
    Application.delete_env(:codex_pooler, CodexPooler.Catalog)

    managed_version =
      :codex_pooler
      |> Application.fetch_env!(CodexClientIdentity)
      |> Keyword.fetch!(:default_client_version)

    assert managed_version =~ ~r/\A\d+\.\d+\.\d+\z/
    assert CodexClientIdentity.version() == managed_version
    assert CodexClientIdentity.user_agent() == "codex_cli_rs/#{managed_version}"

    assert CodexClientIdentity.headers() == [
             {"user-agent", "codex_cli_rs/#{managed_version}"},
             {"originator", "codex_cli_rs"},
             {"version", managed_version}
           ]
  end

  test "falls back to the managed release pin for invalid configured versions" do
    Application.delete_env(:codex_pooler, CodexPooler.Catalog)

    managed_version =
      :codex_pooler
      |> Application.fetch_env!(CodexClientIdentity)
      |> Keyword.fetch!(:default_client_version)

    for version <- [nil, "", "rust-v0.153.4", "not-a-version", 153, %{}] do
      Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: version)

      assert CodexClientIdentity.version() == managed_version
      assert CodexClientIdentity.user_agent() == "codex_cli_rs/#{managed_version}"

      assert CodexClientIdentity.headers() == [
               {"user-agent", "codex_cli_rs/#{managed_version}"},
               {"originator", "codex_cli_rs"},
               {"version", managed_version}
             ]
    end
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
