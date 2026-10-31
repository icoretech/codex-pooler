defmodule CodexPooler.Dev.I18n.TolgeeCatalogs do
  @moduledoc false

  alias CodexPoolerWeb.I18n.Catalog
  alias Expo.{Message, Messages, PO}
  alias Expo.Message.{Plural, Singular}

  @domains ~w(default errors emails)
  @type bundle :: %{domain: String.t(), template: Messages.t(), en: Messages.t(), zh: Messages.t(), path: Path.t(), original: binary()}

  @spec load!(Path.t()) :: [bundle()]
  def load!(root) do
    Enum.map(@domains, fn domain ->
      template = parse_file!(Path.join(root, "#{domain}.pot"))
      en = parse_file!(Path.join(root, "en/LC_MESSAGES/#{domain}.po"))
      path = Path.join(root, "zh_CN/LC_MESSAGES/#{domain}.po")
      original = File.read!(path)
      zh = parse!(original)
      validate!(template, en, "en")
      validate!(template, zh, "zh_CN")
      %{domain: domain, template: template, en: english(template, en), zh: zh, path: path, original: original}
    end)
  end

  @spec parse!(binary()) :: Messages.t()
  def parse!(bytes) do
    case String.valid?(bytes) && PO.parse_string(bytes) do
      {:ok, catalog} -> catalog
      _ -> raise ArgumentError, "invalid UTF-8 PO catalog"
    end
  end

  @spec encode(Messages.t()) :: binary()
  def encode(catalog), do: catalog |> PO.compose() |> IO.iodata_to_binary()

  @spec active(Messages.t()) :: [Message.t()]
  def active(catalog), do: Enum.reject(catalog.messages, & &1.obsolete)

  @spec index(Messages.t()) :: map()
  def index(catalog), do: Map.new(active(catalog), &{Message.key(&1), &1})

  @spec merge!(bundle(), Messages.t()) :: {Messages.t(), map()}
  def merge!(bundle, remote) do
    known = index(bundle.template)
    updates = index(remote)

    messages =
      Enum.map(bundle.zh.messages, fn local ->
        key = Message.key(local)

        case {local.obsolete, Map.has_key?(known, key), Map.get(updates, key)} do
          {false, true, remote_message} when not is_nil(remote_message) -> merge_message!(local, remote_message)
          _ -> local
        end
      end)

    merged = %{bundle.zh | messages: messages}
    validate!(bundle.template, merged, "zh_CN")
    changed = Enum.zip(bundle.zh.messages, messages) |> Enum.count(fn {a, b} -> translation(a) != translation(b) end)
    ignored = Enum.count(updates, fn {key, _} -> not Map.has_key?(known, key) end)
    {merged, %{changed: changed, ignored: ignored, exported: map_size(updates)}}
  end

  @spec verify!(bundle(), Messages.t(), Messages.t()) :: map()
  def verify!(bundle, english, chinese) do
    expected = index(bundle.en)
    actual = index(english)
    missing = Enum.count(expected, fn {key, message} -> not same_translation?(message, Map.get(actual, key)) end)
    if missing != 0, do: raise(ArgumentError, "remote English source mismatch: #{missing} entries")
    target = index(chinese)
    absent = Enum.count(index(bundle.template), fn {key, _} -> not Map.has_key?(target, key) end)
    if absent != 0, do: raise(ArgumentError, "remote Chinese catalog incomplete: #{absent} entries")
    {_merged, counts} = merge!(bundle, chinese)
    Map.put(counts, :source_entries, map_size(expected))
  end

  @spec write_candidates!([{bundle(), Messages.t()}], Path.t()) :: :ok
  def write_candidates!(candidates, directory) do
    Enum.each(candidates, fn {bundle, catalog} -> validate!(bundle.template, catalog, "zh_CN") end)
    if File.exists?(directory), do: raise(ArgumentError, "output directory must not already exist")
    File.mkdir_p!(Path.join(directory, "zh_CN/LC_MESSAGES"))
    Enum.each(candidates, fn {bundle, catalog} -> File.write!(Path.join(directory, "zh_CN/LC_MESSAGES/#{bundle.domain}.po"), candidate_bytes(bundle, catalog)) end)
    :ok
  end

  @spec apply!([{bundle(), Messages.t()}]) :: :ok
  def apply!(candidates) do
    Enum.each(candidates, fn {bundle, catalog} ->
      validate!(bundle.template, catalog, "zh_CN")
      if File.read!(bundle.path) != bundle.original, do: raise(ArgumentError, "catalog changed concurrently; rerun pull")
    end)

    nonce = System.unique_integer([:positive])
    staged = candidates |> Enum.reject(fn {bundle, catalog} -> bundle.zh == catalog end) |> Enum.map(fn {bundle, catalog} -> {bundle, "#{bundle.path}.tolgee-#{nonce}", candidate_bytes(bundle, catalog)} end)

    try do
      Enum.each(staged, fn {_bundle, temp, bytes} -> File.write!(temp, bytes, [:exclusive]) end)

      Enum.each(staged, fn {bundle, _temp, _bytes} ->
        if File.read!(bundle.path) != bundle.original, do: raise(ArgumentError, "catalog changed concurrently; rerun pull")
      end)

      commit_staged!(staged, [])
    after
      Enum.each(staged, fn {_bundle, temp, _bytes} -> File.rm(temp) end)
    end
  end

  defp commit_staged!([], _written), do: :ok

  defp commit_staged!([{bundle, temp, _bytes} | rest], written) do
    case File.rename(temp, bundle.path) do
      :ok ->
        commit_staged!(rest, [bundle | written])

      {:error, reason} ->
        Enum.each(written, fn previous -> File.write!(previous.path, previous.original) end)
        raise File.Error, reason: reason, path: bundle.path, action: "replace catalog"
    end
  end

  defp candidate_bytes(%{zh: catalog, original: original}, catalog), do: original
  defp candidate_bytes(_bundle, catalog), do: encode(catalog)

  defp parse_file!(path), do: path |> File.read!() |> parse!()

  defp english(template, en) do
    messages =
      Enum.map(active(template), fn
        %Singular{} = message -> %{message | msgstr: message.msgid}
        %Plural{} = message -> %{message | msgstr: %{0 => message.msgid, 1 => message.msgid_plural}}
      end)

    %{en | messages: messages}
  end

  defp merge_message!(%type{} = local, %type{} = remote) do
    if plural_source(local) != plural_source(remote) or Message.has_flag?(remote, "fuzzy"), do: raise(ArgumentError, "remote catalog has an incompatible source or fuzzy translation")
    %{local | msgstr: remote.msgstr}
  end

  defp merge_message!(_, _), do: raise(ArgumentError, "remote catalog has an incompatible message shape")
  defp plural_source(%Plural{msgid_plural: value}), do: IO.iodata_to_binary(value)
  defp plural_source(%Singular{}), do: nil
  defp translation(%Singular{msgstr: value}), do: IO.iodata_to_binary(value)
  defp translation(%Plural{msgstr: values}), do: Map.new(values, fn {key, value} -> {key, IO.iodata_to_binary(value)} end)
  defp same_translation?(_, nil), do: false
  defp same_translation?(left, right), do: left.__struct__ == right.__struct__ and plural_source(left) == plural_source(right) and translation(left) == translation(right)

  defp validate!(template, catalog, locale) do
    case Catalog.validate(template, catalog, locale) do
      [] -> :ok
      issues -> raise ArgumentError, "catalog validation failed: #{length(issues)} issue(s), codes=#{issues |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.join(",")}"
    end
  end
end
