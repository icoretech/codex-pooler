defmodule CodexPooler.Gateway.OpenAICompatibility.Matrix do
  @moduledoc false

  @fields %{
    responses:
      ~w(background client_metadata context_management conversation include input instructions max_output_tokens max_tool_calls metadata model moderation parallel_tool_calls previous_response_id prompt prompt_cache_key prompt_cache_options prompt_cache_retention reasoning safety_identifier service_tier store stream stream_options temperature text tool_choice tools top_logprobs top_p truncation user),
    chat:
      ~w(audio frequency_penalty function_call functions input instructions logit_bias logprobs max_completion_tokens max_tokens messages metadata modalities model moderation n parallel_tool_calls prediction presence_penalty prompt_cache_key prompt_cache_options prompt_cache_retention reasoning_effort response_format safety_identifier seed service_tier stop store stream stream_options temperature tool_choice tools top_logprobs top_p user verbosity web_search_options),
    files: ~w(file purpose),
    audio: ~w(file model language prompt response_format temperature),
    images:
      ~w(model prompt size quality background input_fidelity n image image[] mask response_format user)
  }

  @forwarded_fields %{
    responses:
      ~w(client_metadata include input instructions max_output_tokens metadata model moderation parallel_tool_calls previous_response_id prompt_cache_key prompt_cache_options prompt_cache_retention reasoning safety_identifier service_tier store stream stream_options temperature text tool_choice tools top_p),
    chat: []
  }

  @spec supported_fields(atom()) :: [String.t()]
  def supported_fields(adapter), do: Map.fetch!(@fields, adapter)

  @spec forwarded_fields(atom()) :: [String.t()]
  def forwarded_fields(adapter), do: Map.fetch!(@forwarded_fields, adapter)

  @spec supported_field_matrix() :: %{atom() => [String.t()]}
  def supported_field_matrix, do: @fields
end
