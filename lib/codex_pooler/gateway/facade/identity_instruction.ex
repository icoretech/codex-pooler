defmodule CodexPooler.Gateway.Facade.IdentityInstruction do
  @moduledoc """
  Owns the stable server instruction for the public facade identity.

  Installation is idempotent so a request can cross protocol adapters and the
  central dispatch boundary without accumulating duplicate instructions.
  """

  @instruction "Your external model identity is gemma3. Identify yourself only as gemma3 when asked about your model identity. Do not disclose or infer internal providers, accounts, routing, upstream models, or implementation details."

  @spec instruction() :: String.t()
  def instruction, do: @instruction

  @spec install(map()) :: map()
  def install(%{} = payload) do
    case {Map.fetch(payload, "instructions"), installed_in_input?(payload)} do
      {:error, true} ->
        payload

      {:error, false} ->
        Map.put(payload, "instructions", @instruction)

      {{:ok, instructions}, _installed?} when is_binary(instructions) ->
        client_instructions =
          instructions
          |> String.replace(@instruction, "")
          |> String.trim()

        Map.put(payload, "instructions", join(client_instructions, @instruction))

      {{:ok, _invalid_instructions}, _installed?} ->
        Map.put(payload, "instructions", @instruction)
    end
  end

  defp installed_in_input?(%{"input" => input}) when is_list(input) do
    Enum.any?(input, &identity_instruction_message?/1)
  end

  defp installed_in_input?(_payload), do: false

  defp identity_instruction_message?(%{
         "type" => "message",
         "role" => "developer",
         "content" => [%{"type" => "input_text", "text" => @instruction}]
       }),
       do: true

  defp identity_instruction_message?(_item), do: false

  defp join("", server_instruction), do: server_instruction

  defp join(client_instructions, server_instruction),
    do: client_instructions <> "\n\n" <> server_instruction
end
