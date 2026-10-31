defmodule CodexPoolerWeb.Admin.UpstreamAuthJsonImport do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [to_form: 2, upload_errors: 1, upload_errors: 2]

  @upload_limit_bytes 64_000
  @upload_limit_label "64 KB"

  @type content_source ::
          {:ok, {:paste, String.t()}}
          | {:ok, :upload}
          | {:error, String.t(), :cancel_uploads | :keep_uploads}

  @spec upload_limit_bytes() :: pos_integer()
  def upload_limit_bytes, do: @upload_limit_bytes

  @spec upload_limit_label() :: String.t()
  def upload_limit_label, do: @upload_limit_label

  @spec empty_form() :: Phoenix.HTML.Form.t()
  def empty_form do
    to_form(%{"content" => "", "pool_id" => ""}, as: :auth_json)
  end

  @spec form_for_pool(String.t() | nil) :: Phoenix.HTML.Form.t()
  def form_for_pool(pool_id) do
    to_form(%{"content" => "", "pool_id" => pool_id || ""}, as: :auth_json)
  end

  @spec form_with_error(String.t() | nil, atom(), String.t()) :: Phoenix.HTML.Form.t()
  def form_with_error(pool_id, field, message) do
    data = %{content: "", pool_id: pool_id || ""}

    {%{}, %{content: :string, pool_id: :string}}
    |> Ecto.Changeset.cast(data, Map.keys(data))
    |> Map.put(:action, :insert)
    |> Ecto.Changeset.add_error(field, message)
    |> to_form(as: :auth_json)
  end

  @spec content_present?(map()) :: boolean()
  def content_present?(params) when is_map(params), do: present_string(params["content"]) != nil
  def content_present?(_params), do: false

  @spec content_source(map(), [term()], [term()], [String.t()]) :: content_source()
  def content_source(params, completed_upload_entries, in_progress_upload_entries, upload_errors)
      when is_map(params) do
    paste_content = present_string(params["content"])

    classify_content_source(
      paste_content,
      completed_upload_entries,
      in_progress_upload_entries,
      upload_errors
    )
  end

  defp classify_content_source(
         paste_content,
         _completed_upload_entries,
         _in_progress_upload_entries,
         _upload_errors
       )
       when is_binary(paste_content) and byte_size(paste_content) > @upload_limit_bytes do
    {:error, gettext("Pasted JSON must be %{limit} or smaller", limit: @upload_limit_label), :cancel_uploads}
  end

  defp classify_content_source(
         _paste_content,
         _completed_upload_entries,
         _in_progress_upload_entries,
         upload_errors
       )
       when upload_errors != [] do
    {:error, Enum.join(upload_errors, ", "), :cancel_uploads}
  end

  defp classify_content_source(
         paste_content,
         completed_upload_entries,
         in_progress_upload_entries,
         _upload_errors
       )
       when is_binary(paste_content) and
              (completed_upload_entries != [] or in_progress_upload_entries != []) do
    {:error, gettext("Use either pasted JSON or one uploaded file, not both"), :cancel_uploads}
  end

  defp classify_content_source(
         paste_content,
         _completed_upload_entries,
         _in_progress_upload_entries,
         _upload_errors
       )
       when is_binary(paste_content) do
    {:ok, {:paste, paste_content}}
  end

  defp classify_content_source(
         _paste_content,
         completed_upload_entries,
         in_progress_upload_entries,
         []
       ) do
    select_upload_source(completed_upload_entries, in_progress_upload_entries)
  end

  defp select_upload_source(_completed_upload_entries, in_progress_upload_entries)
       when in_progress_upload_entries != [] do
    {:error, gettext("Upload is still in progress; wait for it to finish before importing"), :keep_uploads}
  end

  defp select_upload_source(completed_upload_entries, _in_progress_upload_entries)
       when completed_upload_entries != [] do
    {:ok, :upload}
  end

  defp select_upload_source(_completed_upload_entries, _in_progress_upload_entries) do
    {:error, gettext("Paste auth.json or upload one .json file"), :keep_uploads}
  end

  @spec upload_error_messages(Phoenix.LiveView.UploadConfig.t()) :: [String.t()]
  def upload_error_messages(conf) do
    entry_errors =
      conf.entries
      |> Enum.flat_map(&upload_errors(conf, &1))

    (upload_errors(conf) ++ entry_errors)
    |> Enum.uniq()
    |> Enum.map(&upload_error_message/1)
  end

  @spec read_upload(Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_upload(path), do: File.read(path)

  defp upload_error_message(:too_large), do: gettext("File must be %{limit} or smaller", limit: @upload_limit_label)
  defp upload_error_message(:too_many_files), do: gettext("Upload one .json file")
  defp upload_error_message(:not_accepted), do: gettext("Upload a .json file")
  defp upload_error_message(_error), do: gettext("Uploaded file is invalid")

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil
end
