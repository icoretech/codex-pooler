defmodule CodexPoolerWeb.Admin.JobFilterForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  @state_options ~w(available scheduled executing retryable completed discarded cancelled suspended)
  @attention_options ~w(active_failure retry_pressure stuck_executing backlog_pressure cancelled healthy_context executing available scheduled suspended unknown_state)
  @target_kind_options ~w(assignment upstream_identity pool api_key rollup_date system)
  @uuid_target_kinds ~w(assignment upstream_identity pool api_key)
  @filter_keys ~w(state worker attention target_kind target_id page show_completed job_id)
  @safe_worker_pattern ~r/\A[A-Za-z0-9_.]+\z/

  @type filter_error :: %{required(:field) => atom(), required(:message) => String.t()}
  @type filters :: %{
          required(:state) => String.t() | nil,
          required(:worker) => String.t() | nil,
          required(:attention) => String.t() | nil,
          required(:target_kind) => String.t() | nil,
          required(:target_id) => String.t() | nil,
          required(:page) => pos_integer(),
          required(:show_completed) => boolean(),
          required(:job_id) => pos_integer() | nil
        }
  @type form_values :: %{String.t() => String.t()}
  @type option :: %{
          required(:label) => String.t(),
          required(:value) => String.t(),
          required(:icon) => String.t()
        }

  @spec parse_filters(map()) :: {filters(), form_values(), [filter_error()]}
  def parse_filters(params) when is_map(params) do
    raw_values = raw_form_values(params)
    {show_completed?, show_completed_error} = parse_show_completed(raw_values["show_completed"])
    {state, state_error} = parse_state(raw_values["state"], show_completed?)
    {worker, worker_error} = parse_safe_text(raw_values["worker"], :worker, @safe_worker_pattern)
    {attention, attention_error} = parse_attention(raw_values["attention"])
    {target_kind, target_id, target_errors} = parse_target(raw_values)
    {page, page_error} = parse_positive_integer(raw_values["page"], :page, default: 1)
    {job_id, job_id_error} = parse_positive_integer(raw_values["job_id"], :job_id)

    filters = %{
      state: state,
      worker: worker,
      attention: attention,
      target_kind: target_kind,
      target_id: target_id,
      page: page,
      show_completed: show_completed?,
      job_id: job_id
    }

    errors =
      [
        show_completed_error,
        state_error,
        worker_error,
        attention_error,
        page_error,
        job_id_error
        | target_errors
      ]
      |> Enum.reject(&is_nil/1)

    {filters, form_values(raw_values, filters), errors}
  end

  @spec query_params(map()) :: map()
  def query_params(params) when is_map(params) do
    {filters, _form_values, _errors} = parse_filters(params)

    %{}
    |> maybe_put_param("state", filters.state)
    |> maybe_put_param("worker", filters.worker)
    |> maybe_put_param("attention", filters.attention)
    |> maybe_put_param("target_kind", filters.target_kind)
    |> maybe_put_param("target_id", filters.target_id)
    |> maybe_put_page(filters.page)
    |> maybe_put_show_completed(filters.show_completed)
    |> maybe_put_job_id(filters.job_id)
  end

  @spec open_job_query_params(map(), pos_integer() | String.t()) :: map()
  def open_job_query_params(params, job_id) when is_map(params) do
    query_params(params)
    |> Map.delete("job_id")
    |> maybe_put_job_id(normalized_positive_integer(job_id))
  end

  @spec close_job_query_params(map()) :: map()
  def close_job_query_params(params) when is_map(params) do
    params
    |> query_params()
    |> Map.delete("job_id")
  end

  @spec filter_form(form_values(), [filter_error()]) :: Phoenix.HTML.Form.t()
  def filter_form(form_values, errors \\ []) do
    to_form(form_values, as: :filters, errors: form_errors(errors))
  end

  @spec form_errors([filter_error()]) :: keyword()
  def form_errors(errors), do: Enum.map(errors, &{&1.field, {&1.message, []}})

  @spec state_options() :: [option()]
  def state_options do
    any_state_option() ++ Enum.map(@state_options, &state_option/1)
  end

  @spec attention_options() :: [option()]
  def attention_options do
    [any_attention_option() | Enum.map(@attention_options, &attention_option/1)]
  end

  @spec target_kind_options() :: [option()]
  def target_kind_options do
    Enum.map(@target_kind_options, &target_kind_option/1)
  end

  @spec worker_options([String.t()], String.t() | nil) :: [option()]
  def worker_options(workers, selected_worker \\ nil) do
    options =
      workers
      |> dynamic_options(selected_worker, "hero-cube")
      |> Enum.map(&%{&1 | label: worker_option_label(&1.label)})

    [any_worker_option() | options]
  end

  # Every worker shares the CodexPooler.Jobs. namespace, so printing it in the
  # option list costs width without telling the operator anything. The value
  # keeps the full module, which is what the filter matches on.
  defp worker_option_label(worker), do: String.replace_prefix(worker, "CodexPooler.Jobs.", "")

  @spec selected_state_option(String.t() | nil) :: option()
  def selected_state_option(state),
    do: selected_option(state_options(), state, hd(state_options()))

  @spec selected_attention_option(String.t() | nil) :: option()
  def selected_attention_option(attention),
    do: selected_option(attention_options(), attention, hd(attention_options()))

  @spec selected_target_kind_option(String.t() | nil) :: option() | nil
  def selected_target_kind_option(target_kind),
    do: selected_option(target_kind_options(), target_kind, nil)

  @spec selected_worker_option([option()], String.t() | nil) :: option()
  def selected_worker_option(options, worker),
    do: selected_option(options, worker, any_worker_option())

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value), do: String.trim(to_string(value)) == ""

  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))

  defp raw_form_values(params) do
    Map.new(@filter_keys, fn key -> {key, string_param(params, key) || ""} end)
  end

  defp form_values(raw_values, filters) do
    %{
      "state" => filters.state || raw_values["state"],
      "worker" => filters.worker || raw_values["worker"],
      "attention" => filters.attention || raw_values["attention"],
      "target_kind" => filters.target_kind || raw_values["target_kind"],
      "target_id" => filters.target_id || raw_values["target_id"],
      "page" => Integer.to_string(filters.page),
      "show_completed" => if(filters.show_completed, do: "true", else: "false"),
      "job_id" =>
        if(filters.job_id, do: Integer.to_string(filters.job_id), else: raw_values["job_id"])
    }
  end

  defp parse_show_completed(value) do
    cond do
      blank?(value) -> {false, nil}
      truthy?(value) -> {true, nil}
      falsey?(value) -> {false, nil}
      true -> {false, %{field: :show_completed, message: "Show completed must be true or false"}}
    end
  end

  defp parse_state(nil, _show_completed?), do: {nil, nil}
  defp parse_state("", _show_completed?), do: {nil, nil}

  defp parse_state("completed", false),
    do: {nil, %{field: :state, message: "Completed jobs require show_completed=true"}}

  defp parse_state(state, _show_completed?) do
    if state in @state_options do
      {state, nil}
    else
      {nil, %{field: :state, message: "State filter is not supported"}}
    end
  end

  defp parse_safe_text(nil, _field, _pattern), do: {nil, nil}
  defp parse_safe_text("", _field, _pattern), do: {nil, nil}

  defp parse_safe_text(value, field, pattern) do
    if Regex.match?(pattern, value) do
      {value, nil}
    else
      {nil, %{field: field, message: safe_text_message(field)}}
    end
  end

  defp parse_attention(nil), do: {nil, nil}
  defp parse_attention(""), do: {nil, nil}

  defp parse_attention(attention) do
    if attention in @attention_options do
      {attention, nil}
    else
      {nil, %{field: :attention, message: "Attention filter is not supported"}}
    end
  end

  defp parse_target(%{"target_kind" => "", "target_id" => ""}), do: {nil, nil, []}

  defp parse_target(%{"target_kind" => "", "target_id" => target_id}) when target_id != "" do
    {nil, nil,
     [%{field: :target_kind, message: "Target kind is required when target id is present"}]}
  end

  defp parse_target(%{"target_kind" => target_kind, "target_id" => target_id}) do
    cond do
      target_kind not in @target_kind_options ->
        {nil, nil, [%{field: :target_kind, message: "Target kind filter is not supported"}]}

      target_kind in @uuid_target_kinds ->
        parse_uuid_target(target_kind, target_id)

      target_kind == "rollup_date" ->
        parse_rollup_date_target(target_id)

      target_kind == "system" ->
        parse_system_target(target_id)
    end
  end

  defp parse_uuid_target(_target_kind, "") do
    {nil, nil,
     [%{field: :target_id, message: "Target id is required for the selected target kind"}]}
  end

  defp parse_uuid_target(target_kind, target_id) do
    case Ecto.UUID.cast(target_id) do
      {:ok, uuid} ->
        {target_kind, uuid, []}

      :error ->
        {nil, nil,
         [
           %{
             field: :target_id,
             message: "Target id must be a valid UUID for the selected target kind"
           }
         ]}
    end
  end

  defp parse_rollup_date_target("") do
    {nil, nil,
     [%{field: :target_id, message: "Target id is required for the selected target kind"}]}
  end

  defp parse_rollup_date_target(target_id) do
    case Date.from_iso8601(target_id) do
      {:ok, date} ->
        {"rollup_date", Date.to_iso8601(date), []}

      {:error, _reason} ->
        {nil, nil,
         [%{field: :target_id, message: "Target id must be a valid ISO date for rollup_date"}]}
    end
  end

  defp parse_system_target(""), do: {"system", nil, []}

  defp parse_system_target(_target_id) do
    {nil, nil, [%{field: :target_id, message: "Target id must be blank for system jobs"}]}
  end

  defp parse_positive_integer(value, field, opts \\ [])
  defp parse_positive_integer(nil, _field, opts), do: {Keyword.get(opts, :default), nil}
  defp parse_positive_integer("", _field, opts), do: {Keyword.get(opts, :default), nil}

  defp parse_positive_integer(value, field, opts) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> {integer, nil}
      _other -> {Keyword.get(opts, :default), positive_integer_error(field)}
    end
  end

  defp normalized_positive_integer(value) do
    case parse_positive_integer(value, :job_id) do
      {integer, nil} -> integer
      _invalid -> nil
    end
  end

  defp positive_integer_error(:page),
    do: %{field: :page, message: "Page must be a positive integer"}

  defp positive_integer_error(:job_id),
    do: %{field: :job_id, message: "Job id must be a positive integer"}

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp maybe_put_page(params, page) when page in [nil, 1], do: params
  defp maybe_put_page(params, page), do: Map.put(params, "page", Integer.to_string(page))

  defp maybe_put_show_completed(params, true), do: Map.put(params, "show_completed", "true")
  defp maybe_put_show_completed(params, _show_completed?), do: params

  defp maybe_put_job_id(params, nil), do: params
  defp maybe_put_job_id(params, job_id), do: Map.put(params, "job_id", Integer.to_string(job_id))

  defp dynamic_options(values, selected_value, icon) do
    values
    |> List.wrap()
    |> Kernel.++(List.wrap(blank_to_nil(selected_value)))
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.map(&%{label: &1, value: &1, icon: icon})
  end

  defp selected_option(options, selected_value, fallback) do
    Enum.find(options, &(&1.value == selected_value)) || fallback
  end

  defp any_state_option, do: [%{label: "Any state", value: "", icon: "hero-queue-list"}]
  defp any_attention_option, do: %{label: "Any attention", value: "", icon: "hero-sparkles"}
  defp any_worker_option, do: %{label: "Any worker", value: "", icon: "hero-cube"}

  defp state_option(state), do: %{label: humanize(state), value: state, icon: "hero-queue-list"}

  defp attention_option(attention),
    do: %{label: humanize(attention), value: attention, icon: "hero-exclamation-triangle"}

  defp target_kind_option(kind),
    do: %{label: humanize(kind), value: kind, icon: target_kind_icon(kind)}

  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp target_kind_icon("assignment"), do: "hero-link"
  defp target_kind_icon("upstream_identity"), do: "hero-cloud-arrow-up"
  defp target_kind_icon("pool"), do: "hero-squares-2x2"
  defp target_kind_icon("api_key"), do: "hero-key"
  defp target_kind_icon("rollup_date"), do: "hero-calendar-days"
  defp target_kind_icon("system"), do: "hero-cog-6-tooth"

  defp safe_text_message(:worker), do: "Worker filter contains unsupported characters"

  defp truthy?(true), do: true
  defp truthy?(value) when is_binary(value), do: value in ["true", "1", "on", "yes"]
  defp truthy?(_value), do: false

  defp falsey?(false), do: true
  defp falsey?(value) when is_binary(value), do: value in ["false", "0", "off", "no"]
  defp falsey?(_value), do: false

  defp string_param(params, key), do: params |> Map.get(key) |> blank_to_nil()
end
