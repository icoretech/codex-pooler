defmodule CodexPooler.Dev.MCPFixture.Receipt do
  @moduledoc false

  @lock_timeout_ms 10_000
  @lock_retry_ms 25

  @type setup :: %{required(String.t()) => term()}

  @spec read(String.t()) :: {:ok, setup()} | :missing | {:error, String.t()}
  def read(path) do
    with :ok <- reject_symlink(path) do
      case File.read(path) do
        {:ok, body} -> decode(body)
        {:error, :enoent} -> :missing
        {:error, _reason} -> {:error, "could not read MCP fixture receipt"}
      end
    end
  end

  @spec write!(String.t(), setup()) :: :ok
  def write!(path, setup) do
    root = Path.dirname(path)
    ensure_private_root!(root)
    reject_symlink!(path)

    temporary = path <> ".tmp-" <> random_suffix()
    payload = Jason.encode!(setup) <> "\n"

    try do
      {:ok, file} = File.open(temporary, [:write, :exclusive, :binary])
      :ok = File.chmod(temporary, 0o600)
      :ok = IO.binwrite(file, payload)
      :ok = File.close(file)
      :ok = File.rename(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  @spec remove!(String.t()) :: :ok
  def remove!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> raise "could not remove MCP fixture receipt"
    end
  end

  @spec with_lock(String.t(), (-> result)) :: result | {:error, String.t()} when result: var
  def with_lock(path, function) when is_function(function, 0) do
    deadline = System.monotonic_time(:millisecond) + @lock_timeout_ms
    acquire_lock(path <> ".lock", deadline, function)
  end

  defp acquire_lock(lock_path, deadline, function) do
    ensure_private_root!(Path.dirname(lock_path))

    case File.open(lock_path, [:write, :exclusive, :binary]) do
      {:ok, lock} ->
        try do
          :ok = File.chmod(lock_path, 0o600)
          function.()
        after
          File.close(lock)
          File.rm(lock_path)
        end

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@lock_retry_ms)
          acquire_lock(lock_path, deadline, function)
        else
          {:error, "MCP fixture receipt is busy"}
        end

      {:error, _reason} ->
        {:error, "could not lock MCP fixture receipt"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = setup} -> {:ok, setup}
      _invalid -> {:error, "MCP fixture receipt is invalid"}
    end
  end

  defp ensure_private_root!(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :symlink}} -> raise "MCP fixture root cannot be a symlink"
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> raise "MCP fixture root must be a directory"
      {:error, :enoent} -> File.mkdir_p!(root)
      {:error, _reason} -> raise "could not inspect MCP fixture root"
    end

    :ok = File.chmod(root, 0o700)
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "MCP fixture receipt cannot be a symlink"}

      {:ok, _stat} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        {:error, "could not inspect MCP fixture receipt"}
    end
  end

  defp reject_symlink!(path) do
    case reject_symlink(path) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  defp random_suffix do
    6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
