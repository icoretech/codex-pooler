defmodule CodexPooler.Dev.UpstreamAccountBundle.PrivateFile do
  @moduledoc false

  import Bitwise

  @spec write(String.t(), binary()) :: {:ok, String.t()} | {:error, String.t()}
  def write(path, bundle) when is_binary(path) and is_binary(bundle) do
    with :ok <- private_parent_directory(path) do
      write_exclusive_private_file(path, bundle)
    end
  end

  @spec read(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read(path) when is_binary(path) do
    with :ok <- private_parent_directory(path),
         {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and permission_mode(stat) == 0o600,
         {:ok, bundle} <- File.read(path) do
      {:ok, bundle}
    else
      _invalid ->
        {:error, "bundle input must be a regular 0600 file in a private 0700 directory"}
    end
  end

  defp write_exclusive_private_file(path, bundle) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, io} -> write_open_bundle(io, path, bundle)
      {:error, :eexist} -> {:error, "bundle output already exists"}
      {:error, _reason} -> {:error, "bundle output could not be written"}
    end
  end

  defp write_open_bundle(io, path, bundle) do
    result =
      with :ok <- :file.change_mode(String.to_charlist(path), 0o600),
           {:ok, stat} <- File.lstat(path),
           true <- stat.type == :regular and permission_mode(stat) == 0o600,
           :ok <- :file.write(io, bundle),
           :ok <- :file.sync(io) do
        {:ok, "0600"}
      else
        _reason -> {:error, "bundle output could not be written"}
      end

    close_result = :file.close(io)

    case {result, close_result} do
      {{:ok, mode}, :ok} ->
        {:ok, mode}

      _failure ->
        _removed = File.rm(path)
        {:error, "bundle output could not be written"}
    end
  end

  defp private_parent_directory(path) do
    with {:ok, stat} <- File.lstat(Path.dirname(path)),
         true <- stat.type == :directory and permission_mode(stat) == 0o700 do
      :ok
    else
      _invalid -> {:error, "bundle output parent directory must be private mode 0700"}
    end
  end

  defp permission_mode(stat), do: stat.mode &&& 0o777
end
