defmodule CodexPooler.Gateway.Payloads.RequestOptions.Persona do
  @moduledoc """
  Immutable protocol identity attached to a facade request.
  """

  alias CodexPooler.Gateway.Facade

  @protocols [
    :ollama_chat,
    :ollama_generate,
    :openai_responses,
    :openai_chat,
    :openai_completions,
    :anthropic_messages,
    :codex,
    :media,
    :metadata
  ]

  @type protocol ::
          :ollama_chat
          | :ollama_generate
          | :openai_responses
          | :openai_chat
          | :openai_completions
          | :anthropic_messages
          | :codex
          | :media
          | :metadata

  @enforce_keys [:public_model, :effective_model, :reasoning_effort, :protocol]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          public_model: String.t(),
          effective_model: String.t(),
          reasoning_effort: String.t(),
          protocol: protocol()
        }

  @spec fixed(protocol()) :: t()
  def fixed(protocol) when protocol in @protocols do
    %__MODULE__{
      public_model: Facade.public_model(),
      effective_model: Facade.effective_model(),
      reasoning_effort: Facade.reasoning_effort(),
      protocol: protocol
    }
  end

  @spec fixed?(term()) :: boolean()
  def fixed?(%__MODULE__{protocol: protocol} = persona) when protocol in @protocols do
    persona == fixed(protocol)
  end

  def fixed?(_persona), do: false
end
