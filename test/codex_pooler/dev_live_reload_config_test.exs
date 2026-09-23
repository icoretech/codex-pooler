defmodule CodexPooler.DevLiveReloadConfigTest do
  use ExUnit.Case, async: true

  # The managed dev listener reloaded on every Pooler copy other tooling writes
  # under the checkout's `tmp/`, because live reload watched the whole working
  # directory with relative patterns (findings#232).
  test "dev live reload watches this checkout's web sources and never a copy under tmp" do
    root = File.cwd!()
    config = Config.Reader.read!(Path.join(root, "config/dev.exs"), env: :dev)

    # Same default and expansion as `PhoenixLiveReload.Application`.
    dirs =
      config
      |> Keyword.get(:phoenix_live_reload, [])
      |> Keyword.get(:dirs, [""])
      |> Enum.map(&Path.expand(&1, root))

    patterns =
      config
      |> Keyword.fetch!(:codex_pooler)
      |> Keyword.fetch!(CodexPoolerWeb.Endpoint)
      |> Keyword.fetch!(:live_reload)
      |> Keyword.fetch!(:patterns)

    watched? = fn path -> Enum.any?(dirs, &String.starts_with?(path, &1 <> "/")) end
    reloads? = fn path -> watched?.(path) and Enum.any?(patterns, &Regex.match?(&1, path)) end

    for relative <- ["lib/codex_pooler_web/router.ex", "lib/codex_pooler_web/live/admin/pools_live.ex", "lib/codex_pooler_web/components/core_components.ex", "priv/static/assets/app.css", "priv/gettext/en/LC_MESSAGES/default.po"] do
      assert reloads?.(Path.join(root, relative)), relative
    end

    for relative <- ["tmp/s5-smoke/pooler-d0fd/lib/codex_pooler_web/router.ex", "tmp/p14-oot/lib/codex_pooler_web/live/admin/pools_live.ex", "tmp/gate-wave3b/priv/static/assets/app.css"] do
      refute watched?.(Path.join(root, relative)), relative
    end
  end
end
