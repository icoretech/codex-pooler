defmodule CodexPoolerWeb.Plugs.RuntimeIngress.CompressedBody do
  @moduledoc false

  import Plug.Conn

  alias CodexPooler.Gateway.OperationalSettings
  alias Plug.Conn.Query
  alias Plug.Conn.Utils

  defmodule DecompressionState do
    @moduledoc false

    defstruct offset: 0,
              compressed_size: 0,
              pending: <<>>,
              decompressed_size: 0,
              acc: []
  end

  alias __MODULE__.DecompressionState

  @decompression_chunk_bytes 16_384

  @type error_reason :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t()
        }
  @type read_result ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  @type decode_result ::
          {:ok, Plug.Conn.t()}
          | {:error, error_reason()}
          | {:error, error_reason(), Plug.Conn.t()}
  @type decompression_result :: {:ok, binary()} | {:error, error_reason()}
  @type decompression_task_result :: {:ok, decompression_result()} | {:exit, term()} | nil

  @spec read_plain_json_body(Plug.Conn.t(), keyword()) :: read_result()
  def read_plain_json_body(conn, opts) do
    settings = OperationalSettings.current()

    read_opts =
      opts
      |> Keyword.put(:length, settings.max_decompressed_body_bytes)
      |> Keyword.put(:read_length, settings.max_decompressed_body_bytes)
      |> Keyword.put(:read_timeout, settings.decompression_timeout_ms)

    Plug.Conn.read_body(conn, read_opts)
  end

  @spec decode(Plug.Conn.t(), OperationalSettings.t()) :: decode_result()
  def decode(conn, settings) do
    with {:ok, encoding} <- content_encoding(conn),
         :ok <- supported_encoding?(settings, encoding),
         {:ok, compressed, conn} <- read_compressed_body(conn, settings),
         {:ok, decompressed} <- decompress_with_timeout(compressed, encoding, settings),
         :ok <- validate_decompressed_size(decompressed, settings),
         :ok <- validate_decompression_ratio(compressed, decompressed, settings),
         {:ok, body_params} <- decode_json_body(conn, decompressed) do
      {:ok, put_decoded_body(conn, body_params)}
    else
      :none -> {:ok, conn}
      {:error, _reason} = error -> error
      {:error, _reason, _conn} = error -> error
    end
  end

  @spec content_encoding(Plug.Conn.t()) :: :none | {:ok, String.t()}
  def content_encoding(conn) do
    case get_req_header(conn, "content-encoding") do
      [] -> :none
      [value | _rest] -> {:ok, value |> String.downcase() |> String.trim()}
    end
  end

  @doc false
  @spec normalize_decompression_task_result(decompression_task_result()) ::
          decompression_result()
  def normalize_decompression_task_result({:ok, result}), do: result

  def normalize_decompression_task_result({:exit, _reason}) do
    {:error, invalid_compressed_body_error()}
  end

  def normalize_decompression_task_result(nil) do
    {:error,
     %{
       status: 408,
       code: "request_decompression_timeout",
       message: "request body decompression timed out"
     }}
  end

  defp supported_encoding?(settings, "zstd") do
    if settings.zstd_supported? and "zstd" in settings.decompression_algorithms do
      :ok
    else
      {:error,
       %{
         status: 415,
         code: "unsupported_content_encoding",
         message: "content encoding is not supported"
       }}
    end
  end

  defp supported_encoding?(settings, encoding) do
    if encoding in settings.decompression_algorithms do
      :ok
    else
      {:error,
       %{
         status: 415,
         code: "unsupported_content_encoding",
         message: "content encoding is not supported"
       }}
    end
  end

  defp read_compressed_body(conn, settings) do
    read_compressed_body(conn, settings, [], 0)
  end

  defp read_compressed_body(conn, settings, acc, total_bytes) do
    remaining_bytes = settings.max_compressed_body_bytes - total_bytes

    if remaining_bytes <= 0 do
      compressed_body_too_large(conn)
    else
      read_opts = [
        length: remaining_bytes,
        read_length: min(remaining_bytes, 1_000_000),
        read_timeout: settings.decompression_timeout_ms
      ]

      read_compressed_body_chunk(conn, settings, acc, total_bytes, read_opts)
    end
  end

  defp read_compressed_body_chunk(conn, settings, acc, total_bytes, read_opts) do
    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, body, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([body | acc])), conn}

      {:more, body, conn} ->
        read_compressed_body(conn, settings, [body | acc], total_bytes + byte_size(body))

      {:error, :timeout} ->
        {:error,
         %{
           status: 408,
           code: "request_decompression_timeout",
           message: "request body decompression timed out"
         }, conn}

      {:error, _reason} ->
        {:error,
         %{status: 400, code: "invalid_request", message: "request body could not be read"}, conn}
    end
  end

  defp compressed_body_too_large(conn) do
    {:error,
     %{
       status: 413,
       code: "compressed_request_too_large",
       message: "compressed request body is too large"
     }, conn}
  end

  defp decompress_with_timeout(_compressed, _encoding, %{decompression_timeout_ms: timeout})
       when timeout <= 0 do
    {:error,
     %{
       status: 408,
       code: "request_decompression_timeout",
       message: "request body decompression timed out"
     }}
  end

  defp decompress_with_timeout(compressed, encoding, settings) do
    task = Task.async(fn -> decompress_bounded(compressed, encoding, settings) end)

    task
    |> Task.yield(settings.decompression_timeout_ms)
    |> Kernel.||(Task.shutdown(task, :brutal_kill))
    |> normalize_decompression_task_result()
  end

  defp decompress_bounded(compressed, encoding, settings) when encoding in ["gzip", "deflate"] do
    zstream = :zlib.open()

    try do
      :ok = inflate_init(zstream, encoding)

      case inflate_chunks(zstream, compressed, settings, initial_decompression_state()) do
        {:ok, body} ->
          :ok = :zlib.inflateEnd(zstream)
          {:ok, body}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      _error ->
        {:error, invalid_compressed_body_error()}
    after
      :zlib.close(zstream)
    end
  end

  defp decompress_bounded(compressed, "zstd", settings) do
    case :zstd.context(:decompress) do
      {:ok, zstream} ->
        decompress_zstd_with_context(zstream, compressed, settings)
    end
  rescue
    _error ->
      {:error, invalid_compressed_body_error()}
  catch
    :exit, _reason ->
      {:error, invalid_compressed_body_error()}
  end

  defp decompress_bounded(_compressed, _encoding, _settings) do
    {:error,
     %{
       status: 415,
       code: "unsupported_content_encoding",
       message: "content encoding is not supported"
     }}
  end

  defp decompress_zstd_with_context(zstream, compressed, settings) do
    zstd_stream_chunks(zstream, compressed, settings, initial_decompression_state())
  rescue
    _error ->
      {:error, invalid_compressed_body_error()}
  catch
    :exit, _reason ->
      {:error, invalid_compressed_body_error()}
  after
    :zstd.close(zstream)
  end

  defp zstd_stream_chunks(
         zstream,
         compressed,
         settings,
         %DecompressionState{offset: offset, pending: <<>>} = state
       )
       when offset >= byte_size(compressed) do
    case :zstd.finish(zstream, <<>>) do
      {:done, output} ->
        zstd_finish_result(settings, state, output)
    end
  end

  defp zstd_stream_chunks(
         zstream,
         compressed,
         settings,
         %DecompressionState{} = state
       ) do
    {chunk, state} = zstd_next_chunk(compressed, state)

    case :zstd.stream(zstream, chunk) do
      {:continue, remainder, output} ->
        zstd_stream_result(
          zstream,
          compressed,
          settings,
          %DecompressionState{state | pending: IO.iodata_to_binary([remainder, state.pending])},
          output
        )

      {:continue, output} ->
        zstd_stream_result(
          zstream,
          compressed,
          settings,
          state,
          output
        )
    end
  end

  defp zstd_next_chunk(
         _compressed,
         %DecompressionState{
           offset: offset,
           compressed_size: compressed_size,
           pending: pending
         } = state
       )
       when byte_size(pending) > 0 do
    chunk_size = min(@decompression_chunk_bytes, byte_size(pending))
    <<chunk::binary-size(chunk_size), rest::binary>> = pending

    {chunk,
     %DecompressionState{state | offset: offset, compressed_size: compressed_size, pending: rest}}
  end

  defp zstd_next_chunk(
         compressed,
         %DecompressionState{offset: offset, compressed_size: compressed_size} =
           state
       ) do
    chunk_size = min(@decompression_chunk_bytes, byte_size(compressed) - offset)
    chunk = binary_part(compressed, offset, chunk_size)

    {chunk,
     %DecompressionState{
       state
       | offset: offset + chunk_size,
         compressed_size: compressed_size + chunk_size
     }}
  end

  defp zstd_stream_result(
         zstream,
         compressed,
         settings,
         %DecompressionState{} = state,
         output
       ) do
    output_size = IO.iodata_length(output)
    decompressed_size = state.decompressed_size + output_size

    with :ok <- validate_decompressed_size(decompressed_size, settings),
         :ok <- validate_decompression_ratio(state.compressed_size, decompressed_size, settings) do
      zstd_stream_chunks(
        zstream,
        compressed,
        settings,
        %DecompressionState{
          state
          | decompressed_size: decompressed_size,
            acc: [output | state.acc]
        }
      )
    end
  end

  defp zstd_finish_result(settings, %DecompressionState{} = state, output) do
    output_size = IO.iodata_length(output)
    decompressed_size = state.decompressed_size + output_size

    with :ok <- validate_decompressed_size(decompressed_size, settings),
         :ok <- validate_decompression_ratio(state.compressed_size, decompressed_size, settings) do
      {:ok, IO.iodata_to_binary(Enum.reverse([output | state.acc]))}
    end
  end

  defp inflate_init(zstream, "gzip"), do: :zlib.inflateInit(zstream, 16 + 15)
  defp inflate_init(zstream, "deflate"), do: :zlib.inflateInit(zstream)

  defp inflate_chunks(
         _zstream,
         compressed,
         _settings,
         %DecompressionState{offset: offset} = state
       )
       when offset >= byte_size(compressed) do
    {:ok, IO.iodata_to_binary(Enum.reverse(state.acc))}
  end

  defp inflate_chunks(zstream, compressed, settings, %DecompressionState{} = state) do
    chunk_size = min(@decompression_chunk_bytes, byte_size(compressed) - state.offset)
    chunk = binary_part(compressed, state.offset, chunk_size)
    compressed_size = state.offset + chunk_size

    state = %DecompressionState{
      state
      | offset: compressed_size,
        compressed_size: compressed_size
    }

    case inflate_chunk_outputs(zstream, chunk, settings, state) do
      {:ok, state} -> inflate_chunks(zstream, compressed, settings, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp inflate_chunk_outputs(zstream, input, settings, %DecompressionState{} = state) do
    case :zlib.safeInflate(zstream, input) do
      {:continue, output} ->
        continue_inflate_chunk_outputs(
          zstream,
          settings,
          append_inflate_output(output, settings, state)
        )

      {:finished, output} ->
        append_inflate_output(output, settings, state)
    end
  end

  defp continue_inflate_chunk_outputs(zstream, settings, {:ok, state}) do
    case state.acc do
      [latest_output | _rest] when latest_output in [[], ""] ->
        {:ok, state}

      _non_empty_output ->
        inflate_chunk_outputs(zstream, <<>>, settings, state)
    end
  end

  defp continue_inflate_chunk_outputs(_zstream, _settings, {:error, reason}), do: {:error, reason}

  defp append_inflate_output(output, settings, %DecompressionState{} = state) do
    output_size = IO.iodata_length(output)
    decompressed_size = state.decompressed_size + output_size

    with :ok <- validate_decompressed_size(decompressed_size, settings),
         :ok <- validate_decompression_ratio(state.compressed_size, decompressed_size, settings) do
      {:ok,
       %DecompressionState{
         state
         | decompressed_size: decompressed_size,
           acc: [output | state.acc]
       }}
    end
  end

  defp initial_decompression_state, do: %DecompressionState{}

  defp validate_decompressed_size(body_or_size, settings) do
    size = if is_integer(body_or_size), do: body_or_size, else: byte_size(body_or_size)

    if size <= settings.max_decompressed_body_bytes do
      :ok
    else
      {:error,
       %{
         status: 413,
         code: "decompressed_request_too_large",
         message: "decompressed request body is too large"
       }}
    end
  end

  defp validate_decompression_ratio(compressed_or_size, decompressed_or_size, settings) do
    compressed_size =
      if is_integer(compressed_or_size),
        do: compressed_or_size,
        else: byte_size(compressed_or_size)

    decompressed_size =
      if is_integer(decompressed_or_size),
        do: decompressed_or_size,
        else: byte_size(decompressed_or_size)

    allowed = max(compressed_size, 1) * settings.max_decompression_ratio

    if decompressed_size <= allowed do
      :ok
    else
      {:error,
       %{
         status: 413,
         code: "decompression_ratio_exceeded",
         message: "request body compression ratio is too large"
       }}
    end
  end

  defp invalid_compressed_body_error do
    %{status: 400, code: "invalid_request", message: "compressed request body is invalid"}
  end

  defp decode_json_body(conn, body) do
    case content_type(conn) do
      {:json, _content_type} ->
        case Jason.decode(body) do
          {:ok, params} when is_map(params) ->
            {:ok, params}

          {:ok, _params} ->
            {:error,
             %{
               status: 400,
               code: "invalid_request",
               message: "request body must be a JSON object"
             }}

          {:error, _reason} ->
            {:error,
             %{status: 400, code: "invalid_request", message: "request body must be JSON"}}
        end

      {:other, content_type} ->
        {:error,
         %{
           status: 415,
           code: "unsupported_media_type",
           message: "compressed #{content_type} request bodies are not supported"
         }}
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _rest] ->
        classify_content_type(content_type)

      [] ->
        {:other, "unknown"}
    end
  end

  defp classify_content_type(content_type) do
    case Utils.content_type(content_type) do
      {:ok, "application", subtype, _params} -> json_content_type(subtype, content_type)
      _other -> {:other, content_type}
    end
  end

  defp json_content_type(subtype, content_type) do
    if subtype == "json" or String.ends_with?(subtype, "+json") do
      {:json, content_type}
    else
      {:other, content_type}
    end
  end

  defp put_decoded_body(conn, body_params) do
    query_params = Query.decode(conn.query_string)
    path_params = make_empty_if_unfetched(conn.path_params)
    existing_params = make_empty_if_unfetched(conn.params)

    params =
      query_params
      |> Map.merge(existing_params)
      |> Map.merge(body_params)
      |> Map.merge(path_params)

    %{conn | body_params: body_params, params: params, query_params: query_params}
  end

  defp make_empty_if_unfetched(%Plug.Conn.Unfetched{}), do: %{}
  defp make_empty_if_unfetched(params), do: params
end
