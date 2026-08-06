defmodule CodexPoolerWeb.DevFeaturesTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.InstanceSettings
  alias CodexPoolerWeb.DevFeatures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = %{
      dev_features_enabled: Application.fetch_env(:codex_pooler, :dev_features_enabled),
      impeccable_live_dir: Application.fetch_env(:codex_pooler, :impeccable_live_dir)
    }

    Application.put_env(:codex_pooler, :dev_features_enabled, true)
    Application.put_env(:codex_pooler, :impeccable_live_dir, tmp_dir)

    # The settings cache outlives a sandbox rollback, so the toggle is pinned
    # here rather than inherited from whichever test ran first.
    set_live_toggle(false)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  describe "impeccable live client resolution" do
    test "renders nothing while the development toggle is off", %{tmp_dir: tmp_dir} do
      write_helper!(tmp_dir, port: 8400, token: "d6a1f0c2-0000-4000-8000-000000000000")

      assert DevFeatures.impeccable_live_script_src() == nil
      assert DevFeatures.browser_csp_extra_sources() == []
      assert DevFeatures.impeccable_live_status() == :disabled
    end

    test "carries the running helper's port and session token", %{tmp_dir: tmp_dir} do
      enable_live!()
      token = "d6a1f0c2-9d4b-4a7e-8f21-51c0b0f9a3e1"
      write_helper!(tmp_dir, port: 8433, token: token)

      assert DevFeatures.impeccable_live_script_src() ==
               "http://localhost:8433/live.js?token=#{token}"

      assert DevFeatures.browser_csp_extra_sources() == [
               script_src: ["http://localhost:8433"],
               connect_src: ["http://localhost:8433"],
               img_src: ["blob:"]
             ]
    end

    test "renders nothing and reports a missing helper without a handshake file" do
      enable_live!()

      assert DevFeatures.impeccable_live_script_src() == nil
      assert DevFeatures.browser_csp_extra_sources() == []
      assert DevFeatures.impeccable_live_status() == :helper_missing
    end

    test "ignores a handshake file that carries no usable port or token", %{tmp_dir: tmp_dir} do
      enable_live!()
      File.write!(Path.join(tmp_dir, "server.json"), Jason.encode!(%{pid: 42, port: 0}))

      assert DevFeatures.impeccable_live_script_src() == nil
      assert DevFeatures.impeccable_live_status() == :helper_missing
    end

    test "stands down when the injector already wrote a tag", %{tmp_dir: tmp_dir} do
      enable_live!()
      write_helper!(tmp_dir, port: 8400, token: "d6a1f0c2-0000-4000-8000-000000000001")
      write_injected_layout!(tmp_dir)

      # No second widget, but the injected tag still needs the CSP allowance.
      assert DevFeatures.impeccable_live_script_src() == nil
      assert DevFeatures.impeccable_live_status() == :externally_injected

      assert Keyword.fetch!(DevFeatures.browser_csp_extra_sources(), :script_src) == [
               "http://localhost:8400"
             ]
    end
  end

  describe "impeccable_live_status/0" do
    test "is unavailable when development features are off" do
      Application.put_env(:codex_pooler, :dev_features_enabled, false)
      enable_live!()

      assert DevFeatures.impeccable_live_status() == :unavailable
    end

    test "reports a stale handshake file as unreachable", %{tmp_dir: tmp_dir} do
      enable_live!()
      write_helper!(tmp_dir, port: closed_port(), token: "d6a1f0c2-0000-4000-8000-000000000002")

      assert {:helper_unreachable, "http://localhost:" <> _port} =
               DevFeatures.impeccable_live_status()
    end

    test "reports ready when the helper answers on its port", %{tmp_dir: tmp_dir} do
      enable_live!()
      port = listening_port()
      write_helper!(tmp_dir, port: port, token: "d6a1f0c2-0000-4000-8000-000000000003")

      assert DevFeatures.impeccable_live_status() == {:ready, "http://localhost:#{port}"}
    end
  end

  defp enable_live!, do: set_live_toggle(true)

  defp set_live_toggle(value) do
    {:ok, _settings} =
      InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
        "development" => %{"impeccable_live_enabled" => value}
      })

    :ok
  end

  defp write_helper!(dir, opts) do
    File.write!(
      Path.join(dir, "server.json"),
      Jason.encode!(%{
        pid: System.pid() |> String.to_integer(),
        port: Keyword.fetch!(opts, :port),
        token: Keyword.fetch!(opts, :token)
      })
    )
  end

  # A live config plus a marked target is what an accidental `live.mjs` run
  # leaves behind.
  defp write_injected_layout!(dir) do
    layout = Path.join(dir, "root.html.heex")
    File.write!(layout, "<body>\n<!-- impeccable-live-start -->\n</body>\n")
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{files: [layout]}))
  end

  defp listening_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    port
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:codex_pooler, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:codex_pooler, key)
end
