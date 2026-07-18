defmodule CodexPoolerWeb.Observatory.Components.Section do
  @moduledoc false

  use Phoenix.Component

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :suffix, :string, default: nil

  @doc """
  A section heading rendered as a centred label flanked by hairlines, used to
  separate the cardless activity panels and the model distribution. An optional
  suffix (e.g. the selected time window) trails the label in a muted tone.
  """
  def divider(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <span class="h-px flex-1 bg-base-300/70" aria-hidden="true"></span>
      <h2 id={@id} class="text-xs font-semibold uppercase tracking-widest text-base-content/65">
        {@label}<span :if={@suffix} class="ml-1.5 font-normal text-base-content/40">{@suffix}</span>
      </h2>
      <span class="h-px flex-1 bg-base-300/70" aria-hidden="true"></span>
    </div>
    """
  end
end
