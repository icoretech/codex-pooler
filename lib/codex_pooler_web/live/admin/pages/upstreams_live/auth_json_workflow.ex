defmodule CodexPoolerWeb.Admin.UpstreamsLive.AuthJsonWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [cancel_upload: 3, consume_uploaded_entries: 3, put_flash: 3, uploaded_entries: 2]

  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @spec form_for_open([map()], map()) :: Phoenix.HTML.Form.t()
  def form_for_open(pools, %{"pool-id" => pool_id}) do
    case selected_pool(pools, pool_id) do
      nil -> UpstreamAuthJsonImport.empty_form()
      _pool -> UpstreamAuthJsonImport.form_for_pool(pool_id)
    end
  end

  def form_for_open(_pools, _params), do: UpstreamAuthJsonImport.empty_form()

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> cancel_upload_entries()
    |> assign(
      importing_auth_json: false,
      auth_json_form: UpstreamAuthJsonImport.empty_form()
    )
  end

  @spec validate(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def validate(socket, auth_json_params) do
    if UpstreamAuthJsonImport.content_present?(auth_json_params) do
      socket
    else
      assign(
        socket,
        :auth_json_form,
        UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
      )
    end
  end

  @spec cancel_upload_entry(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def cancel_upload_entry(socket, ref), do: cancel_upload(socket, :auth_json, ref)

  @spec import(Phoenix.LiveView.Socket.t(), map(), map() | nil, (Phoenix.LiveView.Socket.t() ->
                                                                   Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def import(socket, auth_json_params, pool, reload_fun) when is_function(reload_fun, 1) do
    case content(socket, auth_json_params) do
      {:ok, content, socket} ->
        do_import(socket, pool, auth_json_params, content, reload_fun)

      {:error, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_with_error(auth_json_params["pool_id"], :content, message)
         )
         |> assign(:importing_auth_json, true)}
    end
  end

  @spec cancel_upload_entries(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cancel_upload_entries(socket) do
    Enum.reduce(socket.assigns.uploads.auth_json.entries, socket, fn entry, socket ->
      cancel_upload(socket, :auth_json, entry.ref)
    end)
  end

  defp do_import(socket, pool, auth_json_params, content, reload_fun) do
    case Upstreams.import_codex_auth_json(socket.assigns.current_scope, pool, content) do
      {:ok, %{status: :created}} ->
        {:noreply, import_success(socket, "Codex auth.json imported", reload_fun)}

      {:ok, %{status: :existing}} ->
        {:noreply,
         import_success(
           socket,
           "Codex auth.json matched an existing account; tokens updated",
           reload_fun
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(:importing_auth_json, true)
         |> assign(:auth_json_form, to_form(changeset, as: :auth_json))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, WorkflowError.message(reason))
         |> assign(:importing_auth_json, true)
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
         )}
    end
  end

  defp import_success(socket, message, reload_fun) do
    socket
    |> put_flash(:info, message)
    |> assign(:auth_json_form, UpstreamAuthJsonImport.empty_form())
    |> assign(:importing_auth_json, false)
    |> reload_fun.()
  end

  defp content(socket, auth_json_params) do
    {completed_upload_entries, in_progress_upload_entries} = uploaded_entries(socket, :auth_json)
    upload_errors = UpstreamAuthJsonImport.upload_error_messages(socket.assigns.uploads.auth_json)

    case UpstreamAuthJsonImport.content_source(
           auth_json_params,
           completed_upload_entries,
           in_progress_upload_entries,
           upload_errors
         ) do
      {:ok, {:paste, content}} ->
        {:ok, content, socket}

      {:ok, :upload} ->
        consume_upload(socket)

      {:error, message, :cancel_uploads} ->
        {:error, message, cancel_upload_entries(socket)}

      {:error, message, :keep_uploads} ->
        {:error, message, socket}
    end
  end

  defp consume_upload(socket) do
    case consume_uploaded_entries(socket, :auth_json, fn %{path: path}, _entry ->
           UpstreamAuthJsonImport.read_upload(path)
         end) do
      [content] when is_binary(content) ->
        if byte_size(content) <= UpstreamAuthJsonImport.upload_limit_bytes() do
          {:ok, content, socket}
        else
          {:error, "File must be #{UpstreamAuthJsonImport.upload_limit_label()} or smaller",
           socket}
        end

      [] ->
        {:error, "Paste auth.json or upload one .json file", socket}

      _entries ->
        {:error, "Uploaded auth.json could not be read", socket}
    end
  end

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil
end
