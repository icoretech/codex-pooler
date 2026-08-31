defmodule CodexPooler.NativeCompactionTraceTestExportTest do
  use ExUnit.Case, async: false

  alias CodexPooler.NativeCompactionTraceTestExport

  setup do
    previous = System.get_env("CODEX_POOLER_TRACE_TEST_EXPORT_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("CODEX_POOLER_TRACE_TEST_EXPORT_DIR", previous),
        else: System.delete_env("CODEX_POOLER_TRACE_TEST_EXPORT_DIR")
    end)

    :ok
  end

  test "absent environment leaves the completed source untouched" do
    System.delete_env("CODEX_POOLER_TRACE_TEST_EXPORT_DIR")
    {root, source} = completed_trace_fixture()
    on_exit(fn -> File.rm_rf!(root) end)

    assert :disabled = NativeCompactionTraceTestExport.maybe_export(source, :success)
    assert File.exists?(source)
    assert Path.wildcard(Path.join(root, "success.jsonl")) == []
  end

  test "exports a complete private file atomically and refuses overwrite" do
    {source_root, source} = completed_trace_fixture()
    export_root = fresh_root("trace-test-export")

    on_exit(fn ->
      File.rm_rf!(source_root)
      File.rm_rf!(export_root)
    end)

    assert {:ok, destination} =
             NativeCompactionTraceTestExport.export!(source, export_root, :success)

    assert destination == Path.join(export_root, "success.jsonl")
    assert Bitwise.band(File.stat!(export_root).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(destination).mode, 0o777) == 0o600

    assert destination |> File.stream!() |> Enum.at(-1) |> Jason.decode!() |> Map.fetch!("event") ==
             "trace_stopped"

    assert_raise ArgumentError, ~r/already exists/, fn ->
      NativeCompactionTraceTestExport.export!(source, export_root, :success)
    end
  end

  test "rejects relative unsafe and symlink paths" do
    {source_root, source} = completed_trace_fixture()
    relative = "trace-export-relative"
    symlink_root = fresh_root("trace-export-symlink-parent")
    target = fresh_root("trace-export-symlink-target")
    symlink = Path.join(symlink_root, "link")
    File.ln_s!(target, symlink)

    on_exit(fn ->
      File.rm_rf!(source_root)
      File.rm_rf!(symlink_root)
      File.rm_rf!(target)
    end)

    assert_raise ArgumentError, ~r/must be absolute/, fn ->
      NativeCompactionTraceTestExport.export!(source, relative, :failure)
    end

    assert_raise ArgumentError, ~r/non-directory/, fn ->
      NativeCompactionTraceTestExport.export!(source, symlink, :failure)
    end
  end

  test "rejects an incomplete source" do
    source_root = fresh_root("trace-test-incomplete")
    export_root = fresh_root("trace-test-incomplete-export")
    source = Path.join(source_root, "source.jsonl")
    File.write!(source, Jason.encode!(%{"event" => "beam_call"}) <> "\n")

    on_exit(fn ->
      File.rm_rf!(source_root)
      File.rm_rf!(export_root)
    end)

    assert_raise ArgumentError, ~r/incomplete/, fn ->
      NativeCompactionTraceTestExport.export!(source, export_root, :failure)
    end

    refute File.exists?(Path.join(export_root, "failure.jsonl"))
  end

  defp completed_trace_fixture do
    root = fresh_root("trace-test-source")
    source = Path.join(root, "source.jsonl")

    File.write!(
      source,
      [
        Jason.encode!(%{"event" => "trace_started"}),
        Jason.encode!(%{"event" => "trace_stopped"})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    )

    File.chmod!(source, 0o600)
    {root, source}
  end

  defp fresh_root(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end
end
