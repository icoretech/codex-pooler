defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.HostedShell do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @identifier_max_codepoints 64
  @output_max_codepoints 10_485_760
  @skills_max_items 200
  @statuses ~w(in_progress completed incomplete)

  @type skill :: %{required(String.t()) => String.t()}
  @type caller :: %{required(String.t()) => String.t()}
  @type environment :: %{required(String.t()) => String.t() | [skill()]}
  @type action :: %{required(String.t()) => [String.t()] | integer() | nil}
  @type outcome :: %{required(String.t()) => String.t() | integer()}
  @type output :: %{required(String.t()) => String.t() | outcome()}
  @type item :: %{
          required(String.t()) =>
            String.t()
            | integer()
            | nil
            | action()
            | caller()
            | environment()
            | [output()]
        }
  @type result :: {:ok, item()} | {:error, Error.reason()}

  @spec validate_item(term()) :: result()
  def validate_item(%{"type" => "shell_call"} = item) do
    with :ok <- exact_keys(item, ~w(type call_id action id caller status environment)),
         :ok <- bounded_identifier(Map.get(item, "call_id")),
         :ok <- validate_action(Map.get(item, "action")),
         :ok <- optional_nullable_string(item, "id"),
         :ok <- optional_caller(item),
         :ok <- optional_status(item),
         :ok <- optional_environment(item) do
      {:ok, item}
    else
      _invalid -> invalid()
    end
  end

  def validate_item(%{"type" => "shell_call_output"} = item) do
    with :ok <- exact_keys(item, ~w(type call_id output id caller status max_output_length)),
         :ok <- bounded_identifier(Map.get(item, "call_id")),
         :ok <- validate_output(Map.get(item, "output")),
         :ok <- optional_nullable_string(item, "id"),
         :ok <- optional_caller(item),
         :ok <- optional_status(item),
         :ok <- optional_nullable_integer(item, "max_output_length") do
      {:ok, item}
    else
      _invalid -> invalid()
    end
  end

  def validate_item(_item), do: invalid()

  @spec validate_action(term()) :: :ok | :error
  defp validate_action(%{"commands" => commands} = action) when is_list(commands) do
    with :ok <- exact_keys(action, ~w(commands timeout_ms max_output_length)),
         true <- Enum.all?(commands, &is_binary/1),
         :ok <- optional_nullable_integer(action, "timeout_ms"),
         :ok <- optional_nullable_integer(action, "max_output_length") do
      :ok
    else
      _invalid -> :error
    end
  end

  defp validate_action(_action), do: :error

  @spec optional_caller(map()) :: :ok | :error
  defp optional_caller(%{"caller" => nil}), do: :ok

  defp optional_caller(%{"caller" => %{"type" => "direct"} = caller}),
    do: exact_keys(caller, ["type"])

  defp optional_caller(%{
         "caller" => %{"type" => "program", "caller_id" => caller_id} = caller
       }) do
    with :ok <- exact_keys(caller, ~w(type caller_id)) do
      bounded_identifier(caller_id)
    end
  end

  defp optional_caller(%{"caller" => _caller}), do: :error
  defp optional_caller(_item), do: :ok

  @spec optional_status(map()) :: :ok | :error
  defp optional_status(%{"status" => status}) when status in @statuses or is_nil(status), do: :ok
  defp optional_status(%{"status" => _status}), do: :error
  defp optional_status(_item), do: :ok

  @spec optional_environment(map()) :: :ok | :error
  defp optional_environment(%{"environment" => nil}), do: :ok

  defp optional_environment(%{"environment" => %{"type" => "local"} = environment}) do
    with :ok <- exact_keys(environment, ~w(type skills)) do
      optional_skills(environment)
    end
  end

  defp optional_environment(%{
         "environment" =>
           %{
             "type" => "container_reference",
             "container_id" => container_id
           } = environment
       })
       when is_binary(container_id),
       do: exact_keys(environment, ~w(type container_id))

  defp optional_environment(%{"environment" => _environment}), do: :error
  defp optional_environment(_item), do: :ok

  @spec optional_skills(map()) :: :ok | :error
  defp optional_skills(%{"skills" => skills}) when is_list(skills),
    do: validate_skills(skills, 0)

  defp optional_skills(%{"skills" => _skills}), do: :error
  defp optional_skills(_environment), do: :ok

  @spec validate_skills(list(), non_neg_integer()) :: :ok | :error
  defp validate_skills([], _count), do: :ok
  defp validate_skills([_skill | _rest], @skills_max_items), do: :error

  defp validate_skills([skill | rest], count) do
    with :ok <- validate_skill(skill) do
      validate_skills(rest, count + 1)
    end
  end

  @spec validate_skill(term()) :: :ok | :error
  defp validate_skill(
         %{
           "name" => name,
           "description" => description,
           "path" => path
         } = skill
       )
       when is_binary(name) and is_binary(description) and is_binary(path),
       do: exact_keys(skill, ~w(name description path))

  defp validate_skill(_skill), do: :error

  @spec validate_output(term()) :: :ok | :error
  defp validate_output(output) when is_list(output), do: validate_each(output, &validate_chunk/1)
  defp validate_output(_output), do: :error

  @spec validate_chunk(term()) :: :ok | :error
  defp validate_chunk(
         %{
           "stdout" => stdout,
           "stderr" => stderr,
           "outcome" => outcome
         } = chunk
       )
       when is_binary(stdout) and is_binary(stderr) do
    with :ok <- exact_keys(chunk, ~w(stdout stderr outcome)),
         true <- bounded_codepoints?(stdout, 0, @output_max_codepoints),
         true <- bounded_codepoints?(stderr, 0, @output_max_codepoints) do
      validate_outcome(outcome)
    else
      _invalid -> :error
    end
  end

  defp validate_chunk(_chunk), do: :error

  @spec validate_outcome(term()) :: :ok | :error
  defp validate_outcome(%{"type" => "timeout"} = outcome), do: exact_keys(outcome, ["type"])

  defp validate_outcome(%{"type" => "exit", "exit_code" => exit_code} = outcome)
       when is_integer(exit_code),
       do: exact_keys(outcome, ~w(type exit_code))

  defp validate_outcome(_outcome), do: :error

  @spec optional_nullable_string(map(), String.t()) :: :ok | :error
  defp optional_nullable_string(item, key) do
    case Map.fetch(item, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) or is_nil(value) -> :ok
      {:ok, _value} -> :error
    end
  end

  @spec optional_nullable_integer(map(), String.t()) :: :ok | :error
  defp optional_nullable_integer(item, key) do
    case Map.fetch(item, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) or is_nil(value) -> :ok
      {:ok, _value} -> :error
    end
  end

  @spec bounded_identifier(term()) :: :ok | :error
  defp bounded_identifier(value) when is_binary(value) do
    if bounded_codepoints?(value, 1, @identifier_max_codepoints), do: :ok, else: :error
  end

  defp bounded_identifier(_value), do: :error

  @spec bounded_codepoints?(binary(), non_neg_integer(), pos_integer()) :: boolean()
  defp bounded_codepoints?(value, minimum, maximum),
    do: scan_codepoints(value, 0, minimum, maximum)

  @spec scan_codepoints(binary(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          boolean()
  defp scan_codepoints(value, count, minimum, maximum) do
    case String.next_codepoint(value) do
      nil ->
        count >= minimum

      {_codepoint, _rest} when count == maximum ->
        false

      {codepoint, rest} ->
        String.valid?(codepoint) and scan_codepoints(rest, count + 1, minimum, maximum)
    end
  end

  @spec exact_keys(map(), [String.t()]) :: :ok | :error
  defp exact_keys(item, allowed_keys) do
    if Enum.all?(Map.keys(item), &(&1 in allowed_keys)), do: :ok, else: :error
  end

  @spec validate_each(list(), (term() -> :ok | :error)) :: :ok | :error
  defp validate_each(items, validator) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validator.(item) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  @spec invalid() :: {:error, Error.reason()}
  defp invalid,
    do: {:error, Error.invalid_request("input item shape is not translatable", "input")}
end
