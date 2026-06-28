defmodule CodexPooler.Accounting.PricingResolution do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.PricingResolution.Costing
  alias CodexPooler.Catalog.{Model, PricingSnapshot}
  alias CodexPooler.Repo

  @default_price_bucket "default"
  @long_context_price_bucket "long_context"
  @unavailable_pricing_availability "unavailable"

  @typep suffix_candidate :: %{
           from: String.t(),
           to: String.t(),
           distance: pos_integer()
         }

  @typep snapshots_by_identifier :: %{optional(String.t()) => PricingSnapshot.t()}
  @typep suffix_snapshot_lookup ::
           ([String.t()], String.t(), String.t(), DateTime.t() -> snapshots_by_identifier())

  @typep pricing_context :: %{
           identifiers: [String.t()],
           requested_tier: String.t() | nil,
           actual_tier: String.t() | nil,
           service_tier: String.t(),
           price_bucket: String.t(),
           timestamp: DateTime.t(),
           batch_usage: boolean()
         }

  @typep pricing_resolution_step ::
           {:exact | :suffix, :priced | :unavailable, String.t()}

  @spec lookup(Model.t(), String.t(), map(), map(), DateTime.t()) :: map()
  def lookup(%Model{} = model, requested_model, payload, opts, timestamp) do
    requested_tier = requested_service_tier(payload, opts)
    actual_tier = actual_service_tier(%{}, opts)
    batch_usage? = explicit_batch_usage?(payload, opts)
    price_bucket = Costing.price_bucket(payload)

    lookup_for_tier(
      model,
      requested_model,
      requested_tier,
      actual_tier,
      price_bucket,
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

      lookup_for_tier(
        model,
        request.requested_model,
        requested_tier,
        actual_tier,
        Costing.price_bucket_for_input_tokens(usage.input_tokens),
        timestamp,
        details_value(reservation, "batch_usage") == true
      )
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

  @spec reservation_estimate(map(), struct() | nil, term()) :: {:ok, map()}
  defdelegate reservation_estimate(payload, snapshot, policy), to: Costing

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

    put_serialized_alias_metadata(pricing_metadata, Map.get(pricing, :alias))
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

    put_serialized_alias_metadata(details, Map.get(pricing, :alias))
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
      requested_service_tier: normalize_snapshot_value(requested_tier),
      actual_service_tier: normalize_snapshot_value(actual_tier),
      service_tier: normalize_snapshot_value(effective_tier)
    }
  end

  defp lookup_for_request_metadata(%Request{} = request, %Model{} = model, timestamp) do
    requested_tier = metadata_pricing_value(request, "requested_service_tier")
    actual_tier = metadata_pricing_value(request, "actual_service_tier")

    lookup_for_tier(
      model,
      request.requested_model,
      requested_tier,
      actual_tier,
      metadata_pricing_value(request, "price_bucket") || @default_price_bucket,
      timestamp,
      metadata_pricing_value(request, "batch_usage") == true
    )
  end

  defp lookup_for_tier(
         %Model{} = model,
         requested_model,
         requested_tier,
         actual_tier,
         price_bucket,
         timestamp,
         batch_usage?
       ) do
    identifiers = pricing_identifiers(model, requested_model)

    case priceable_service_tier(requested_tier, actual_tier, batch_usage?) do
      {:ok, service_tier} ->
        lookup_for_service_tier(
          identifiers,
          requested_tier,
          actual_tier,
          service_tier,
          price_bucket,
          timestamp,
          batch_usage?
        )

      {:unpriced, status} ->
        service_tier = if normalize_service_tier(requested_tier) == "batch", do: "batch"
        unpriced_snapshot(status, requested_tier, actual_tier, service_tier, batch_usage?)
    end
  end

  defp lookup_for_service_tier(
         identifiers,
         requested_tier,
         actual_tier,
         service_tier,
         price_bucket,
         timestamp,
         batch_usage?
       ) do
    context = %{
      identifiers: identifiers,
      requested_tier: requested_tier,
      actual_tier: actual_tier,
      service_tier: service_tier,
      price_bucket: price_bucket,
      timestamp: timestamp,
      batch_usage: batch_usage?
    }

    context
    |> pricing_resolution_steps()
    |> Enum.find_value(&resolve_pricing_step(context, &1))
    |> case do
      nil -> missing_pricing_snapshot(context)
      pricing -> pricing
    end
  end

  @spec pricing_resolution_steps(pricing_context()) :: [pricing_resolution_step()]
  defp pricing_resolution_steps(%{price_bucket: @long_context_price_bucket}) do
    [
      {:exact, :priced, @long_context_price_bucket},
      {:exact, :unavailable, @long_context_price_bucket},
      {:exact, :priced, @default_price_bucket},
      {:suffix, :priced, @long_context_price_bucket},
      {:suffix, :unavailable, @long_context_price_bucket},
      {:suffix, :priced, @default_price_bucket}
    ]
  end

  defp pricing_resolution_steps(%{price_bucket: price_bucket}) do
    [
      {:exact, :priced, price_bucket},
      {:exact, :unavailable, price_bucket},
      {:suffix, :priced, price_bucket},
      {:suffix, :unavailable, price_bucket}
    ]
  end

  @spec resolve_pricing_step(pricing_context(), pricing_resolution_step()) :: map() | nil
  defp resolve_pricing_step(context, {:exact, :priced, price_bucket}) do
    case pricing_snapshot(
           context.identifiers,
           context.service_tier,
           price_bucket,
           context.timestamp
         ) do
      %PricingSnapshot{} = snapshot -> priced_snapshot(context, snapshot)
      nil -> nil
    end
  end

  defp resolve_pricing_step(context, {:exact, :unavailable, price_bucket}) do
    case unavailable_pricing_snapshot(
           context.identifiers,
           context.service_tier,
           price_bucket,
           context.timestamp
         ) do
      %PricingSnapshot{} -> unavailable_price_bucket_snapshot(context, price_bucket)
      nil -> nil
    end
  end

  defp resolve_pricing_step(context, {:suffix, :priced, price_bucket}) do
    case suffix_inference_pricing_snapshot(
           context.identifiers,
           context.service_tier,
           price_bucket,
           context.timestamp
         ) do
      {%PricingSnapshot{} = snapshot, alias_metadata} ->
        priced_snapshot(context, snapshot, alias_metadata)

      nil ->
        nil
    end
  end

  defp resolve_pricing_step(context, {:suffix, :unavailable, price_bucket}) do
    case suffix_inference_unavailable_pricing_snapshot(
           context.identifiers,
           context.service_tier,
           price_bucket,
           context.timestamp
         ) do
      {%PricingSnapshot{}, alias_metadata} ->
        unavailable_price_bucket_snapshot(context, price_bucket, alias_metadata)

      nil ->
        nil
    end
  end

  defp priced_snapshot(context, snapshot, alias_metadata \\ nil) do
    priced_snapshot(
      snapshot,
      context.requested_tier,
      context.actual_tier,
      context.service_tier,
      context.batch_usage,
      alias_metadata
    )
  end

  defp unavailable_price_bucket_snapshot(context, price_bucket, alias_metadata \\ nil) do
    unavailable_price_bucket_snapshot(
      context.requested_tier,
      context.actual_tier,
      context.service_tier,
      price_bucket,
      context.batch_usage,
      alias_metadata
    )
  end

  @spec pricing_snapshot([String.t()], String.t(), String.t(), DateTime.t()) ::
          PricingSnapshot.t() | nil
  defp pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
    case latest_pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
      %PricingSnapshot{} = snapshot ->
        if priced_pricing_snapshot?(snapshot), do: snapshot

      nil ->
        nil
    end
  end

  @spec unavailable_pricing_snapshot([String.t()], String.t(), String.t(), DateTime.t()) ::
          PricingSnapshot.t() | nil
  defp unavailable_pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
    case latest_pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
      %PricingSnapshot{} = snapshot ->
        if unavailable_pricing_snapshot_marker?(snapshot), do: snapshot

      nil ->
        nil
    end
  end

  @spec latest_pricing_snapshot([String.t()], String.t(), String.t(), DateTime.t()) ::
          PricingSnapshot.t() | nil
  defp latest_pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
    Repo.one(
      from ps in PricingSnapshot,
        where:
          ps.model_identifier in ^identifiers and ps.effective_at <= ^timestamp and
            fragment("?->>'service_tier'", ps.config) == ^service_tier and
            fragment("?->>'price_bucket'", ps.config) == ^price_bucket and
            fragment("?->>'pricing_type'", ps.config) == "per_1m_tokens",
        order_by: [desc: ps.effective_at, desc: ps.captured_at, desc: ps.id],
        limit: 1
    )
  end

  @spec suffix_inference_pricing_snapshot([String.t()], String.t(), String.t(), DateTime.t()) ::
          {PricingSnapshot.t(), map()} | nil
  defp suffix_inference_pricing_snapshot(identifiers, service_tier, price_bucket, timestamp) do
    suffix_inference_snapshot(
      identifiers,
      service_tier,
      price_bucket,
      timestamp,
      &pricing_snapshots_by_identifier/4
    )
  end

  @spec suffix_inference_unavailable_pricing_snapshot(
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t()
        ) :: {PricingSnapshot.t(), map()} | nil
  defp suffix_inference_unavailable_pricing_snapshot(
         identifiers,
         service_tier,
         price_bucket,
         timestamp
       ) do
    suffix_inference_snapshot(
      identifiers,
      service_tier,
      price_bucket,
      timestamp,
      &unavailable_pricing_snapshots_by_identifier/4
    )
  end

  @spec suffix_inference_snapshot(
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t(),
          suffix_snapshot_lookup()
        ) :: {PricingSnapshot.t(), map()} | nil
  defp suffix_inference_snapshot(identifiers, service_tier, price_bucket, timestamp, lookup_fun) do
    candidates = suffix_inference_candidates(identifiers)
    candidate_identifiers = candidates |> Enum.map(& &1.to) |> Enum.uniq()

    snapshots_by_identifier =
      lookup_fun.(candidate_identifiers, service_tier, price_bucket, timestamp)

    candidates
    |> Enum.flat_map(&candidate_snapshot_match(&1, snapshots_by_identifier))
    |> nearest_suffix_inference_match()
  end

  @spec pricing_snapshots_by_identifier([String.t()], String.t(), String.t(), DateTime.t()) ::
          snapshots_by_identifier()
  defp pricing_snapshots_by_identifier([], _service_tier, _price_bucket, _timestamp), do: %{}

  defp pricing_snapshots_by_identifier(identifiers, service_tier, price_bucket, timestamp) do
    identifiers
    |> latest_pricing_snapshots_by_identifier(service_tier, price_bucket, timestamp)
    |> Map.filter(fn {_identifier, snapshot} -> priced_pricing_snapshot?(snapshot) end)
  end

  @spec unavailable_pricing_snapshots_by_identifier(
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t()
        ) :: snapshots_by_identifier()
  defp unavailable_pricing_snapshots_by_identifier([], _service_tier, _price_bucket, _timestamp),
    do: %{}

  defp unavailable_pricing_snapshots_by_identifier(
         identifiers,
         service_tier,
         price_bucket,
         timestamp
       ) do
    identifiers
    |> latest_pricing_snapshots_by_identifier(service_tier, price_bucket, timestamp)
    |> Map.filter(fn {_identifier, snapshot} ->
      unavailable_pricing_snapshot_marker?(snapshot)
    end)
  end

  @spec latest_pricing_snapshots_by_identifier(
          [String.t()],
          String.t(),
          String.t(),
          DateTime.t()
        ) :: snapshots_by_identifier()
  defp latest_pricing_snapshots_by_identifier(identifiers, service_tier, price_bucket, timestamp) do
    PricingSnapshot
    |> where(
      [ps],
      ps.model_identifier in ^identifiers and ps.effective_at <= ^timestamp and
        fragment("?->>'service_tier'", ps.config) == ^service_tier and
        fragment("?->>'price_bucket'", ps.config) == ^price_bucket and
        fragment("?->>'pricing_type'", ps.config) == "per_1m_tokens"
    )
    |> order_by([ps],
      asc: ps.model_identifier,
      desc: ps.effective_at,
      desc: ps.captured_at,
      desc: ps.id
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn snapshot, snapshots ->
      Map.put_new(snapshots, snapshot.model_identifier, snapshot)
    end)
  end

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

  @spec candidate_snapshot_match(suffix_candidate(), map()) :: [map()]
  defp candidate_snapshot_match(candidate, snapshots_by_identifier) do
    case Map.fetch(snapshots_by_identifier, candidate.to) do
      {:ok, snapshot} -> [Map.put(candidate, :snapshot, snapshot)]
      :error -> []
    end
  end

  @spec nearest_suffix_inference_match([map()]) :: {PricingSnapshot.t(), map()} | nil
  defp nearest_suffix_inference_match([]), do: nil

  defp nearest_suffix_inference_match(matches) do
    nearest_distance = matches |> Enum.map(& &1.distance) |> Enum.min()
    nearest_matches = Enum.filter(matches, &(&1.distance == nearest_distance))

    case nearest_matches |> Enum.map(& &1.snapshot.model_identifier) |> Enum.uniq() do
      [model_identifier] ->
        match = Enum.find(nearest_matches, &(&1.snapshot.model_identifier == model_identifier))

        {match.snapshot, suffix_alias_metadata(match.from, model_identifier)}

      _ambiguous_or_missing ->
        nil
    end
  end

  @spec suffix_alias_metadata(String.t(), String.t()) :: map()
  defp suffix_alias_metadata(from_identifier, to_identifier) do
    %{
      "source" => "suffix_inference",
      "from" => from_identifier,
      "to" => to_identifier
    }
  end

  defp pricing_identifiers(model, requested_model) do
    Enum.uniq(
      Enum.reject(
        [model.pricing_ref, model.upstream_model_id, model.exposed_model_id, requested_model],
        &blank?/1
      )
    )
  end

  @spec missing_pricing_snapshot(pricing_context()) :: map()
  defp missing_pricing_snapshot(context) do
    model_snapshot_exists? =
      Repo.exists?(
        from ps in PricingSnapshot,
          where:
            ps.model_identifier in ^context.identifiers and ps.effective_at <= ^context.timestamp and
              fragment("?->>'price_bucket'", ps.config) == "default" and
              fragment("?->>'pricing_type'", ps.config) == "per_1m_tokens"
      )

    status =
      if model_snapshot_exists?, do: "unpriced_missing_tier", else: "unpriced_missing_model"

    unpriced_snapshot(
      status,
      context.requested_tier,
      context.actual_tier,
      context.service_tier,
      context.batch_usage
    )
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
    enforced_service_tier(opts) || attr(opts, :service_tier) || attr(payload, :service_tier)
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
    attr(opts, :actual_service_tier) ||
      metadata_service_tier(attr(opts, :attempt_metadata)) ||
      attr(usage, :service_tier)
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
      requested == "auto" and actual in [nil, "auto"] -> {:unpriced, "unpriced_auto_tier"}
      requested == "auto" -> mapped_service_tier(actual, batch_usage?)
      true -> mapped_service_tier(requested, batch_usage?)
    end
  end

  defp mapped_service_tier("batch", false), do: {:unpriced, "unpriced_batch_tier"}
  defp mapped_service_tier("batch", true), do: {:ok, "batch"}
  defp mapped_service_tier(tier, _batch_usage?), do: mapped_service_tier(tier)

  defp mapped_service_tier(nil), do: {:ok, "standard"}
  defp mapped_service_tier("default"), do: {:ok, "standard"}
  defp mapped_service_tier("standard"), do: {:ok, "standard"}
  defp mapped_service_tier("flex"), do: {:ok, "flex"}
  defp mapped_service_tier("priority"), do: {:ok, "priority"}
  defp mapped_service_tier("batch"), do: {:ok, "batch"}
  defp mapped_service_tier(_tier), do: {:unpriced, "unpriced_unsupported_tier"}

  defp normalize_service_tier(nil), do: nil

  defp normalize_service_tier(tier) when is_binary(tier) do
    tier
    |> String.trim()
    |> String.downcase()
    |> blank_to_nil()
  end

  defp normalize_service_tier(tier), do: tier |> to_string() |> normalize_service_tier()

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
    attr(payload, :reasoning_effort) ||
      get_in(payload, ["reasoning", "effort"]) ||
      get_in(payload, [:reasoning, :effort])
  end

  defp pricing_metadata_value(request_metadata, key) do
    get_in(request_metadata, ["pricing", key])
  end

  defp normalize_snapshot_value(nil), do: nil

  defp normalize_snapshot_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> blank_to_nil()
  end

  defp normalize_snapshot_value(value), do: value |> to_string() |> normalize_snapshot_value()

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
