defmodule CodexPooler.Accounting.PricingResolution do
  @moduledoc false

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.PricingResolution.{ContextRule, Costing, Generations}
  alias CodexPooler.Catalog.{Model, PricingSnapshot}
  alias CodexPooler.Repo
  alias CodexPooler.ServiceTier

  @default_price_bucket "default"
  @unavailable_pricing_availability "unavailable"

  @typep suffix_candidate :: %{
           from: String.t(),
           to: String.t(),
           distance: pos_integer()
         }

  @spec lookup(Model.t(), String.t(), map(), map(), DateTime.t()) :: map()
  def lookup(%Model{} = model, requested_model, payload, opts, timestamp) do
    requested_tier = requested_service_tier(payload, opts)
    actual_tier = actual_service_tier(%{}, opts)
    batch_usage? = explicit_batch_usage?(payload, opts)

    input_tokens =
      case attr(opts, :reservation_estimate) do
        %{input_tokens: input_tokens} when is_integer(input_tokens) ->
          input_tokens

        _estimate ->
          Costing.estimate_input_tokens(payload, %{source_endpoint: attr(opts, :endpoint) || "/backend-api/codex/responses"})
      end

    lookup_for_tier(
      pricing_identifiers(model, requested_model, attr(opts, :endpoint)),
      requested_tier,
      actual_tier,
      input_tokens,
      timestamp,
      batch_usage?
    )
  end

  @spec lookup_for_settlement(
          Request.t(),
          Attempt.t(),
          LedgerEntry.t(),
          map(),
          map(),
          DateTime.t()
        ) ::
          map()
  def lookup_for_settlement(
        %Request{} = request,
        %Attempt{} = attempt,
        %LedgerEntry{} = reservation,
        usage,
        attrs,
        timestamp
      ) do
    maybe_test_settlement_fault(request)
    model = request.model_id && Repo.get(Model, request.model_id)

    if model do
      requested_tier =
        reservation
        |> details_value("requested_service_tier")
        |> fallback(request |> metadata_pricing_value("requested_service_tier"))

      actual_tier =
        actual_service_tier(usage, attrs) ||
          metadata_service_tier(attempt.response_metadata) ||
          request |> metadata_pricing_value("actual_service_tier")

      pricing_identifiers(model, request.requested_model, request.endpoint)
      |> lookup_for_tier(
        requested_tier,
        actual_tier,
        usage.input_tokens,
        timestamp,
        details_value(reservation, "batch_usage") == true
      )
      |> require_cache_write_rate(usage)
      |> require_cached_input_rate(usage)
    else
      unpriced_snapshot("unpriced_missing_model", nil, nil, nil, false)
    end
  end

  @spec latest_snapshot_for_request(Request.t(), Model.t() | nil) :: struct() | nil
  def latest_snapshot_for_request(%Request{} = request, %Model{} = model) do
    request
    |> lookup_for_request_metadata(model, now())
    |> Map.get(:snapshot)
  end

  def latest_snapshot_for_request(%Request{}, nil), do: nil

  @spec reservation_estimate(map(), struct() | nil, term(), map() | nil, CodexPooler.Accounting.PricingResolution.InputEstimate.context()) :: {:ok, map()}
  defdelegate reservation_estimate(payload, snapshot, policy, precomputed \\ nil, context \\ %{}), to: Costing

  @spec cost_micros(struct() | nil, map()) :: Decimal.t() | nil
  defdelegate cost_micros(snapshot, usage), to: Costing

  @spec metadata(map()) :: map()
  def metadata(pricing) do
    snapshot = pricing.snapshot

    pricing_metadata = %{
      "status" => pricing.status,
      "requested_service_tier" => pricing.requested_service_tier,
      "actual_service_tier" => pricing.actual_service_tier,
      "service_tier" => pricing.service_tier,
      "price_bucket" => pricing.price_bucket,
      "pricing_type" => pricing.pricing_type,
      "batch_usage" => pricing.batch_usage,
      "snapshot" =>
        if(snapshot,
          do: %{
            "id" => snapshot.id,
            "model_identifier" => snapshot.model_identifier,
            "price_version" => snapshot.price_version
          },
          else: nil
        )
    }

    pricing_metadata
    |> put_serialized_alias_metadata(Map.get(pricing, :alias))
    |> put_serialized_price_bucket_fallback(Map.get(pricing, :price_bucket_fallback))
    |> put_serialized_context_pricing(Map.get(pricing, :context_pricing))
  end

  @spec details(map()) :: map()
  def details(pricing) do
    snapshot = pricing.snapshot

    details = %{
      "pricing_status" => pricing.status,
      "requested_service_tier" => pricing.requested_service_tier,
      "actual_service_tier" => pricing.actual_service_tier,
      "service_tier" => pricing.service_tier,
      "price_bucket" => pricing.price_bucket,
      "pricing_type" => pricing.pricing_type,
      "batch_usage" => pricing.batch_usage,
      "price_version" => snapshot && snapshot.price_version
    }

    details
    |> put_serialized_alias_metadata(Map.get(pricing, :alias))
    |> put_serialized_price_bucket_fallback(Map.get(pricing, :price_bucket_fallback))
    |> put_serialized_context_pricing(Map.get(pricing, :context_pricing))
  end

  @spec update_request_metadata(map() | nil, map()) :: map()
  def update_request_metadata(metadata, pricing) do
    Map.put(metadata || %{}, "pricing", metadata(pricing))
  end

  @spec request_settings_snapshot(map(), map(), map()) :: map()
  def request_settings_snapshot(payload, request_metadata, pricing) do
    requested_tier = requested_service_tier_snapshot(payload, request_metadata, pricing)
    actual_tier = actual_service_tier_snapshot(request_metadata, pricing)

    effective_tier =
      effective_service_tier_snapshot(requested_tier, actual_tier, request_metadata, pricing)

    %{
      reasoning_effort: payload_reasoning_effort(payload) |> normalize_snapshot_value(),
      requested_service_tier: ServiceTier.canonicalize(requested_tier),
      actual_service_tier: ServiceTier.canonicalize(actual_tier),
      service_tier: ServiceTier.canonicalize(effective_tier)
    }
  end

  defp lookup_for_request_metadata(%Request{} = request, %Model{} = model, timestamp) do
    requested_tier = metadata_pricing_value(request, "requested_service_tier")
    actual_tier = metadata_pricing_value(request, "actual_service_tier")

    lookup_for_tier(
      pricing_identifiers(model, request.requested_model, request.endpoint),
      requested_tier,
      actual_tier,
      {:bucket, metadata_pricing_value(request, "price_bucket") || @default_price_bucket},
      timestamp,
      metadata_pricing_value(request, "batch_usage") == true
    )
  end

  defp lookup_for_tier(
         identifiers,
         requested_tier,
         actual_tier,
         input,
         timestamp,
         batch_usage?
       ) do
    requested_tier = ServiceTier.canonicalize(requested_tier)
    actual_tier = ServiceTier.canonicalize(actual_tier)

    case priceable_service_tier(requested_tier, actual_tier, batch_usage?) do
      {:ok, service_tier} ->
        lookup_for_service_tier(
          identifiers,
          requested_tier,
          actual_tier,
          service_tier,
          input,
          timestamp,
          batch_usage?
        )

      {:unpriced, status} ->
        service_tier = if normalize_service_tier(requested_tier) == "batch", do: "batch"
        unpriced_snapshot(status, requested_tier, actual_tier, service_tier, batch_usage?)
    end
  end

  defp lookup_for_service_tier(identifiers, requested_tier, actual_tier, service_tier, input, timestamp, batch_usage?) do
    suffixes = suffix_inference_candidates(identifiers)
    candidates = normalize_pricing_identifiers(identifiers ++ Enum.map(suffixes, & &1.to))
    families = Generations.load(candidates, service_tier, timestamp)

    context = %{
      identifiers: identifiers,
      requested_tier: requested_tier,
      actual_tier: actual_tier,
      service_tier: service_tier,
      batch_usage: batch_usage?,
      families: families
    }

    classified =
      Map.new(families, fn {identifier, family} ->
        {identifier, if(family.anchor, do: ContextRule.classify(family, input))}
      end)

    exact = Enum.map(identifiers, &classified[normalize_pricing_identifier(&1)])
    suffix = Enum.map(suffixes, &Map.put(&1, :candidate, classified[normalize_pricing_identifier(&1.to)]))

    exact_primary(context, exact) ||
      exact_fallback(context, exact) ||
      suffix_outcome(context, suffix, :primary) ||
      suffix_outcome(context, suffix, :unavailable) ||
      suffix_outcome(context, suffix, :fallback) ||
      missing_pricing_snapshot(context)
  end

  # Identifier precedence is settled before availability. Only missing primary
  # buckets may offer a fallback while a lower exact primary takes precedence.
  defp exact_primary(context, candidates) do
    case Enum.find(candidates, &primary?/1) do
      nil -> nil
      candidate -> candidate_pricing(context, candidate, candidate.primary)
    end
  end

  defp primary?(nil), do: false
  defp primary?(%{rule: %{"status" => status}}) when status in ["unknown", "invalid"], do: true
  defp primary?(candidate), do: not is_nil(candidate.primary)

  defp exact_fallback(context, candidates) do
    case Enum.find(candidates, &fallback?/1) do
      nil ->
        nil

      candidate ->
        if priced_pricing_snapshot?(candidate.fallback),
          do: candidate_pricing(context, candidate, candidate.fallback)
    end
  end

  defp fallback?(nil), do: false
  defp fallback?(candidate), do: is_nil(candidate.primary) and not is_nil(candidate.fallback)

  # Preserve priced/terminal, unavailable, then fallback suffix categories.
  # Ambiguity is evaluated independently at each category's nearest distance.
  defp suffix_outcome(context, suffixes, category) do
    matches = Enum.filter(suffixes, &suffix_category?(&1.candidate, category))

    case matches do
      [] ->
        nil

      _matches ->
        distance = matches |> Enum.map(& &1.distance) |> Enum.min()
        nearest = Enum.filter(matches, &(&1.distance == distance))

        resolve_nearest_suffix(context, Enum.uniq_by(nearest, &normalize_pricing_identifier(&1.to)), category)
    end
  end

  defp resolve_nearest_suffix(context, [match], category) do
    snapshot = if category == :fallback, do: match.candidate.fallback, else: match.candidate.primary
    to = if snapshot, do: snapshot.model_identifier, else: match.to

    context
    |> candidate_pricing(match.candidate, snapshot)
    |> put_pricing_alias_metadata(suffix_alias_metadata(match.from, to))
  end

  defp resolve_nearest_suffix(_context, _ambiguous, _category), do: nil

  defp suffix_category?(nil, _category), do: false
  defp suffix_category?(%{rule: %{"status" => status}}, :primary) when status in ["unknown", "invalid"], do: true
  defp suffix_category?(%{primary: %PricingSnapshot{} = snapshot}, :primary), do: priced_pricing_snapshot?(snapshot)
  defp suffix_category?(%{primary: %PricingSnapshot{} = snapshot}, :unavailable), do: unavailable_pricing_snapshot_marker?(snapshot)
  defp suffix_category?(candidate, :fallback), do: fallback?(candidate) and priced_pricing_snapshot?(candidate.fallback)
  defp suffix_category?(_candidate, _category), do: false

  defp candidate_pricing(context, candidate, snapshot) do
    pricing =
      case candidate.rule["status"] do
        status when status in ["unknown", "invalid"] ->
          unpriced_snapshot("unpriced_context_boundary_" <> status, context.requested_tier, context.actual_tier, context.service_tier, context.batch_usage, candidate.bucket)

        _status ->
          if priced_pricing_snapshot?(snapshot) do
            priced_snapshot(snapshot, context.requested_tier, context.actual_tier, context.service_tier, context.batch_usage, nil)
          else
            unavailable_price_bucket_snapshot(context.requested_tier, context.actual_tier, context.service_tier, candidate.bucket, context.batch_usage, nil)
          end
      end

    facts =
      candidate.facts
      |> Map.put("price_bucket", pricing.price_bucket)
      |> Map.put("snapshot_id", snapshot && snapshot.id)
      |> historical_generation(candidate, snapshot)

    pricing
    |> Map.put(:context_pricing, facts)
    |> annotate_price_bucket_fallback(candidate.bucket)
  end

  defp annotate_price_bucket_fallback(%{status: "priced", price_bucket: selected} = pricing, requested)
       when selected != requested do
    Map.put(pricing, :price_bucket_fallback, %{
      "requested" => requested,
      "selected" => selected,
      "reason" => if(requested == "long_context", do: "long_context_pricing_absent", else: "requested_bucket_pricing_absent")
    })
  end

  defp annotate_price_bucket_fallback(pricing, _requested), do: pricing

  defp historical_generation(facts, %{coherent: false}, %PricingSnapshot{} = snapshot) do
    update_in(facts, ["generation"], &Map.merge(&1, %{"price_version" => snapshot.price_version, "importer_format_revision" => snapshot.config["importer_format_revision"]}))
  end

  defp historical_generation(facts, _candidate, _snapshot), do: facts

  @spec suffix_inference_candidates([String.t()]) :: [suffix_candidate()]
  defp suffix_inference_candidates(identifiers) do
    exact_identifiers = MapSet.new(identifiers)

    identifiers
    |> Enum.flat_map(&suffix_inference_candidates_for_identifier/1)
    |> Enum.reject(&MapSet.member?(exact_identifiers, &1.to))
    |> Enum.uniq_by(fn candidate -> {candidate.from, candidate.to, candidate.distance} end)
  end

  @spec suffix_inference_candidates_for_identifier(term()) :: [suffix_candidate()]
  defp suffix_inference_candidates_for_identifier(identifier) when is_binary(identifier) do
    normalized_identifier = String.trim(identifier)
    segments = String.split(normalized_identifier, "-", trim: true)

    case segments do
      [_single] ->
        []

      [] ->
        []

      _segments ->
        do_suffix_inference_candidates(segments, normalized_identifier)
    end
  end

  defp suffix_inference_candidates_for_identifier(_identifier), do: []

  @spec do_suffix_inference_candidates([String.t()], String.t()) :: [suffix_candidate()]
  defp do_suffix_inference_candidates(segments, original_identifier) do
    segment_count = length(segments)

    1..(segment_count - 1)
    |> Enum.reduce_while({[], 0}, fn distance, {candidates, arbitrary_trim_count} ->
      suffix_inference_candidate_step(
        segments,
        original_identifier,
        segment_count,
        distance,
        candidates,
        arbitrary_trim_count
      )
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec suffix_inference_candidate_step(
          [String.t()],
          String.t(),
          pos_integer(),
          pos_integer(),
          [suffix_candidate()],
          non_neg_integer()
        ) :: {:cont | :halt, {[suffix_candidate()], non_neg_integer()}}
  defp suffix_inference_candidate_step(
         segments,
         original_identifier,
         segment_count,
         distance,
         candidates,
         arbitrary_trim_count
       ) do
    arbitrary_trim_count =
      if date_or_version_suffix?(Enum.at(segments, -distance)),
        do: arbitrary_trim_count,
        else: arbitrary_trim_count + 1

    if arbitrary_trim_count > 1 do
      {:halt, {candidates, arbitrary_trim_count}}
    else
      candidate_identifier =
        segments
        |> Enum.take(segment_count - distance)
        |> Enum.join("-")

      candidates =
        maybe_prepend_suffix_candidate(
          candidates,
          candidate_identifier,
          original_identifier,
          distance
        )

      {:cont, {candidates, arbitrary_trim_count}}
    end
  end

  @spec maybe_prepend_suffix_candidate(
          [suffix_candidate()],
          String.t(),
          String.t(),
          pos_integer()
        ) :: [suffix_candidate()]
  defp maybe_prepend_suffix_candidate(
         candidates,
         candidate_identifier,
         original_identifier,
         distance
       ) do
    if blank?(candidate_identifier) or candidate_identifier == original_identifier do
      candidates
    else
      [
        %{
          from: original_identifier,
          to: candidate_identifier,
          distance: distance
        }
        | candidates
      ]
    end
  end

  @spec date_or_version_suffix?(term()) :: boolean()
  defp date_or_version_suffix?(segment) when is_binary(segment) do
    Regex.match?(~r/\A(?:v)?\d+(?:[._]\d+)*\z/i, String.trim(segment))
  end

  defp date_or_version_suffix?(_segment), do: false

  @spec suffix_alias_metadata(String.t(), String.t()) :: map()
  defp suffix_alias_metadata(from_identifier, to_identifier) do
    %{
      "source" => "suffix_inference",
      "from" => from_identifier,
      "to" => to_identifier
    }
  end

  # Native Images use a catalog model only to select an eligible account. That
  # carrier's text-token prices do not describe the image service's usage.
  defp pricing_identifiers(_model, requested_model, endpoint)
       when endpoint in ["/backend-api/codex/images/generations", "/backend-api/codex/images/edits"] do
    Enum.reject([requested_model], &blank?/1)
  end

  defp pricing_identifiers(model, requested_model, _endpoint) do
    Enum.uniq(
      Enum.reject(
        [model.pricing_ref, model.upstream_model_id, model.exposed_model_id, requested_model],
        &blank?/1
      )
    )
  end

  defp missing_pricing_snapshot(context) do
    model_snapshot_exists? =
      Enum.any?(context.identifiers, fn identifier ->
        context.families[normalize_pricing_identifier(identifier)].model_exists
      end)

    status = if model_snapshot_exists?, do: "unpriced_missing_tier", else: "unpriced_missing_model"
    unpriced_snapshot(status, context.requested_tier, context.actual_tier, context.service_tier, context.batch_usage)
  end

  defp priced_snapshot(
         snapshot,
         requested_tier,
         actual_tier,
         service_tier,
         batch_usage?,
         alias_metadata
       ) do
    pricing = %{
      snapshot: snapshot,
      status: "priced",
      requested_service_tier: requested_tier,
      actual_service_tier: actual_tier,
      service_tier: service_tier,
      price_bucket: snapshot.config["price_bucket"],
      pricing_type: snapshot.config["pricing_type"],
      batch_usage: batch_usage?
    }

    put_pricing_alias_metadata(pricing, alias_metadata)
  end

  @spec priced_pricing_snapshot?(PricingSnapshot.t()) :: boolean()
  defp priced_pricing_snapshot?(%PricingSnapshot{} = snapshot) do
    not unavailable_pricing_snapshot_marker?(snapshot) and
      not is_nil(snapshot.input_token_micros) and not is_nil(snapshot.output_token_micros)
  end

  defp require_cache_write_rate(
         %{status: "priced", snapshot: %PricingSnapshot{cache_write_token_micros: nil}} = pricing,
         %{cache_write_tokens: cache_write_tokens}
       )
       when is_integer(cache_write_tokens) and cache_write_tokens > 0 do
    %{pricing | status: "unpriced_missing_cache_write_rate"}
  end

  defp require_cache_write_rate(pricing, _usage), do: pricing

  defp require_cached_input_rate(
         %{status: "priced", snapshot: %PricingSnapshot{cached_input_token_micros: nil}} = pricing,
         %{input_tokens: input_tokens, cached_input_tokens: cached_input_tokens}
       )
       when is_integer(input_tokens) and input_tokens > 0 and is_integer(cached_input_tokens) and cached_input_tokens > 0 do
    %{pricing | status: "unpriced_missing_cached_input_rate"}
  end

  defp require_cached_input_rate(pricing, _usage), do: pricing

  @spec unavailable_pricing_snapshot_marker?(PricingSnapshot.t()) :: boolean()
  defp unavailable_pricing_snapshot_marker?(%PricingSnapshot{config: config}) do
    Map.get(config || %{}, "availability") == @unavailable_pricing_availability
  end

  @spec unavailable_price_bucket_snapshot(
          String.t() | nil,
          String.t() | nil,
          String.t(),
          String.t(),
          boolean(),
          map() | nil
        ) :: map()
  defp unavailable_price_bucket_snapshot(
         requested_tier,
         actual_tier,
         service_tier,
         price_bucket,
         batch_usage?,
         alias_metadata
       ) do
    "unpriced_unavailable_price_bucket"
    |> unpriced_snapshot(requested_tier, actual_tier, service_tier, batch_usage?, price_bucket)
    |> put_pricing_alias_metadata(alias_metadata)
  end

  defp unpriced_snapshot(
         status,
         requested_tier,
         actual_tier,
         service_tier,
         batch_usage?,
         price_bucket \\ @default_price_bucket
       ) do
    %{
      snapshot: nil,
      status: status,
      requested_service_tier: requested_tier,
      actual_service_tier: actual_tier,
      service_tier: service_tier,
      price_bucket: price_bucket,
      pricing_type: "per_1m_tokens",
      batch_usage: batch_usage?
    }
  end

  defp requested_service_tier(payload, opts) do
    opts
    |> enforced_service_tier()
    |> fallback(attr(opts, :service_tier))
    |> fallback(attr(payload, :service_tier))
    |> ServiceTier.canonicalize()
  end

  defp enforced_service_tier(opts) do
    policy = attr(opts, :api_key_policy) || %{}
    attr(policy, :enforced_service_tier)
  end

  defp explicit_batch_usage?(payload, opts) do
    [
      dual_key_value(opts, :batch_usage),
      dual_key_value(opts, :batch),
      dual_key_value(payload, :batch_usage),
      dual_key_value(payload, :batch)
    ]
    |> Enum.any?(&truthy?/1)
    |> batch_usage_from_flags?(
      attr(opts, :endpoint),
      attr(opts, :request_metadata)
    )
  end

  defp batch_usage_from_flags?(true, _endpoint, _metadata), do: true

  defp batch_usage_from_flags?(false, endpoint, metadata) do
    batch_endpoint?(endpoint) || batch_metadata?(metadata)
  end

  defp batch_metadata?(%{} = metadata) do
    pricing = dual_key_value(metadata, :pricing)

    truthy?(dual_key_value(metadata, :batch_usage)) ||
      truthy?(dual_key_value(metadata, :batch)) ||
      truthy?(dual_key_value(pricing, :batch_usage))
  end

  defp batch_metadata?(_metadata), do: false

  defp dual_key_value(%{} = map, atom_key) when is_atom(atom_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(atom_key))
    end
  end

  defp dual_key_value(_map, _atom_key), do: nil

  defp batch_endpoint?(endpoint) when is_binary(endpoint), do: String.contains?(endpoint, "batch")
  defp batch_endpoint?(_endpoint), do: false

  defp actual_service_tier(usage, opts) do
    opts
    |> attr(:actual_service_tier)
    |> fallback(metadata_service_tier(attr(opts, :attempt_metadata)))
    |> fallback(attr(usage, :service_tier))
    |> ServiceTier.canonicalize()
  end

  defp metadata_service_tier(%{} = metadata) do
    attr(metadata, :service_tier) ||
      get_in(metadata, ["response", "service_tier"]) ||
      get_in(metadata, [:response, :service_tier]) ||
      get_in(metadata, ["pricing", "actual_service_tier"]) ||
      get_in(metadata, [:pricing, :actual_service_tier])
  end

  defp metadata_service_tier(_metadata), do: nil

  defp priceable_service_tier(requested_tier, actual_tier, batch_usage?) do
    requested = normalize_service_tier(requested_tier)
    actual = normalize_service_tier(actual_tier)

    cond do
      requested == "batch" and not batch_usage? -> {:unpriced, "unpriced_batch_tier"}
      requested == "batch" -> mapped_service_tier(requested, batch_usage?)
      echo_hides_requested_tier?(requested, actual) -> mapped_service_tier(requested, batch_usage?)
      actual not in [nil, "auto"] -> mapped_service_tier(actual, batch_usage?)
      requested == "auto" and actual in [nil, "auto"] -> {:unpriced, "unpriced_auto_tier"}
      true -> mapped_service_tier(requested, batch_usage?)
    end
  end

  # The ChatGPT Codex backend reports `default` on the terminal response of a
  # request that asked for `priority` (Fast), with or without the Pooler in the
  # path, while it serves and meters the request as Fast: the provider bills
  # Fast at a multiple of the standard credit rate and it uses included limits
  # faster (findings#127, findings#206 row 206-271). A `default` echo therefore
  # says nothing about a requested priority tier, and pricing keeps the tier
  # that was requested. The same fail-closed rule applies to an explicit
  # ultrafast request: an ambiguous `default` echo must not select Standard
  # while the catalog has no applicable ultrafast generation. Any other
  # reported tier still outranks the request.
  defp echo_hides_requested_tier?(requested, "default") when requested in ["priority", "ultrafast"], do: true
  defp echo_hides_requested_tier?(_requested, _actual), do: false

  defp mapped_service_tier("batch", false), do: {:unpriced, "unpriced_batch_tier"}
  defp mapped_service_tier("batch", true), do: {:ok, "batch"}
  defp mapped_service_tier(tier, _batch_usage?), do: mapped_service_tier(tier)

  defp mapped_service_tier(nil), do: {:ok, "standard"}
  defp mapped_service_tier("default"), do: {:ok, "standard"}
  defp mapped_service_tier("standard"), do: {:ok, "standard"}
  defp mapped_service_tier("flex"), do: {:ok, "flex"}
  defp mapped_service_tier("priority"), do: {:ok, "priority"}
  defp mapped_service_tier("ultrafast"), do: {:ok, "ultrafast"}
  defp mapped_service_tier("batch"), do: {:ok, "batch"}

  # Scale is a recognized service tier. Resolve only matching snapshots;
  # without one, leave pricing explicitly unpriced rather than borrowing
  # another tier's rate.
  defp mapped_service_tier("scale"), do: {:ok, "scale"}

  defp mapped_service_tier(_tier), do: {:unpriced, "unpriced_unsupported_tier"}

  defp normalize_service_tier(tier), do: ServiceTier.canonicalize(tier)

  defp normalize_pricing_identifiers(identifiers) do
    identifiers
    |> Enum.map(&normalize_pricing_identifier/1)
    |> Enum.uniq()
  end

  defp normalize_pricing_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.downcase()
  end

  defp requested_service_tier_snapshot(payload, request_metadata, pricing) do
    pricing.requested_service_tier ||
      pricing_metadata_value(request_metadata, "requested_service_tier") ||
      attr(payload, :service_tier)
  end

  defp actual_service_tier_snapshot(request_metadata, pricing) do
    pricing.actual_service_tier || pricing_metadata_value(request_metadata, "actual_service_tier")
  end

  defp effective_service_tier_snapshot(requested_tier, actual_tier, request_metadata, pricing) do
    pricing.service_tier ||
      pricing_metadata_value(request_metadata, "service_tier") ||
      actual_tier || requested_tier
  end

  defp payload_reasoning_effort(payload) do
    attr(payload, :reasoning_effort) || nested_reasoning_effort(payload)
  end

  # The payload is the client's, read before dispatch: only an object `reasoning` states an effort. Any other shape
  # (a string, a list) is the provider's to refuse at validation, and the request must still reach it (findings#339).
  defp nested_reasoning_effort(%{"reasoning" => %{"effort" => effort}}), do: effort
  defp nested_reasoning_effort(%{reasoning: %{effort: effort}}), do: effort
  defp nested_reasoning_effort(_payload), do: nil

  defp pricing_metadata_value(request_metadata, key) do
    get_in(request_metadata, ["pricing", key])
  end

  defp normalize_snapshot_value(nil), do: nil

  defp normalize_snapshot_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_snapshot_value(value) when is_atom(value) or is_number(value), do: value |> to_string() |> normalize_snapshot_value()

  # An effort the client sent as an object or a list states no effort to record.
  defp normalize_snapshot_value(_value), do: nil

  defp metadata_pricing_value(%Request{request_metadata: metadata}, key) do
    get_in(metadata || %{}, ["pricing", key])
  end

  defp details_value(%LedgerEntry{details: details}, key),
    do: Map.get(details || %{}, key)

  defp fallback(nil, value), do: value
  defp fallback(value, _fallback), do: value

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp truthy?(value), do: value in [true, "true", "1", 1, "yes", "batch"]

  defp put_pricing_alias_metadata(pricing, nil), do: pricing

  defp put_pricing_alias_metadata(pricing, alias_metadata),
    do: Map.put(pricing, :alias, alias_metadata)

  defp put_serialized_alias_metadata(serialized, nil), do: serialized

  defp put_serialized_alias_metadata(serialized, alias_metadata),
    do: Map.put(serialized, "alias", alias_metadata)

  defp put_serialized_price_bucket_fallback(serialized, nil), do: serialized

  defp put_serialized_price_bucket_fallback(serialized, fallback),
    do: Map.put(serialized, "price_bucket_fallback", fallback)

  defp put_serialized_context_pricing(serialized, nil), do: serialized

  defp put_serialized_context_pricing(serialized, facts),
    do: Map.put(serialized, "context_pricing", facts)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  if Mix.env() == :test do
    # Test-only fault seam: raises the armed exception once, from inside a
    # response task's settlement transaction, reproducing a database failure
    # at the pricing lookup (the production frame under pool exhaustion).
    # Armed per pool and one-shot, so the task's own recovery finalization
    # and the client's resend run against a healthy database.
    defp maybe_test_settlement_fault(%Request{pool_id: pool_id}) do
      case Application.get_env(:codex_pooler, :settlement_pricing_test_fault) do
        {^pool_id, exception} when is_exception(exception) ->
          Application.delete_env(:codex_pooler, :settlement_pricing_test_fault)
          raise exception

        _no_fault ->
          :ok
      end
    end
  else
    defp maybe_test_settlement_fault(_request), do: :ok
  end
end
