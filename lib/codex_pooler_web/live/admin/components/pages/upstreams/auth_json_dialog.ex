defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AuthJsonDialog do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :auth_json_form, :any, required: true
  attr :importing_auth_json, :boolean, required: true
  attr :pool_options, :list, required: true
  attr :upload, :map, required: true
  attr :upload_limit_label, :string, required: true

  def auth_json_import_dialog(assigns) do
    ~H"""
    <dialog :if={@importing_auth_json} id="auth-json-import-dialog" class="modal" open>
      <div class="modal-box max-w-5xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Upstream credentials
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Import auth.json</h2>
          <p class="mt-2 w-full text-sm leading-6 text-base-content/70">
            Import a Codex CLI or Codex Desktop auth.json into encrypted upstream storage.
          </p>
        </div>

        <.form
          id="auth-json-import-form"
          for={@auth_json_form}
          phx-change="validate_auth_json_import"
          phx-submit="import_auth_json"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input
            field={@auth_json_form[:pool_id]}
            type="select"
            label="Target Pool"
            options={@pool_options}
          />

          <div
            :if={auth_json_form_error_messages(@auth_json_form) != []}
            id="auth-json-import-errors"
            class="rounded-box border border-error/30 bg-error/10 p-3 text-sm text-error"
          >
            <p :for={message <- auth_json_form_error_messages(@auth_json_form)}>{message}</p>
          </div>

          <div class="grid items-stretch gap-4 lg:grid-cols-2">
            <section
              id="auth-json-import-paste-panel"
              class="grid gap-3 rounded-box border border-base-300 bg-base-100 p-4"
            >
              <div>
                <h3 class="font-semibold text-base-content">Paste contents</h3>
                <p class="mt-1 text-sm leading-6 text-base-content/65">
                  Use this when the file is already open.
                </p>
              </div>
              <.input
                field={@auth_json_form[:content]}
                type="textarea"
                label="File contents"
                placeholder="Paste auth.json contents"
                value=""
              />
            </section>

            <section
              id="auth-json-import-file-dropzone"
              phx-drop-target={@upload.ref}
              class="grid gap-3 rounded-box border border-dashed border-base-300 bg-base-200/40 p-4"
            >
              <div class="grid h-full min-h-40 place-items-center gap-3 rounded-box bg-base-100 p-5 text-center">
                <.icon name="hero-document-arrow-up" class="size-7 text-base-content/45" />
                <div class="grid gap-0.5">
                  <h3 class="font-semibold text-base-content">Drop auth.json</h3>
                  <p class="text-sm leading-6 text-base-content/65">
                    Upload auth.json up to {@upload_limit_label}.
                  </p>
                </div>
                <label for={@upload.ref} class="btn btn-neutral btn-sm cursor-pointer gap-2">
                  <.icon name="hero-folder-open" class="size-4" />
                  <span>Choose file</span>
                </label>
                <span id="auth-json-import-file-input" class="sr-only">
                  <.live_file_input upload={@upload} />
                </span>
              </div>

              <div class="grid gap-3">
                <article
                  :for={entry <- @upload.entries}
                  id={"auth-json-import-upload-#{entry.ref}"}
                  class="rounded-box border border-base-300 bg-base-100 p-3"
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="min-w-0">
                      <p class="font-semibold text-base-content">auth.json selected</p>
                      <p class="text-xs text-base-content/60">{entry.progress}% uploaded</p>
                    </div>
                    <button
                      id={"auth-json-import-upload-cancel-#{entry.ref}"}
                      type="button"
                      class="btn btn-ghost btn-sm btn-square"
                      phx-click="cancel_auth_json_upload"
                      phx-value-ref={entry.ref}
                      aria-label="Remove selected auth.json file"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                  <progress
                    class="progress progress-primary mt-3 h-1.5 w-full"
                    value={entry.progress}
                    max="100"
                  >
                    {entry.progress}%
                  </progress>
                  <p
                    :for={message <- auth_json_upload_error_messages(@upload, entry)}
                    class="mt-2 text-xs text-error"
                  >
                    {message}
                  </p>
                </article>

                <p
                  :for={message <- auth_json_upload_error_messages(@upload)}
                  class="rounded-box border border-error/30 bg-error/10 p-3 text-sm text-error"
                >
                  {message}
                </p>
              </div>
            </section>
          </div>

          <AdminComponents.extended_notice
            id="auth-json-import-refresh-token-warning"
            icon="hero-exclamation-triangle"
            tone={:warning}
            title="Codex Pooler becomes the refresh-token authority."
            description="This is a credential lineage handoff: Do not keep using the same auth.json from another Codex install, machine, or automation, because provider refresh-token rotation can invalidate one copy and move the account to reauth_required. Personal access token auth.json entries are not supported in this cycle; import ChatGPT token auth.json only."
          />
        </.form>

        <AdminComponents.dialog_footer id="auth-json-import-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="auth-json-import-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_import_auth_json"
            />
            <AdminComponents.action_button
              id="auth-json-import-submit"
              icon="hero-document-arrow-up"
              label="Import auth.json"
              type="submit"
              form="auth-json-import-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_import_auth_json">close</button>
      </form>
    </dialog>
    """
  end

  defp auth_json_form_error_messages(form) do
    form.errors
    |> Enum.map(fn
      {_field, {message, _opts}} -> message
      {_field, message} when is_binary(message) -> message
    end)
    |> Enum.uniq()
  end

  defp auth_json_upload_error_messages(upload) do
    upload
    |> Phoenix.Component.upload_errors()
    |> Enum.map(&auth_json_upload_error_message/1)
  end

  defp auth_json_upload_error_messages(upload, entry) do
    upload
    |> Phoenix.Component.upload_errors(entry)
    |> Enum.map(&auth_json_upload_error_message/1)
  end

  defp auth_json_upload_error_message(:too_large), do: "File must be 64 KB or smaller"
  defp auth_json_upload_error_message(:too_many_files), do: "Upload one auth.json file"
  defp auth_json_upload_error_message(:not_accepted), do: "Upload auth.json as a .json file"
  defp auth_json_upload_error_message(_error), do: "Uploaded file is invalid"
end
