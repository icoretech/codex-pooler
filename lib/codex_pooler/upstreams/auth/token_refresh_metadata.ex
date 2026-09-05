defmodule CodexPooler.Upstreams.Auth.TokenRefreshMetadata do
  @moduledoc false

  alias CodexPooler.Upstreams.Auth.AccessTokenExpiry

  @canonical_expiry_key "access_token_expires_at"
  @legacy_expiry_key "secret_expires_at"
  @credential_epoch_key "credential_epoch"
  @token_refresh_key "token_refresh"
  @marker_key "access_token_expiry"
  @preserved_refresh_keys ~w(attempt_id started_at receive_timeout_ms stale_after_ms rotated_refresh_token)
  @known_sources %{
    :jwt_exp => "jwt_exp",
    :explicit => "explicit",
    :expires_in => "expires_in"
  }
  @known_source_strings Map.values(@known_sources)
  @marker_keys MapSet.new(~w(version credential_epoch state source))

  @spec build_imported(
          map() | nil,
          AccessTokenExpiry.resolution(),
          pos_integer(),
          String.t(),
          DateTime.t()
        ) :: map()
  def build_imported(metadata, resolution, epoch, trigger_kind, %DateTime{} = imported_at) do
    build_replacement(metadata, resolution, epoch, %{
      "status" => "imported",
      "trigger_kind" => trigger_kind,
      "imported_at" => DateTime.to_iso8601(imported_at)
    })
  end

  @spec build_succeeded(
          map() | nil,
          AccessTokenExpiry.resolution(),
          pos_integer(),
          String.t(),
          DateTime.t(),
          map()
        ) :: map()
  def build_succeeded(
        metadata,
        resolution,
        epoch,
        trigger_kind,
        %DateTime{} = finished_at,
        fields \\ %{}
      ) do
    build_replacement(
      metadata,
      resolution,
      epoch,
      %{
        "status" => "succeeded",
        "trigger_kind" => trigger_kind,
        "finished_at" => DateTime.to_iso8601(finished_at)
      },
      fields
    )
  end

  @spec preserve_access_token_expiry(map() | nil, map() | nil) :: map()
  def preserve_access_token_expiry(metadata, replacement_refresh) do
    metadata = normalize_metadata(metadata)
    replacement_refresh = normalize_metadata(replacement_refresh)

    case metadata[@token_refresh_key] do
      %{} = current ->
        case Map.fetch(current, @marker_key) do
          {:ok, marker} -> Map.put(replacement_refresh, @marker_key, marker)
          :error -> replacement_refresh
        end

      _current ->
        replacement_refresh
    end
  end

  @spec project_access_token_expiry(term()) :: AccessTokenExpiry.resolution()
  def project_access_token_expiry(%{} = metadata) do
    case Map.fetch(metadata, @token_refresh_key) do
      {:ok, %{} = token_refresh} -> project_marker(metadata, token_refresh[@marker_key])
      {:ok, _present_but_invalid} -> AccessTokenExpiry.unknown()
      :error -> project_legacy(metadata)
    end
  end

  def project_access_token_expiry(_metadata), do: AccessTokenExpiry.unknown()

  @spec rebind_access_token_expiry(map(), map(), pos_integer()) :: map()
  def rebind_access_token_expiry(metadata, previous_metadata, new_epoch)
      when is_map(metadata) and is_map(previous_metadata) and is_integer(new_epoch) and
             new_epoch > 0 do
    old_epoch = previous_metadata[@credential_epoch_key]

    with ^new_epoch <- metadata[@credential_epoch_key],
         true <- is_integer(old_epoch) and old_epoch > 0,
         %{} = refresh <- metadata[@token_refresh_key],
         %{} = marker <- refresh[@marker_key],
         true <- trusted_marker?(previous_metadata, marker, old_epoch) do
      put_in(metadata, [@token_refresh_key, @marker_key, @credential_epoch_key], new_epoch)
    else
      _untrusted -> preserve_untrusted_or_legacy_expiry(metadata, previous_metadata, new_epoch)
    end
  end

  def rebind_access_token_expiry(metadata, _old_epoch, _new_epoch), do: metadata

  defp preserve_untrusted_or_legacy_expiry(metadata, previous_metadata, new_epoch) do
    case Map.fetch(metadata, @token_refresh_key) do
      {:ok, %{@marker_key => _untrusted} = refresh} ->
        Map.put(
          metadata,
          @token_refresh_key,
          Map.put(refresh, @marker_key, marker(AccessTokenExpiry.unknown(), new_epoch))
        )

      :error ->
        preserve_legacy_expiry(metadata, previous_metadata, new_epoch)

      _without_marker ->
        metadata
    end
  end

  defp preserve_legacy_expiry(metadata, previous_metadata, new_epoch) do
    case project_access_token_expiry(previous_metadata) do
      %{state: :known, deadline: deadline} = resolution ->
        metadata
        |> Map.put(@canonical_expiry_key, DateTime.to_iso8601(deadline))
        |> Map.put(@token_refresh_key, %{@marker_key => marker(resolution, new_epoch)})

      _unknown ->
        metadata
    end
  end

  defp build_replacement(metadata, resolution, epoch, required_fields, supplied_fields \\ %{})
       when is_integer(epoch) and epoch > 0 do
    metadata = normalize_metadata(metadata)
    current_refresh = normalize_metadata(metadata[@token_refresh_key])

    refresh =
      current_refresh
      |> Map.take(@preserved_refresh_keys)
      |> Map.merge(normalize_metadata(supplied_fields))
      |> Map.merge(required_fields)
      |> Map.put("generation", next_generation(current_refresh["generation"]))
      |> Map.put(@marker_key, marker(resolution, epoch))

    metadata
    |> Map.delete(@canonical_expiry_key)
    |> Map.delete(@legacy_expiry_key)
    |> Map.put(@credential_epoch_key, epoch)
    |> Map.put(@token_refresh_key, refresh)
    |> maybe_put_canonical_expiry(resolution)
  end

  defp marker(%{state: :known, source: source, deadline: %DateTime{}}, epoch)
       when is_map_key(@known_sources, source) do
    %{
      "version" => 1,
      @credential_epoch_key => epoch,
      "state" => "known",
      "source" => Map.fetch!(@known_sources, source)
    }
  end

  defp marker(_resolution, epoch) do
    %{
      "version" => 1,
      @credential_epoch_key => epoch,
      "state" => "unknown",
      "source" => "unavailable"
    }
  end

  defp maybe_put_canonical_expiry(metadata, %{state: :known, deadline: %DateTime{} = deadline}) do
    Map.put(metadata, @canonical_expiry_key, DateTime.to_iso8601(deadline))
  end

  defp maybe_put_canonical_expiry(metadata, _resolution), do: metadata

  defp project_marker(metadata, marker) do
    epoch = metadata[@credential_epoch_key]

    if is_integer(epoch) and epoch > 0 and trusted_marker?(metadata, marker, epoch) do
      case marker do
        %{"state" => "known", "source" => source} ->
          {:ok, deadline} = AccessTokenExpiry.parse_datetime(metadata[@canonical_expiry_key])
          AccessTokenExpiry.known(deadline, source_atom(source))

        %{"state" => "unknown"} ->
          AccessTokenExpiry.unknown()
      end
    else
      AccessTokenExpiry.unknown()
    end
  end

  defp trusted_marker?(metadata, %{} = marker, epoch) do
    marker_keys = marker |> Map.keys() |> MapSet.new()

    marker["version"] == 1 and marker[@credential_epoch_key] == epoch and
      case marker do
        %{"state" => "known", "source" => source}
        when source in @known_source_strings ->
          marker_keys == @marker_keys and
            match?(
              {:ok, %DateTime{}},
              AccessTokenExpiry.parse_datetime(metadata[@canonical_expiry_key])
            )

        %{"state" => "unknown", "source" => "unavailable"} ->
          marker_keys == @marker_keys

        _invalid ->
          false
      end
  end

  defp trusted_marker?(_metadata, _marker, _epoch), do: false

  defp project_legacy(metadata) do
    if legacy_epoch?(Map.fetch(metadata, @credential_epoch_key)) do
      metadata
      |> Map.get(@canonical_expiry_key, metadata[@legacy_expiry_key])
      |> AccessTokenExpiry.parse_datetime()
      |> case do
        {:ok, deadline} -> AccessTokenExpiry.known(deadline, :explicit)
        :error -> AccessTokenExpiry.unknown()
      end
    else
      AccessTokenExpiry.unknown()
    end
  end

  defp legacy_epoch?(:error), do: true
  defp legacy_epoch?({:ok, 1}), do: true
  defp legacy_epoch?(_epoch), do: false

  defp source_atom("jwt_exp"), do: :jwt_exp
  defp source_atom("explicit"), do: :explicit
  defp source_atom("expires_in"), do: :expires_in

  defp next_generation(generation) when is_integer(generation) and generation >= 0,
    do: generation + 1

  defp next_generation(_generation), do: 1

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
