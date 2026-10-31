defmodule CodexPoolerWeb.Admin.RequestLogFilterForm do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPoolerWeb.DateTimeInput

  @status_options ~w(accepted in_progress succeeded failed client_cancelled rejected)
  @filter_keys ~w(pool_id status upstream_identity_id model date_from date_to request_id)

  @type filter_error :: %{required(:field) => atom(), required(:message) => String.t()}
  @type parsed_filters :: [{atom(), term()}]

  @spec query_params(map()) :: map()
  def query_params(filter_params) do
    filter_params
    |> Map.take(@filter_keys)
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  @spec parse_filters(map(), term(), MapSet.t(String.t()), String.t()) ::
          {parsed_filters(), map(), [filter_error()]}
  def parse_filters(params, selected_pool, visible_upstream_identity_ids, timezone \\ "Etc/UTC") do
    form_values = form_values(params, selected_pool)
    {status, status_error} = parse_status(form_values["status"])

    {upstream_id, upstream_error} =
      parse_upstream_identity(
        form_values["upstream_identity_id"],
        visible_upstream_identity_ids
      )

    {date_from, date_from_error} = parse_date(form_values["date_from"], :date_from, timezone)
    {date_to, date_to_error} = parse_date(form_values["date_to"], :date_to, timezone)

    filters =
      (status_filters(status) ++
         [
           upstream_identity_id: upstream_id,
           model: blank_to_nil(form_values["model"]),
           request_id: blank_to_nil(form_values["request_id"]),
           date_from: date_from,
           date_to: date_to
         ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    errors =
      Enum.reject(
        [status_error, upstream_error, date_from_error, date_to_error],
        &is_nil/1
      )

    {filters, form_values, errors}
  end

  @spec select_pool([term()], term()) :: {term() | nil, filter_error() | nil}
  def select_pool([], pool_id) do
    if blank?(pool_id) do
      {nil, nil}
    else
      {nil, %{field: :pool_id, message: gettext("Pool filter did not match an available Pool")}}
    end
  end

  def select_pool(pools, pool_id) do
    cond do
      blank?(pool_id) ->
        {nil, nil}

      pool = Enum.find(pools, &(&1.id == pool_id)) ->
        {pool, nil}

      true ->
        {nil, %{field: :pool_id, message: gettext("Pool filter did not match an available Pool")}}
    end
  end

  @spec form_errors([filter_error()]) :: keyword()
  def form_errors(errors), do: Enum.map(errors, &{&1.field, {&1.message, []}})

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_value), do: true

  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))

  defp form_values(params, selected_pool) do
    %{
      "pool_id" => (selected_pool && selected_pool.id) || string_param(params, "pool_id"),
      "status" => string_param(params, "status"),
      "upstream_identity_id" => string_param(params, "upstream_identity_id"),
      "model" => string_param(params, "model"),
      "date_from" => string_param(params, "date_from"),
      "date_to" => string_param(params, "date_to"),
      "request_id" => string_param(params, "request_id")
    }
  end

  # The status filter selects rows by the status they show. `failed` leaves out
  # the client cancellations (`RequestOutcome`), which have their own
  # `client_cancelled` option; "Any status" lists both.
  defp status_filters(nil), do: []
  defp status_filters("failed"), do: [status: "failed", client_cancelled: false]
  defp status_filters("client_cancelled"), do: [client_cancelled: true]
  defp status_filters(status), do: [status: status]

  defp parse_status(nil), do: {nil, nil}

  defp parse_status(status) do
    if status in @status_options do
      {status, nil}
    else
      {nil, %{field: :status, message: gettext("Status filter is not supported")}}
    end
  end

  defp parse_upstream_identity(nil, _visible_upstream_identity_ids), do: {nil, nil}

  defp parse_upstream_identity(upstream_identity_id, visible_upstream_identity_ids) do
    if MapSet.member?(visible_upstream_identity_ids, upstream_identity_id) do
      {upstream_identity_id, nil}
    else
      {nil,
       %{
         field: :upstream_identity_id,
         message: gettext("Upstream account filter did not match a visible upstream account")
       }}
    end
  end

  defp parse_date(nil, _field, _timezone), do: {nil, nil}

  defp parse_date(value, field, timezone) do
    case DateTimeInput.date_boundary(value, field, timezone) do
      {:ok, datetime} ->
        {datetime, nil}

      {:error, :gap} ->
        {nil, %{field: field, message: gettext("%{date} does not exist in the selected timezone", date: date_label(field))}}

      {:error, :unknown_timezone} ->
        {nil, %{field: field, message: gettext("%{date} timezone is unavailable; update your timezone in Settings", date: date_label(field))}}

      {:error, _reason} ->
        {nil, %{field: field, message: gettext("%{date} must be a valid date", date: date_label(field))}}
    end
  end

  defp date_label(:date_from), do: gettext("Date from")
  defp date_label(:date_to), do: gettext("Date to")

  defp string_param(params, key), do: params |> Map.get(key) |> blank_to_nil()
end
