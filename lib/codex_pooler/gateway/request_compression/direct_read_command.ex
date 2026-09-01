defmodule CodexPooler.Gateway.RequestCompression.DirectReadCommand do
  @moduledoc false

  @type quote :: :unquoted | :single | :double | :native
  @type token :: {quote(), String.t()}

  @spec read?(term()) :: boolean()
  def read?(%{"type" => "local_shell_call"} = item) do
    case item do
      %{"action" => %{"type" => "exec", "command" => command}}
      when is_list(command) and command != [] ->
        if Enum.all?(command, &valid_native_token?/1) do
          command
          |> Enum.map(&{:native, &1})
          |> direct_read?()
        else
          false
        end

      _item ->
        false
    end
  end

  def read?(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> read?(decoded)
      _invalid -> false
    end
  end

  def read?(arguments) when is_map(arguments) do
    case command_argument(arguments) do
      {:ok, command} -> scalar_read?(command)
      :error -> false
    end
  end

  def read?(_arguments), do: false

  defp valid_native_token?(token) when is_binary(token) and token != "" do
    token
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 32 and &1 != 127))
  end

  defp valid_native_token?(_token), do: false

  defp command_argument(arguments) do
    case Enum.filter(["cmd", "command"], &Map.has_key?(arguments, &1)) do
      [key] ->
        case Map.fetch!(arguments, key) do
          command when is_binary(command) and command != "" -> {:ok, command}
          _invalid -> :error
        end

      _keys ->
        :error
    end
  end

  defp scalar_read?(command) do
    case lex(command) do
      {:ok, tokens} -> scalar_tokens_read?(tokens)
      :error -> false
    end
  end

  defp scalar_tokens_read?(tokens) do
    case Enum.split_while(tokens, &(&1 != :pipe)) do
      {direct, []} -> direct_read?(direct)
      {left, [:pipe | right]} -> nl_read?(left) and pipeline_sed_read?(right)
    end
  end

  defp direct_read?([{:unquoted, "cat"} | args]), do: file_command_read?(args, [])
  defp direct_read?([{:native, "cat"} | args]), do: file_command_read?(args, [])
  defp direct_read?([{:unquoted, "nl"} | args]), do: nl_args_read?(args)
  defp direct_read?([{:native, "nl"} | args]), do: nl_args_read?(args)
  defp direct_read?([{:unquoted, "head"} | args]), do: head_tail_args_read?(args)
  defp direct_read?([{:native, "head"} | args]), do: head_tail_args_read?(args)
  defp direct_read?([{:unquoted, "tail"} | args]), do: head_tail_args_read?(args)
  defp direct_read?([{:native, "tail"} | args]), do: head_tail_args_read?(args)
  defp direct_read?([{:unquoted, "sed"} | args]), do: sed_args_read?(args, true)
  defp direct_read?([{:native, "sed"} | args]), do: sed_args_read?(args, true)
  defp direct_read?(_tokens), do: false

  defp nl_read?([{:unquoted, "nl"} | args]), do: nl_args_read?(args)
  defp nl_read?(_tokens), do: false

  defp nl_args_read?([{:unquoted, "-ba"} | args]), do: file_command_read?(args, [])
  defp nl_args_read?([{:native, "-ba"} | args]), do: file_command_read?(args, [])
  defp nl_args_read?(args), do: file_command_read?(args, [])

  defp head_tail_args_read?([{:unquoted, "-n"}, {:unquoted, count} | args]) do
    decimal?(count) and file_command_read?(args, [])
  end

  defp head_tail_args_read?([{:native, "-n"}, {:native, count} | args]) do
    decimal?(count) and file_command_read?(args, [])
  end

  defp head_tail_args_read?([{quote, "--"} | _args] = args)
       when quote in [:unquoted, :native],
       do: file_command_read?(args, [])

  defp head_tail_args_read?([{quote, <<"-", count::binary>>} | args])
       when quote in [:unquoted, :native] do
    decimal?(count) and file_command_read?(args, [])
  end

  defp head_tail_args_read?(args), do: file_command_read?(args, [])

  defp sed_args_read?([{quote, "-n"}, script | args], require_files?)
       when quote in [:unquoted, :native] do
    print_script?(script) and
      if(require_files?, do: file_command_read?(args, []), else: args == [])
  end

  defp sed_args_read?(_args, _require_files?), do: false

  defp pipeline_sed_read?([{:unquoted, "sed"} | args]), do: sed_args_read?(args, false)
  defp pipeline_sed_read?(_tokens), do: false

  defp print_script?({quote, script}) do
    valid_print_script?(script) and
      (not String.contains?(script, "$") or quote in [:single, :native])
  end

  defp valid_print_script?(script) do
    case Regex.run(~r/\A(?:[0-9]+|\$)(?:,(?:[0-9]+|\$))?p\z/, script) do
      [_match] -> true
      _no_match -> false
    end
  end

  defp file_command_read?(tokens, files) do
    case tokens do
      [] ->
        files != []

      [{quote, "--"} | rest] when quote in [:unquoted, :native] and files == [] ->
        files_after_separator?(rest)

      [{_quote, file} | rest] ->
        if file_operand?(file, false) do
          file_command_read?(rest, [file | files])
        else
          false
        end
    end
  end

  defp files_after_separator?([]), do: false

  defp files_after_separator?(tokens) do
    Enum.all?(tokens, fn {_quote, file} -> file != "--" and file_operand?(file, true) end)
  end

  defp file_operand?(file, after_separator?) do
    String.trim(file) != "" and file != "-" and
      (after_separator? or not String.starts_with?(file, "-"))
  end

  defp decimal?(value) when value != "" do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp decimal?(_value), do: false

  defp lex(command) when is_binary(command) do
    lex(command, :between, [], [], false)
  end

  defp lex(<<>>, :between, [], [], _pipe?), do: :error
  defp lex(<<>>, :between, [], tokens, _pipe?), do: {:ok, Enum.reverse(tokens)}

  defp lex(<<>>, :unquoted, current, tokens, _pipe?) do
    with {:ok, next_tokens} <- finish_token(:unquoted, current, tokens) do
      {:ok, Enum.reverse(next_tokens)}
    end
  end

  defp lex(<<>>, quote, _current, _tokens, _pipe?) when quote in [:single, :double], do: :error

  defp lex(<<char, rest::binary>>, state, current, tokens, pipe?) when char in [32, 9] do
    case state do
      :between ->
        lex(rest, :between, [], tokens, pipe?)

      :unquoted ->
        with {:ok, next_tokens} <- finish_token(:unquoted, current, tokens) do
          lex(rest, :between, [], next_tokens, pipe?)
        end

      quoted when quoted in [:single, :double] ->
        lex(rest, state, [char | current], tokens, pipe?)
    end
  end

  defp lex(<<char, _rest::binary>>, _state, _current, _tokens, _pipe?)
       when char < 32 or char == 127,
       do: :error

  defp lex(<<quote, rest::binary>>, :between, [], tokens, pipe?) when quote in [?', ?"] do
    lex(rest, if(quote == ?', do: :single, else: :double), [], tokens, pipe?)
  end

  defp lex(<<quote, rest::binary>>, kind, current, tokens, pipe?)
       when (quote == ?' and kind == :single) or (quote == ?" and kind == :double) do
    case rest do
      <<>> ->
        with {:ok, next_tokens} <- finish_token(kind, current, tokens) do
          {:ok, Enum.reverse(next_tokens)}
        end

      <<next, _tail::binary>> when next in [32, 9] ->
        with {:ok, next_tokens} <- finish_token(kind, current, tokens) do
          lex(rest, :between, [], next_tokens, pipe?)
        end

      _mixed ->
        :error
    end
  end

  defp lex(<<char, _rest::binary>>, :unquoted, _current, _tokens, _pipe?)
       when char in [?', ?"],
       do: :error

  defp lex(<<char, _rest::binary>>, :between, _current, _tokens, _pipe?)
       when char in [?;, ?&, ?<, ?>, ?(, ?), ?{, ?}, ?!, ?#],
       do: :error

  defp lex(<<char, _rest::binary>>, :unquoted, _current, _tokens, _pipe?)
       when char in [?;, ?&, ?<, ?>, ?(, ?), ?{, ?}, ?!],
       do: :error

  defp lex(<<?|, rest::binary>>, :between, [], tokens, false) when tokens != [] do
    case rest do
      <<next, _tail::binary>> when next in [32, 9] ->
        lex(rest, :between, [], [:pipe | tokens], true)

      _adjacent ->
        :error
    end
  end

  defp lex(<<?|, _rest::binary>>, state, _current, _tokens, _pipe?)
       when state in [:between, :unquoted],
       do: :error

  defp lex(<<92, _rest::binary>>, quoted, _current, _tokens, _pipe?)
       when quoted in [:single, :double],
       do: :error

  defp lex(<<96, _rest::binary>>, quoted, _current, _tokens, _pipe?)
       when quoted in [:single, :double],
       do: :error

  defp lex(<<36, _rest::binary>>, :double, _current, _tokens, _pipe?),
    do: :error

  defp lex(<<char, _rest::binary>>, :between, _current, _tokens, _pipe?)
       when char == 36 or char == 92 or char == 96,
       do: :error

  defp lex(<<char, rest::binary>>, :unquoted, current, tokens, pipe?) do
    if char in [36, 92, 96] do
      :error
    else
      lex(rest, :unquoted, [char | current], tokens, pipe?)
    end
  end

  defp lex(<<char, rest::binary>>, :between, [], tokens, pipe?) do
    lex(rest, :unquoted, [char], tokens, pipe?)
  end

  defp lex(<<char, rest::binary>>, kind, current, tokens, pipe?)
       when kind in [:single, :double] do
    lex(rest, kind, [char | current], tokens, pipe?)
  end

  defp finish_token(_quote, [], _tokens), do: :error

  defp finish_token(quote, reversed, tokens) do
    {:ok, [{quote, reversed |> Enum.reverse() |> :erlang.list_to_binary()} | tokens]}
  end
end
