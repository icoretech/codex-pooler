defmodule CodexPoolerWeb.I18n.PlaceholdersTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.I18n.Placeholders

  test "extracts a set without depending on order or repeated bindings" do
    assert Placeholders.extract("%{name}: %{count}; %{name}") == MapSet.new(["name", "count"])
    assert :ok = Placeholders.compare("%{name}: %{count}", "%{count}：%{name} %{name}")
  end

  test "detects both missing and translator-introduced placeholders" do
    assert {:error, %{missing: ["name"], extra: ["user"]}} = Placeholders.compare("Hello %{name}", "你好，%{user}")
  end

  test "matches Gettext literal percent and unterminated binding behavior" do
    assert Placeholders.extract("100% %% %{} %{unterminated") == MapSet.new()
    assert Placeholders.extract("%%{name} %{ spaced name }") == MapSet.new(["name", " spaced name "])
    assert :ok = Placeholders.compare("100% ready", "已 100% 就绪")
  end
end
