defmodule CodexPooler.Files.CapabilitySpool do
  @moduledoc false

  @directory_prefix "codex-pooler-file-capability-"

  @spec open() :: {:ok, String.t(), IO.device()} | {:error, :unavailable}
  def open, do: open(3)

  defp open(attempts) when attempts > 0 do
    suffix = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    directory = Path.join(System.tmp_dir!(), @directory_prefix <> suffix)
    path = Path.join(directory, "upload")

    case File.mkdir(directory) do
      :ok -> open_in_private_directory(directory, path)
      {:error, :eexist} -> open(attempts - 1)
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception in [File.Error, ArgumentError] -> {:error, :unavailable}
  end

  defp open(0), do: {:error, :unavailable}

  defp open_in_private_directory(directory, path) do
    with :ok <- File.chmod(directory, 0o700),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      case File.chmod(path, 0o600) do
        :ok ->
          {:ok, path, io}

        {:error, _reason} ->
          File.close(io)
          remove_path_and_directory(path)
          {:error, :unavailable}
      end
    else
      _error ->
        remove_path_and_directory(path)
        {:error, :unavailable}
    end
  end

  @spec remove(String.t()) :: :ok
  def remove(path) when is_binary(path) do
    remove_path_and_directory(path)
    :ok
  end

  def remove(_path), do: :ok

  defp remove_path_and_directory(path) do
    directory = Path.dirname(path)

    if String.starts_with?(Path.basename(directory), @directory_prefix) and
         Path.dirname(directory) == Path.expand(System.tmp_dir!()) do
      File.rm(path)
      File.rmdir(directory)
    end

    :ok
  end
end
