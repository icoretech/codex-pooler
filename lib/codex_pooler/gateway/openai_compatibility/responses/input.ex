defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.{Normalization, Validation}

  @spec normalize_audio_input(map()) :: {:ok, map()} | {:error, Error.reason()}
  defdelegate normalize_audio_input(payload), to: Normalization

  @spec normalize_input(map()) :: {:ok, map()} | {:error, term()}
  defdelegate normalize_input(payload), to: Normalization

  @spec finalize_normalized_input(map()) :: {:ok, map()} | {:error, term()}
  defdelegate finalize_normalized_input(payload), to: Normalization

  @spec normalize_list_input(map()) :: {:ok, map()} | {:error, term()}
  defdelegate normalize_list_input(payload), to: Normalization

  @spec normalize_recoverable_opencode_replay_call_ids(map()) :: {:ok, map()}
  defdelegate normalize_recoverable_opencode_replay_call_ids(payload), to: Normalization

  @spec validate_input(map()) :: :ok | {:error, term()}
  defdelegate validate_input(payload), to: Validation

  @spec validate_input(map(), boolean()) :: :ok | {:error, term()}
  defdelegate validate_input(payload, has_tool_result?), to: Validation

  @spec validate_previous_response_continuation(map()) :: :ok | {:error, term()}
  defdelegate validate_previous_response_continuation(payload), to: Validation

  @spec validate_previous_response_continuation(map(), boolean()) :: :ok | {:error, term()}
  defdelegate validate_previous_response_continuation(payload, has_tool_result?), to: Validation
end
