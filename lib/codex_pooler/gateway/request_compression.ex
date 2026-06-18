defmodule CodexPooler.Gateway.RequestCompression do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression.Eligibility
  alias CodexPooler.Gateway.RequestCompression.JsonStringRanges
  alias CodexPooler.Gateway.RequestCompression.Metadata
  alias CodexPooler.Gateway.RequestCompression.ResponsesLiveZone
  alias CodexPooler.Gateway.RequestCompression.Strategies
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @strategy_modules %{
    diff: Strategies.Diff,
    json_array_lossless: Strategies.JsonArrayLossless,
    json_document_lossless: Strategies.JsonDocumentLossless,
    log_output: Strategies.LogOutput,
    search_results: Strategies.SearchResults
  }

  # Compression is opportunistic: bodies above 1 MiB skip before JSON scanning.
  @max_body_bytes 1_048_576
  # At most 50 planned output candidates are processed for one dispatch.
  @max_candidate_count 50
  @max_candidate_tokenization_bytes 8_192

  @type upstream_payload :: binary() | {:multipart, list()} | term()

  @spec maybe_compress(upstream_payload(), term(), RequestOptions.t()) ::
          {upstream_payload(), RequestOptions.t()}
  def maybe_compress(upstream_payload, context, %RequestOptions{} = request_options) do
    started = System.monotonic_time(:millisecond)

    try do
      case Eligibility.check(upstream_payload, context, request_options) do
        {:eligible, metadata} ->
          if over_body_limit?(upstream_payload) do
            skip_over_limit(
              upstream_payload,
              request_options,
              metadata,
              :over_body_limit,
              0,
              0,
              started
            )
          else
            compress_payload(upstream_payload, context, request_options, metadata, started)
          end

        {:skip, reason, metadata} ->
          {upstream_payload,
           put_compression_metadata(
             request_options,
             skipped_metadata(metadata),
             skip_status(reason),
             reason,
             started
           )}
      end
    rescue
      error ->
        fail_open(
          upstream_payload,
          request_options,
          context,
          classify_exception(error),
          error,
          started
        )
    catch
      kind, reason ->
        fail_open(
          upstream_payload,
          request_options,
          context,
          :compression_error,
          {kind, reason},
          started
        )
    end
  end

  def maybe_compress(upstream_payload, _context, request_options) do
    {upstream_payload, request_options}
  end

  defp compress_payload(upstream_payload, context, request_options, metadata, started)
       when is_binary(upstream_payload) do
    with {:ok, opts} <- strategy_opts(context, request_options),
         {:ok, candidates} <- ResponsesLiveZone.plan_candidates(upstream_payload) do
      maybe_rewrite_candidates(
        upstream_payload,
        candidates,
        opts,
        context,
        request_options,
        metadata,
        started
      )
    else
      {:error, :tokenizer_unavailable} ->
        skip_tokenizer_unavailable(upstream_payload, request_options, metadata, started)

      {:error, :invalid_json} ->
        fail_open(
          upstream_payload,
          request_options,
          context,
          :invalid_json,
          :invalid_json,
          started
        )
    end
  end

  defp compress_payload(upstream_payload, _context, request_options, metadata, started) do
    {upstream_payload,
     put_compression_metadata(
       request_options,
       metadata,
       :skipped,
       :payload_kind_ineligible,
       started
     )}
  end

  defp over_body_limit?(payload) when is_binary(payload), do: byte_size(payload) > @max_body_bytes
  defp over_body_limit?(_payload), do: false

  defp skip_over_limit(
         upstream_payload,
         request_options,
         metadata,
         reason,
         candidate_count,
         skipped_count,
         started
       ) do
    metadata =
      Map.merge(metadata, %{
        candidate_count: candidate_count,
        compressed_count: 0,
        skipped_count: skipped_count
      })

    {upstream_payload,
     put_compression_metadata(request_options, metadata, :skipped, reason, started)}
  end

  defp maybe_rewrite_candidates(
         upstream_payload,
         candidates,
         opts,
         context,
         request_options,
         metadata,
         started
       ) do
    candidate_count = length(candidates)

    if candidate_count > @max_candidate_count do
      skip_over_limit(
        upstream_payload,
        request_options,
        metadata,
        :over_candidate_limit,
        candidate_count,
        candidate_count,
        started
      )
    else
      rewrite_candidates(
        upstream_payload,
        candidates,
        opts,
        context,
        request_options,
        metadata,
        started
      )
    end
  end

  defp rewrite_candidates(
         upstream_payload,
         candidates,
         opts,
         context,
         request_options,
         metadata,
         started
       ) do
    case candidate_replacements(upstream_payload, candidates, opts) do
      {:ok, [], strategy_metadata, skip_reasons} ->
        no_rewrite(
          upstream_payload,
          request_options,
          metadata,
          candidates,
          strategy_metadata,
          skip_reasons,
          started
        )

      {:ok, replacements, strategy_metadata, skip_reasons} ->
        case JsonStringRanges.replace_ranges(upstream_payload, replacements) do
          {:ok, compressed_payload} ->
            metadata =
              compressed_metadata(
                metadata,
                upstream_payload,
                compressed_payload,
                candidates,
                strategy_metadata,
                skip_reasons
              )

            {compressed_payload,
             put_compression_metadata(request_options, metadata, :compressed, :rewritten, started)}

          {:error, :invalid_range} ->
            fail_open(
              upstream_payload,
              request_options,
              context,
              :scanner_error,
              :invalid_range,
              started
            )
        end

      {:error, reason} ->
        fail_open(upstream_payload, request_options, context, reason, reason, started)
    end
  end

  defp candidate_replacements(upstream_payload, candidates, opts) do
    Enum.reduce_while(candidates, {:ok, [], [], %{}}, fn candidate,
                                                         {:ok, replacements, metadata,
                                                          skip_reasons} ->
      case candidate_replacement(upstream_payload, candidate, opts) do
        {:ok, replacement, strategy_metadata} ->
          {:cont,
           {:ok, [replacement | replacements], [strategy_metadata | metadata], skip_reasons}}

        {:skip, reason} when is_atom(reason) ->
          skip_reasons = increment_skip_reason(skip_reasons, reason)
          {:cont, {:ok, replacements, metadata, skip_reasons}}

        :skip ->
          {:cont, {:ok, replacements, metadata, skip_reasons}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp candidate_replacement(
         upstream_payload,
         %{compressible: true, strategy: strategy} = candidate,
         opts
       ) do
    with :ok <- candidate_tokenization_input_within_limit(candidate),
         {:ok, module} <- strategy_module(strategy),
         {:ok, output} <-
           JsonStringRanges.decode_string(upstream_payload, Map.from_struct(candidate)),
         {:ok, compressed_content, strategy_metadata} <-
           compress_with_strategy(module, output, opts) do
      replacement = %{
        byte_start: candidate.byte_start,
        byte_end: candidate.byte_end,
        replacement: Jason.encode!(compressed_content)
      }

      {:ok, replacement, strategy_metadata}
    else
      {:skip, reason} when is_atom(reason) -> {:skip, reason}
      :skip -> :skip
      {:error, :invalid_json} -> {:error, :scanner_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_replacement(_upstream_payload, _candidate, _opts), do: :skip

  defp candidate_tokenization_input_within_limit(%{output_byte_size: output_byte_size})
       when is_integer(output_byte_size) and output_byte_size > @max_candidate_tokenization_bytes do
    {:skip, :tokenizer_input_limit}
  end

  defp candidate_tokenization_input_within_limit(_candidate), do: :ok

  defp strategy_module(strategy) when is_atom(strategy) do
    case Map.fetch(@strategy_modules, strategy) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :strategy_unavailable}
    end
  end

  defp strategy_module(_strategy), do: {:error, :strategy_unavailable}

  defp compress_with_strategy(module, output, opts) do
    case module.compress(output, opts) do
      {:ok, %{content: compressed_content, metadata: metadata}}
      when is_binary(compressed_content) and is_map(metadata) ->
        {:ok, compressed_content, metadata}

      :skip ->
        :skip

      {:skip, reason} when is_atom(reason) ->
        {:skip, reason}

      _other ->
        {:error, :compression_error}
    end
  end

  defp no_rewrite(
         upstream_payload,
         request_options,
         metadata,
         candidates,
         strategy_metadata,
         skip_reasons,
         started
       ) do
    reason = no_rewrite_reason(candidates, skip_reasons)
    status = no_rewrite_status(reason)

    metadata =
      metadata
      |> Map.merge(%{
        candidate_count: length(candidates),
        compressed_count: 0,
        skipped_count: length(candidates),
        original_bytes: byte_size(upstream_payload),
        compressed_bytes: byte_size(upstream_payload)
      })
      |> put_skip_summary(skip_reasons)
      |> put_strategy_summary(strategy_metadata)

    {upstream_payload,
     put_compression_metadata(request_options, metadata, status, reason, started)}
  end

  defp compressed_metadata(
         metadata,
         upstream_payload,
         compressed_payload,
         candidates,
         strategy_metadata,
         skip_reasons
       ) do
    metadata
    |> Map.merge(%{
      candidate_count: length(candidates),
      compressed_count: length(strategy_metadata),
      skipped_count: length(candidates) - length(strategy_metadata),
      original_bytes: byte_size(upstream_payload),
      compressed_bytes: byte_size(compressed_payload)
    })
    |> put_skip_summary(skip_reasons)
    |> put_token_counts(strategy_metadata)
    |> put_strategy_summary(strategy_metadata)
  end

  defp increment_skip_reason(skip_reasons, :tokenizer_input_limit) do
    Map.update(skip_reasons, :tokenizer_input_limit, 1, &(&1 + 1))
  end

  defp increment_skip_reason(skip_reasons, _reason), do: skip_reasons

  defp no_rewrite_reason([], _skip_reasons), do: :no_candidates

  defp no_rewrite_reason(candidates, skip_reasons) do
    if Map.get(skip_reasons, :tokenizer_input_limit, 0) == length(candidates) do
      :tokenizer_input_limit
    else
      :no_rewrites
    end
  end

  defp no_rewrite_status(:tokenizer_input_limit), do: :skipped
  defp no_rewrite_status(_reason), do: :no_change

  defp put_skip_summary(metadata, skip_reasons) do
    case Map.get(skip_reasons, :tokenizer_input_limit, 0) do
      count when is_integer(count) and count > 0 ->
        Map.put(metadata, :tokenizer_input_skipped_count, count)

      _count ->
        metadata
    end
  end

  defp put_token_counts(metadata, strategy_metadata) do
    original_tokens = sum_metadata(strategy_metadata, :original_tokens)
    compressed_tokens = sum_metadata(strategy_metadata, :compressed_tokens)

    metadata
    |> maybe_put_positive_count(:original_tokens, original_tokens)
    |> maybe_put_positive_count(:compressed_tokens, compressed_tokens)
  end

  defp put_strategy_summary(metadata, strategy_metadata) do
    strategies =
      strategy_metadata
      |> Enum.map(&metadata_value(&1, :strategy))
      |> Enum.map(&Metadata.strategy_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    metadata =
      case strategies do
        [] -> metadata
        strategies -> Map.put(metadata, :strategies, strategies)
      end

    case tokenizer(strategy_metadata) do
      nil -> metadata
      tokenizer -> Map.put(metadata, :tokenizer, tokenizer)
    end
  end

  defp sum_metadata(metadata, key) do
    Enum.reduce(metadata, 0, fn item, total ->
      case metadata_value(item, key) do
        value when is_integer(value) and value >= 0 -> total + value
        _value -> total
      end
    end)
  end

  defp maybe_put_positive_count(metadata, _key, 0), do: metadata
  defp maybe_put_positive_count(metadata, key, value), do: Map.put(metadata, key, value)

  defp tokenizer(strategy_metadata) do
    Enum.find_value(strategy_metadata, fn item ->
      case metadata_value(item, :tokenizer) do
        value when is_binary(value) -> value
        _value -> nil
      end
    end)
  end

  defp strategy_opts(context, request_options) do
    case supported_model(context, request_options) do
      nil -> {:error, :tokenizer_unavailable}
      model -> {:ok, [model: model]}
    end
  end

  defp supported_model(context, request_options) do
    context
    |> model_candidates(request_options)
    |> Enum.find(&token_counter_model?/1)
  end

  defp model_candidates(context, request_options) do
    model = field(context, :model)
    visible_model = context |> field(:route_state) |> field(:visible_model)
    routing = field(request_options, :routing)

    [
      field(model, :upstream_model_id),
      field(model, :exposed_model_id),
      field(visible_model, :upstream_model_id),
      field(visible_model, :exposed_model_id),
      field(routing, :effective_model),
      field(routing, :requested_model)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp token_counter_model?(model) when is_binary(model) do
    match?({:ok, _encoding}, TokenCounter.encoding_for_model(model))
  end

  defp token_counter_model?(_model), do: false

  defp skip_tokenizer_unavailable(upstream_payload, request_options, metadata, started)
       when is_binary(upstream_payload) do
    bytes = byte_size(upstream_payload)

    metadata =
      Map.merge(metadata, %{
        candidate_count: 0,
        compressed_count: 0,
        skipped_count: 0,
        original_bytes: bytes,
        compressed_bytes: bytes
      })

    {upstream_payload,
     put_compression_metadata(
       request_options,
       metadata,
       :skipped,
       :tokenizer_unavailable,
       started
     )}
  end

  defp fail_open(upstream_payload, request_options, context, reason, error, started) do
    metadata =
      upstream_payload
      |> safe_failure_metadata(context, request_options)
      |> Map.merge(%{
        enabled: failure_enabled?(context),
        candidate_count: 0,
        compressed_count: 0,
        skipped_count: 0
      })

    log_fail_open(reason, error, metadata)

    {upstream_payload,
     put_compression_metadata(
       request_options,
       metadata,
       :error_passthrough,
       reason,
       started
     )}
  end

  defp put_compression_metadata(request_options, metadata, status, reason, started) do
    metadata = Metadata.put_writer_fields(metadata, status, reason, elapsed_ms(started))

    RequestOptions.put_runtime_context(request_options, payload_compression: metadata)
  end

  defp skipped_metadata(metadata) do
    Map.merge(metadata, %{
      candidate_count: 0,
      compressed_count: 0,
      skipped_count: 0
    })
  end

  defp skip_status(:pool_disabled), do: :disabled
  defp skip_status(_reason), do: :ineligible

  defp classify_exception(%Jason.DecodeError{}), do: :invalid_json
  defp classify_exception(_error), do: :compression_error

  defp safe_failure_metadata(upstream_payload, context, %RequestOptions{} = request_options) do
    bytes = payload_bytes(upstream_payload)

    %{
      route_class: field(context, :route_class) || field(request_options.transport, :route_class),
      transport: field(request_options.transport, :transport),
      original_bytes: bytes,
      compressed_bytes: bytes
    }
  end

  defp payload_bytes(payload) when is_binary(payload), do: byte_size(payload)
  defp payload_bytes(_payload), do: nil

  defp failure_enabled?(context) do
    context
    |> field(:route_state)
    |> field(:routing_settings)
    |> field(:request_compression_enabled)
    |> Kernel.==(true)
  end

  defp log_fail_open(reason, error, metadata) do
    Logger.warning(
      "request compression failed open",
      request_compression_reason: Atom.to_string(reason),
      request_compression_exception: exception_class(error),
      request_compression_route_class: metadata.route_class,
      request_compression_transport: metadata.transport
    )
  end

  defp exception_class(%module{}) when is_atom(module), do: inspect(module)
  defp exception_class({kind, _reason}) when is_atom(kind), do: Atom.to_string(kind)
  defp exception_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp exception_class(_error), do: "unknown"

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp field(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, value} -> value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp metadata_value(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, value} -> value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp metadata_value(_value, _key), do: nil
end
