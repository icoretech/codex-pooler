defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.{Normalization, Validation}

  @spec normalize_input(map()) :: {:ok, map()} | {:error, term()}
  defdelegate normalize_input(payload), to: Normalization

  @spec normalize_list_input(map()) :: {:ok, map()} | {:error, term()}
  defdelegate normalize_list_input(payload), to: Normalization

  @spec normalize_recoverable_opencode_replay_call_ids(map()) :: {:ok, map()}
  defdelegate normalize_recoverable_opencode_replay_call_ids(payload), to: Normalization

  @spec validate_input(map()) :: :ok | {:error, term()}
  defdelegate validate_input(payload), to: Validation

  @spec validate_previous_response_continuation(map()) :: :ok | {:error, term()}
  defdelegate validate_previous_response_continuation(payload), to: Validation
end
