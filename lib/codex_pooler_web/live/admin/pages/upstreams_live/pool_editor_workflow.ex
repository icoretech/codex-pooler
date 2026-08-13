defmodule CodexPoolerWeb.Admin.UpstreamsLive.PoolEditorWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, start_async: 3]

  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Catalog
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolWizardComponents

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec initial_assigns() :: map()
  def initial_assigns do
    %{
      editing_pool: nil,
      pool_edit_form: nil,
      pool_editor_step: "details",
      pool_editor_upstream_options: [],
      pool_editor_api_key_options: [],
      pool_editor_warnings: [],
      pool_model_serving_form: nil,
      pool_model_serving_snapshot: nil,
      pool_model_serving_models: [],
      pool_model_serving_status: :idle,
      pool_model_serving_dirty?: false,
      pool_model_serving_sync_pending?: false,
      pool_model_serving_pending_attrs: nil,
      pool_model_serving_load_token: nil
    }
  end

  @spec find_editable_pool(term(), term()) :: {:ok, map()} | {:error, term()}
  def find_editable_pool(scope, pool_id) when is_binary(pool_id) do
    with true <- Pools.can_manage_pools?(scope),
         {:ok, pools} <- Pools.list_pools_for_management(scope),
         %{} = pool <- Enum.find(pools, &(&1.id == pool_id)),
         {:ok, _decision} <-
           Pools.require_capability(scope, Pools.capability(:pool_manage), pool_id: pool.id) do
      {:ok, pool}
    else
      false -> {:error, %{message: "Pool management is not available for this session"}}
      nil -> {:error, %{message: "Pool was not found"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def find_editable_pool(_scope, _pool_id), do: {:error, %{message: "Pool was not found"}}

  @spec open(socket(), map(), term()) :: socket()
  def open(socket, pool, step) do
    step = PoolWizardComponents.normalize_step(step, :edit)

    if match?(%{id: pool_id} when pool_id == pool.id, socket.assigns.editing_pool) do
      socket = assign(socket, :pool_editor_step, step)

      if connected?(socket) && socket.assigns.pool_model_serving_status == :idle do
        begin_model_serving_load(socket, pool)
      else
        socket
      end
    else
      {upstream_options, upstream_warnings} =
        PoolForm.load_upstream_identity_options(socket.assigns.current_scope, true)

      {api_key_options, api_key_warnings} =
        PoolForm.load_api_key_options(socket.assigns.current_scope, true)

      socket
      |> close()
      |> assign(
        editing_pool: pool,
        pool_edit_form: PoolForm.edit_form(pool),
        pool_editor_step: step,
        pool_editor_upstream_options:
          PoolForm.edit_upstream_identity_options(pool, upstream_options),
        pool_editor_api_key_options: api_key_options,
        pool_editor_warnings: upstream_warnings ++ api_key_warnings
      )
      |> maybe_begin_model_serving_load(pool)
    end
  end

  @spec close(socket()) :: socket()
  def close(socket), do: assign(socket, initial_assigns())

  @spec save(socket(), map(), (socket(), map() -> socket())) :: socket()
  def save(socket, pool_params, reload_fun) do
    pool_id = pool_params["id"]

    with %{} = editing_pool <- socket.assigns.editing_pool,
         true <- editing_pool.id == pool_id,
         {:ok, pool} <-
           PoolWorkflow.update_pool_with_related_settings(
             socket.assigns.current_scope,
             pool_id,
             pool_params
           ) do
      socket
      |> put_flash(:info, "Pool updated")
      |> assign(editing_pool: pool, pool_edit_form: PoolForm.edit_form(pool))
      |> reload_fun.(pool)
    else
      nil ->
        put_flash(socket, :error, "Pool was not found")

      false ->
        put_flash(socket, :error, "Pool was not found")

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> put_flash(:error, error_message(changeset))
        |> assign(
          :pool_edit_form,
          PoolForm.edit_form(
            socket.assigns.editing_pool,
            pool_params,
            PoolForm.changeset_errors(changeset)
          )
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, error_message(reason))
        |> assign(
          :pool_edit_form,
          PoolForm.edit_form(socket.assigns.editing_pool, pool_params)
        )
    end
  end

  @spec validate_model_serving(socket(), map()) :: socket()
  def validate_model_serving(socket, attrs) do
    if socket.assigns.editing_pool && socket.assigns.pool_model_serving_snapshot do
      socket
      |> assign(
        :pool_model_serving_form,
        PoolForm.model_serving_form(
          socket.assigns.pool_model_serving_snapshot,
          socket.assigns.pool_model_serving_models,
          attrs
        )
      )
      |> assign(
        pool_model_serving_dirty?: true,
        pool_model_serving_pending_attrs: attrs
      )
    else
      socket
    end
  end

  @spec save_model_serving(socket(), map()) :: socket()
  def save_model_serving(socket, attrs) do
    submission = PoolForm.model_serving_submission(attrs)
    pool = socket.assigns.editing_pool

    with %{} <- pool,
         {:ok, _decision} <-
           Pools.require_capability(
             socket.assigns.current_scope,
             Pools.capability(:pool_manage),
             pool_id: pool.id
           ),
         {:ok, _result} <-
           Pools.update_model_serving_modes(
             socket.assigns.current_scope,
             pool,
             submission.rows,
             submission.revision
           ) do
      socket
      |> put_flash(:info, "Model serving modes updated")
      |> assign(pool_editor_step: "models", pool_model_serving_dirty?: false)
      |> begin_model_serving_load(pool, reset?: false)
    else
      nil ->
        put_flash(socket, :error, "Pool was not found")

      {:error, reason} ->
        socket = put_flash(socket, :error, error_message(reason))

        if match?(%{code: :stale_revision}, reason) do
          socket
          |> assign(pool_editor_step: "models", pool_model_serving_dirty?: true)
          |> begin_model_serving_load(pool, reset?: false, pending_attrs: attrs)
        else
          socket
          |> reproject_model_serving_error(attrs)
          |> assign(
            pool_editor_step: "models",
            pool_model_serving_status: :error,
            pool_model_serving_dirty?: true,
            pool_model_serving_pending_attrs: attrs
          )
        end
    end
  end

  @spec handle_model_async(term(), term(), socket()) :: socket()
  def handle_model_async(
        {:pool_editor_model_serving, load_token, pool_id},
        {:ok, {:ok, data}},
        socket
      ) do
    if current_model_load?(socket, load_token, pool_id) do
      apply_model_serving_load(socket, data)
    else
      socket
    end
  end

  def handle_model_async(
        {:pool_editor_model_serving, load_token, pool_id},
        result,
        socket
      )
      when result in [{:ok, {:error, :load_failed}}, {:exit, :normal}] do
    if current_model_load?(socket, load_token, pool_id),
      do: model_serving_load_error(socket),
      else: socket
  end

  def handle_model_async(
        {:pool_editor_model_serving, load_token, pool_id},
        {:exit, _reason},
        socket
      ) do
    if current_model_load?(socket, load_token, pool_id),
      do: model_serving_load_error(socket),
      else: socket
  end

  defp maybe_begin_model_serving_load(socket, pool) do
    if connected?(socket), do: begin_model_serving_load(socket, pool), else: socket
  end

  defp begin_model_serving_load(socket, pool, opts \\ []) do
    reset? = Keyword.get(opts, :reset?, true)
    pending_attrs = Keyword.get(opts, :pending_attrs)
    load_token = make_ref()
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        pool_model_serving_status: :loading,
        pool_model_serving_sync_pending?: false,
        pool_model_serving_pending_attrs: pending_attrs,
        pool_model_serving_load_token: load_token
      )
      |> start_async({:pool_editor_model_serving, load_token, pool.id}, fn ->
        load_model_serving_data(scope, pool)
      end)

    if reset? do
      assign(socket,
        pool_model_serving_form: nil,
        pool_model_serving_snapshot: nil,
        pool_model_serving_models: [],
        pool_model_serving_dirty?: false
      )
    else
      socket
    end
  end

  defp load_model_serving_data(scope, pool) do
    case Pools.model_serving_modes_snapshot(scope, pool) do
      {:ok, snapshot} ->
        hydration = CandidateEligibility.hydrate_model_visibility(pool)

        models =
          for model <- hydration.visible_models,
              {:ok, candidates} <- [CandidateEligibility.routable_candidates(hydration, model)] do
            source_ids = Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
            {model, source_ids}
          end

        {:ok,
         %{
           snapshot: snapshot,
           models: models,
           catalog_state: Catalog.catalog_read_state(pool)
         }}

      {:error, _reason} ->
        {:error, :load_failed}
    end
  end

  defp current_model_load?(socket, load_token, pool_id) do
    socket.assigns.pool_model_serving_load_token == load_token &&
      match?(%{id: ^pool_id}, socket.assigns.editing_pool)
  end

  defp apply_model_serving_load(socket, data) do
    pending_attrs = socket.assigns.pool_model_serving_pending_attrs

    form =
      case pending_attrs do
        attrs when is_map(attrs) ->
          attrs = Map.put(attrs, "revision", data.snapshot.revision)
          PoolForm.model_serving_form(data.snapshot, data.models, attrs)

        nil ->
          PoolForm.model_serving_form(data.snapshot, data.models)
      end

    pending? = is_map(pending_attrs)

    assign(socket,
      pool_model_serving_form: form,
      pool_model_serving_snapshot: data.snapshot,
      pool_model_serving_models: data.models,
      pool_model_serving_status:
        if(pending?, do: :stale, else: model_serving_status(data.catalog_state, form.rows)),
      pool_model_serving_dirty?: pending?,
      pool_model_serving_sync_pending?: pending?,
      pool_model_serving_pending_attrs:
        if(pending?, do: Map.put(pending_attrs, "revision", data.snapshot.revision)),
      pool_model_serving_load_token: nil
    )
  end

  defp model_serving_load_error(socket) do
    assign(socket,
      pool_model_serving_form: nil,
      pool_model_serving_snapshot: nil,
      pool_model_serving_models: [],
      pool_model_serving_status: :error,
      pool_model_serving_dirty?: false,
      pool_model_serving_sync_pending?: false,
      pool_model_serving_pending_attrs: nil,
      pool_model_serving_load_token: nil
    )
  end

  defp reproject_model_serving_error(socket, attrs) do
    if socket.assigns.pool_model_serving_snapshot do
      assign(
        socket,
        :pool_model_serving_form,
        PoolForm.model_serving_form(
          socket.assigns.pool_model_serving_snapshot,
          socket.assigns.pool_model_serving_models,
          attrs
        )
      )
    else
      socket
    end
  end

  defp model_serving_status(%{status: :failed}, _rows), do: :error
  defp model_serving_status(_catalog_state, []), do: :empty

  defp model_serving_status(%{status: status}, _rows)
       when status in [:stale, :syncing, :unavailable],
       do: :stale

  defp model_serving_status(_catalog_state, _rows), do: :ready

  defp error_message(%Ecto.Changeset{} = changeset) do
    case PoolForm.changeset_errors(changeset) do
      [{_field, {message, _opts}} | _rest] -> message
      [{_field, message} | _rest] when is_binary(message) -> message
      _errors -> "Pool action failed"
    end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Pool action failed"
end
