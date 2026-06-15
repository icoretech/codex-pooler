defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks do
  @moduledoc false

  @supported_encodings [:cl100k_base, :o200k_base]

  @type encoding :: :cl100k_base | :o200k_base
  @type ranks :: %{required(binary()) => non_neg_integer()}
  @type error_reason :: :unsupported_encoding | :rank_file_unavailable | :invalid_rank_file

  @spec load(encoding()) :: {:ok, ranks()} | {:error, error_reason()}
  def load(encoding) when encoding in @supported_encodings do
    key = {__MODULE__, :ranks, encoding}

    case :persistent_term.get(key, :not_found) do
      :not_found -> load_uncached(key, encoding)
      ranks -> {:ok, ranks}
    end
  end

  def load(_encoding), do: {:error, :unsupported_encoding}

  @spec supported_encodings() :: [encoding()]
  def supported_encodings, do: @supported_encodings

  defp load_uncached(key, encoding) do
    with {:ok, path} <- rank_file_path(encoding),
         {:ok, raw} <- File.read(path),
         {:ok, ranks} <- parse(raw) do
      :persistent_term.put(key, ranks)
      {:ok, ranks}
    end
  end

  defp rank_file_path(encoding) do
    with {:ok, priv_dir} <- priv_dir() do
      path = Path.join([priv_dir, "tokenizers", "ranks", "#{encoding}.tiktoken"])

      if File.regular?(path) do
        {:ok, path}
      else
        {:error, :rank_file_unavailable}
      end
    end
  end

  defp priv_dir do
    case :code.priv_dir(:codex_pooler) do
      path when is_list(path) -> {:ok, List.to_string(path)}
      {:error, _reason} -> {:error, :rank_file_unavailable}
    end
  end

  defp parse(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, acc} ->
      case parse_line(line) do
        {:ok, token, rank} -> {:cont, {:ok, Map.put(acc, token, rank)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_line(line) do
    with [encoded_token, rank_string] <- String.split(line, " ", parts: 2),
         {:ok, token} <- Base.decode64(encoded_token),
         {rank, ""} <- Integer.parse(rank_string) do
      {:ok, token, rank}
    else
      _error -> {:error, :invalid_rank_file}
    end
  end
end
