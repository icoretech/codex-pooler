defmodule CodexPooler.NativeCompactionTraceTestExport do
  @moduledoc false

  @env "CODEX_POOLER_TRACE_TEST_EXPORT_DIR"

  @spec maybe_export(Path.t(), :success | :failure) :: :disabled | {:ok, Path.t()}
  def maybe_export(source, kind) when kind in [:success, :failure] do
    case System.get_env(@env) do
      nil ->
        :disabled

      export_root ->
        export!(source, export_root, kind)
    end
  end

  @spec export!(Path.t(), Path.t(), :success | :failure) :: {:ok, Path.t()}
  def export!(source, export_root, kind) when kind in [:success, :failure] do
    require_test_env!()
    root = validate_root!(export_root)
    source = Path.expand(source)
    destination = Path.join(root, "#{kind}.jsonl")
    temporary = destination <> ".tmp-#{System.unique_integer([:positive])}"

    validate_source!(source)
    reject_existing!(destination)

    try do
      {:ok, source_io} = File.open(source, [:read, :binary])

      try do
        {:ok, destination_io} = File.open(temporary, [:write, :binary, :exclusive])

        try do
          :ok = copy_stream(source_io, destination_io)
          :ok = :file.sync(destination_io)
        after
          File.close(destination_io)
        end
      after
        File.close(source_io)
      end

      File.chmod!(temporary, 0o600)
      assert_complete!(temporary)
      :ok = File.rename(temporary, destination)
      File.chmod!(destination, 0o600)
      IO.puts("TRACE_TEST_EXPORT=#{destination}")
      {:ok, destination}
    after
      if File.exists?(temporary), do: File.rm!(temporary)
    end
  end

  defp require_test_env! do
    unless Mix.env() == :test, do: raise(ArgumentError, "trace test export is test-only")
  end

  defp validate_root!(root) when is_binary(root) do
    unless Path.type(root) == :absolute,
      do: raise(ArgumentError, "trace export directory must be absolute")

    expanded = Path.expand(root)
    temp = Path.expand(System.tmp_dir!())

    unless expanded != temp and String.starts_with?(expanded, temp <> "/"),
      do: raise(ArgumentError, "trace export directory must be below the system temp directory")

    ensure_directory_chain!(expanded, temp)
    File.chmod!(expanded, 0o700)

    stat = File.lstat!(expanded)

    unless stat.type == :directory and Bitwise.band(stat.mode, 0o777) == 0o700,
      do: raise(ArgumentError, "trace export directory must be a private directory")

    expanded
  end

  defp validate_root!(_root), do: raise(ArgumentError, "invalid trace export directory")

  defp ensure_directory_chain!(path, temp) do
    relative = Path.relative_to(path, temp)

    Enum.reduce(Path.split(relative), temp, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> :ok
        {:ok, _other} -> raise ArgumentError, "trace export path contains a non-directory"
        {:error, :enoent} -> File.mkdir!(next)
        {:error, reason} -> raise File.Error, reason: reason, action: "inspect", path: next
      end

      File.chmod!(next, 0o700)
      next
    end)
  end

  defp validate_source!(source) do
    case File.lstat(source) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _other} -> raise ArgumentError, "trace source must be a regular file"
      {:error, reason} -> raise File.Error, reason: reason, action: "inspect", path: source
    end
  end

  defp reject_existing!(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> raise ArgumentError, "trace export destination already exists"
      {:error, reason} -> raise File.Error, reason: reason, action: "inspect", path: path
    end
  end

  defp copy_stream(source, destination) do
    case IO.binread(source, 64 * 1024) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      data ->
        :ok = IO.binwrite(destination, data)
        copy_stream(source, destination)
    end
  end

  defp assert_complete!(path) do
    last = path |> File.stream!() |> Enum.reduce(nil, fn line, _last -> line end)

    unless is_binary(last) and Jason.decode!(last)["event"] == "trace_stopped",
      do: raise(ArgumentError, "trace export source is incomplete")
  end
end
