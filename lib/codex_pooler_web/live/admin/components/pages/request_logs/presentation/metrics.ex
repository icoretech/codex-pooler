defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics do
  @moduledoc false

  alias CodexPoolerWeb.Admin.Format

  @model_colors ~w(--color-info --color-success --color-secondary --color-warning --color-reset-bank --admin-chart-other-models)

  @spec model_color(String.t()) :: String.t()
  def model_color(model), do: "var(#{Enum.at(@model_colors, :erlang.phash2(model, length(@model_colors)))})"

  @type segment :: %{key: :cached_input | :uncached_input | :output, label: String.t(), count: non_neg_integer()}
  @type composition :: %{segments: [segment()], title: String.t()}

  @spec token_composition(map() | nil) :: composition() | nil
  def token_composition(%{input_tokens: input, cached_input_tokens: cached, output_tokens: output, total_tokens: total}) do
    if known_counts?([input, cached, output, total]) and total > 0 and input + output == total and cached <= input do
      segments = [
        %{key: :cached_input, label: "Cached input", count: cached},
        %{key: :uncached_input, label: "Uncached input", count: input - cached},
        %{key: :output, label: "Output", count: output}
      ]

      detail = Enum.map_join(segments, "; ", &"#{&1.label}: #{Format.integer(&1.count)}")
      %{segments: segments, title: "#{Format.integer(total)} total tokens — #{detail}. Output includes reasoning tokens."}
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

    "#{rate}%"
  end

  def cache_rate_label(_counts), do: nil

  defp known_counts?(counts), do: Enum.all?(counts, &(is_integer(&1) and &1 >= 0))
end
