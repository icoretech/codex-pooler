defmodule CodexPooler.InstanceSettings.BodyReadTimeoutTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  setup do
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()
    :ok
  end

  test "new installations persist independent body-read and decompression defaults" do
    settings = InstanceSettings.ensure_singleton!()

    assert settings.ingress.body_read_timeout_ms == 15_000
    assert settings.ingress.decompression_timeout_ms == 10_000
    assert %{rows: [[15_000, 10_000]]} = Repo.query!("SELECT (ingress->>'body_read_timeout_ms')::integer, (ingress->>'decompression_timeout_ms')::integer FROM instance_settings")
  end

  test "legacy saved rows inherit their upload timeout and retain it when decode timeout changes" do
    InstanceSettings.ensure_singleton!()

    for timeout <- [10_000, 45_000] do
      Repo.query!("UPDATE instance_settings SET ingress = jsonb_set(ingress - 'body_read_timeout_ms', '{decompression_timeout_ms}', to_jsonb($1::integer))", [timeout])

      loaded = InstanceSettings.get!()
      assert loaded.ingress.body_read_timeout_ms == timeout
      assert OperationalSettings.from_instance_settings(loaded).body_read_timeout_ms == timeout

      assert {:ok, _updated} = InstanceSettings.update_system_settings(loaded, %{"ingress" => %{"decompression_timeout_ms" => 5_000}})

      reloaded = InstanceSettings.get!()
      assert reloaded.ingress.body_read_timeout_ms == timeout
      assert reloaded.ingress.decompression_timeout_ms == 5_000
      assert %{rows: [[^timeout]]} = Repo.query!("SELECT (ingress->>'body_read_timeout_ms')::integer FROM instance_settings")
    end
  end

  test "a saved body-read timeout remains independent across cache reload and unrelated saves" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} = InstanceSettings.update_system_settings(settings, %{"ingress" => %{"body_read_timeout_ms" => 37_000, "decompression_timeout_ms" => 2_000}})
    assert InstanceSettings.current().ingress.body_read_timeout_ms == 37_000
    assert {:ok, _updated} = InstanceSettings.update_system_settings(updated, %{"ingress" => %{"max_decompression_ratio" => 123}})

    InstanceSettings.reset_cache_for_test()
    current = OperationalSettings.from_instance_settings(InstanceSettings.current())
    assert current.body_read_timeout_ms == 37_000
    assert current.decompression_timeout_ms == 2_000
  end

  test "body-read timeout rejects missing, zero, negative and noninteger input" do
    settings = InstanceSettings.ensure_singleton!()

    for value <- [nil, 0, -1, "invalid", "1.5"] do
      assert {:error, changeset} = InstanceSettings.update_system_settings(settings, %{"ingress" => %{"body_read_timeout_ms" => value}})
      assert errors_on(changeset).ingress.body_read_timeout_ms != []
      assert InstanceSettings.get!().ingress.body_read_timeout_ms == 15_000
    end
  end

  test "operational projection accepts legacy in-memory ingress without the new field" do
    settings = Settings.default()
    ingress = settings.ingress |> Map.from_struct() |> Map.delete(:body_read_timeout_ms) |> Map.put(:decompression_timeout_ms, 29_000)

    assert OperationalSettings.from_instance_settings(%{settings | ingress: ingress}).body_read_timeout_ms == 29_000
  end
end
