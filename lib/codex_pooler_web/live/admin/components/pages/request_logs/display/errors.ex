defmodule CodexPoolerWeb.Admin.RequestLogsDisplay.Errors do
  @moduledoc false

  alias CodexPoolerWeb.DateTimeDisplay

  def format_errors(%{errors: errors}, datetime_preferences) do
    if is_nil(errors) or errors == [] do
      ["—"]
    else
      error_display_items(errors, datetime_preferences)
    end
  end

  defp error_display_items(errors, datetime_preferences) do
    advised = advised_reset_at(errors)

    cond do
      Enum.any?(errors, &quota_exhaustion_error?/1) ->
        ["quota exhausted"] ++
          reset_display_items(advised || exhausted_reset_at(errors), datetime_preferences)

      Enum.any?(errors, &quota_evidence_unavailable?/1) ->
        ["quota evidence unavailable"]

      true ->
        errors
        |> Enum.map(&format_single_error/1)
        |> Enum.uniq()
        |> Kernel.++(reset_display_items(advised, datetime_preferences))
    end
  end

  @doc """
  The reset a terminal usage-limit refusal advised the client and its
  `Retry-After` seconds, from a routed refusal's `gateway_denial` or a relayed
  provider `429`'s attempt (findings#206 rows 206-553, 206-577), or `nil`.
  The list's failure line and the drawer render the same advice.
  """
  @spec advised_reset([map()] | nil) :: {String.t(), pos_integer()} | nil
  def advised_reset(errors) when is_list(errors) do
    Enum.find_value(errors, fn error ->
      case {error_field(error, :advised_reset_at), error_field(error, :advised_retry_seconds)} do
        {reset_at, seconds} when is_binary(reset_at) and is_integer(seconds) -> {reset_at, seconds}
        _none -> nil
      end
    end)
  end

  def advised_reset(_errors), do: nil

  @doc "The advised reset as the drawer shows it, or `nil`."
  @spec format_advised_reset([map()] | nil, map()) :: String.t() | nil
  def format_advised_reset(errors, datetime_preferences) do
    case advised_reset(errors) do
      {reset_at, seconds} -> "#{format_reset_at(reset_at, datetime_preferences)} (Retry-After #{seconds} s)"
      nil -> nil
    end
  end

  defp advised_reset_at(errors) do
    case advised_reset(errors) do
      {reset_at, _seconds} -> reset_at
      nil -> nil
    end
  end

  defp error_field(error, key) when is_map(error), do: Map.get(error, key) || Map.get(error, Atom.to_string(key))
  defp error_field(_error, _key), do: nil

  defp reset_display_items(nil, _datetime_preferences), do: []

  defp reset_display_items(reset_at, datetime_preferences),
    do: ["resets #{format_reset_at(reset_at, datetime_preferences)}"]

  defp exhausted_reset_at(errors) do
    Enum.find_value(errors, fn error ->
      if quota_exhaustion_error?(error), do: error_reset_at(error)
    end)
  end

  defp quota_exhaustion_error?(%{code: code})
       when code in ["quota_exhausted", "quota_weekly_exhausted"],
       do: true

  defp quota_exhaustion_error?(%{"code" => code})
       when code in ["quota_exhausted", "quota_weekly_exhausted"],
       do: true

  defp quota_exhaustion_error?(%{reason_codes: reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_error?(%{"reason_codes" => reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_error?(_error), do: false

  defp quota_evidence_unavailable?(%{code: "quota_evidence_unavailable"}), do: true
  defp quota_evidence_unavailable?(%{"code" => "quota_evidence_unavailable"}), do: true
  defp quota_evidence_unavailable?(_error), do: false

  defp error_reset_at(%{reset_at: reset_at}), do: reset_at
  defp error_reset_at(%{"reset_at" => reset_at}), do: reset_at
  defp error_reset_at(_error), do: nil

  defp format_reset_at(%DateTime{} = reset_at, datetime_preferences),
    do: DateTimeDisplay.format_datetime(reset_at, datetime_preferences)

  defp format_reset_at(reset_at, datetime_preferences) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, datetime, _offset} -> format_reset_at(datetime, datetime_preferences)
      {:error, _reason} -> reset_at
    end
  end

  defp format_reset_at(reset_at, _datetime_preferences), do: to_string(reset_at)

  defp format_single_error(%{code: code}) when is_binary(code) and code != "",
    do: code

  defp format_single_error(%{"code" => code}) when is_binary(code) and code != "",
    do: code

  defp format_single_error(%{source: source, kind: kind})
       when is_binary(source) and is_binary(kind),
       do: "#{source}:#{kind}"

  defp format_single_error(%{"source" => source, "kind" => kind})
       when is_binary(source) and is_binary(kind),
       do: "#{source}:#{kind}"

  defp format_single_error(%{}), do: "error"
  defp format_single_error(_other), do: "error"
end
