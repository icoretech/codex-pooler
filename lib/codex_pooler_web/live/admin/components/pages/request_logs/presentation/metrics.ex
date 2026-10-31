defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPoolerWeb.Admin.Format

  @model_colors ~w(--color-info --color-success --color-secondary --color-warning --color-neutral --color-base-content)

  @spec model_color(String.t()) :: String.t()
  def model_color(model), do: "var(#{Enum.at(@model_colors, :erlang.phash2(model, length(@model_colors)))})"

  @type segment :: %{key: :cached_input | :uncached_input | :output, label: String.t(), count: non_neg_integer()}
  @type composition :: %{segments: [segment()], title: String.t()}

  @spec token_composition(map() | nil) :: composition() | nil
  def token_composition(%{input_tokens: input, cached_input_tokens: cached, output_tokens: output, total_tokens: total}) do
    if known_counts?([input, cached, output, total]) and total > 0 and input + output == total and cached <= input do
      segments = [
        %{key: :cached_input, label: gettext("Cached input"), count: cached},
        %{key: :uncached_input, label: gettext("Uncached input"), count: input - cached},
        %{key: :output, label: gettext("Output"), count: output}
      ]

      title = ngettext("%{tokens} total token — Cached input: %{cached}; Uncached input: %{uncached}; Output: %{output}. Output includes reasoning tokens.", "%{tokens} total tokens — Cached input: %{cached}; Uncached input: %{uncached}; Output: %{output}. Output includes reasoning tokens.", total, tokens: Format.integer(total), cached: Format.integer(cached), uncached: Format.integer(input - cached), output: Format.integer(output))
      %{segments: segments, title: title}
    end
  end

  def token_composition(_counts), do: nil

  @spec cache_rate_label(map() | nil) :: String.t() | nil
  def cache_rate_label(%{input_tokens: input, cached_input_tokens: cached}) when is_integer(input) and input > 0 and is_integer(cached) and cached >= 0 and cached <= input do
    rate =
      (cached / input * 100)
      |> :erlang.float_to_binary(decimals: 1)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    if cached > 0 and rate == "0", do: "<0.1%", else: "#{rate}%"
  end

  def cache_rate_label(_counts), do: nil

  defp known_counts?(counts), do: Enum.all?(counts, &(is_integer(&1) and &1 >= 0))
end
