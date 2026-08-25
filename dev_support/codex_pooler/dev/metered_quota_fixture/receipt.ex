defmodule CodexPooler.Dev.MeteredQuotaFixture.Receipt do
  @moduledoc false

  @lock_timeout_ms 10_000
  @lock_retry_ms 25

  @type document :: %{required(String.t()) => term()}

  @spec read(String.t(), String.t()) :: {:ok, document()} | :missing | {:error, String.t()}
  def read(path, allowed_root) do
    with :ok <- validate_path(path, allowed_root),
         :ok <- validate_receipt_node(path) do
      case File.read(path) do
        {:ok, body} -> decode(body)
        {:error, :enoent} -> :missing
        {:error, _reason} -> {:error, "could not read metered quota fixture receipt"}
      end
    end
  end

  @spec write(String.t(), String.t(), document()) :: :ok | {:error, String.t()}
  def write(path, allowed_root, document) do
    with :ok <- validate_path(path, allowed_root),
         :ok <- ensure_private_parent(path),
         :ok <- validate_receipt_node(path) do
      temporary = path <> ".tmp-" <> random_suffix()

      try do
        with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]),
             :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, Jason.encode!(document) <> "\n"),
             :ok <- File.close(file),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          _failure -> {:error, "could not write metered quota fixture receipt"}
        end
      after
        File.rm(temporary)
      end
    end
  end

  @spec remove(String.t(), String.t()) :: :ok | {:error, String.t()}
  def remove(path, allowed_root) do
    with :ok <- validate_path(path, allowed_root),
         :ok <- validate_receipt_node(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, "could not remove metered quota fixture receipt"}
      end
    end
  end

  @spec with_lock(String.t(), String.t(), (-> result)) :: result | {:error, String.t()}
        when result: var
  def with_lock(path, allowed_root, function) when is_function(function, 0) do
    with :ok <- validate_path(path, allowed_root),
         :ok <- ensure_private_parent(path) do
      deadline = System.monotonic_time(:millisecond) + @lock_timeout_ms
      acquire_lock(path <> ".lock", deadline, function)
    end
  end

  defp acquire_lock(lock_path, deadline, function) do
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
          {:error, "metered quota fixture receipt is busy"}
        end

      {:error, _reason} ->
        {:error, "could not lock metered quota fixture receipt"}
    end
  end

  defp validate_path(path, allowed_root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(allowed_root)

    if Path.dirname(expanded_path) == expanded_root do
      :ok
    else
      {:error, "metered quota fixture receipt must be directly inside #{expanded_root}"}
    end
  end

  defp ensure_private_parent(path) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "metered quota fixture parent cannot be a symlink"}

      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o700 do
          :ok
        else
          {:error, "metered quota fixture parent must have mode 0700"}
        end

      {:ok, _stat} ->
        {:error, "metered quota fixture parent must be a directory"}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(parent),
             :ok <- File.chmod(parent, 0o700) do
          :ok
        else
          _failure -> {:error, "could not create metered quota fixture parent"}
        end

      {:error, _reason} ->
        {:error, "could not inspect metered quota fixture parent"}
    end
  end

  defp validate_receipt_node(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "metered quota fixture receipt cannot be a symlink"}

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o777) == 0o600 do
          :ok
        else
          {:error, "metered quota fixture receipt must have mode 0600"}
        end

      {:ok, _stat} ->
        {:error, "metered quota fixture receipt must be a regular file"}

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        {:error, "could not inspect metered quota fixture receipt"}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> {:ok, document}
      _invalid -> {:error, "metered quota fixture receipt is invalid"}
    end
  end

  defp random_suffix do
    6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
