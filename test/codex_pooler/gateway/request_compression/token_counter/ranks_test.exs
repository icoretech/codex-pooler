defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.RanksTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks

  @bpe_beam_file ~c"Elixir.CodexPooler.Gateway.RequestCompression.TokenCounter.BPE.beam"

  test "load/1 resolves a bundled rank asset through a lexically valid dangling priv link" do
    {:module, Ranks} = Code.ensure_loaded(Ranks)

    encoding = :o200k_base
    cache_key = {Ranks, :ranks, encoding}
    previous_cache = :persistent_term.get(cache_key, :not_found)
    original_app_dir = List.to_string(:code.lib_dir(:codex_pooler))
    original_priv_dir = resolved_priv_dir(List.to_string(:code.priv_dir(:codex_pooler)))
    expected_ebin_entry = Path.join(original_app_dir, "ebin")

    original_code_path_entry =
      Enum.find(:code.get_path(), fn entry -> List.to_string(entry) == expected_ebin_entry end)

    assert original_code_path_entry != nil,
           "expected the exact #{expected_ebin_entry} entry in :code.get_path/0"

    temporary_root =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-dangling-priv-ranks-#{System.unique_integer([:positive])}"
      )

    physical_root = Path.join(temporary_root, "physical/deep")
    logical_root = Path.join(temporary_root, "logical")
    temporary_app_dir = Path.join(logical_root, "codex_pooler")
    temporary_ebin_dir = Path.join(temporary_app_dir, "ebin")
    temporary_priv_dir = Path.join(temporary_app_dir, "priv")
    temporary_ranks_dir = Path.join([temporary_root, "assets", "tokenizers", "ranks"])

    on_exit(fn ->
      true = :code.replace_path(:codex_pooler, original_code_path_entry)
      :persistent_term.erase(cache_key)
      if previous_cache != :not_found, do: :persistent_term.put(cache_key, previous_cache)
      File.rm_rf!(temporary_root)
    end)

    File.mkdir_p!(Path.join([physical_root, "codex_pooler", "ebin"]))
    File.mkdir_p!(temporary_ranks_dir)
    File.ln_s!(physical_root, logical_root)

    File.cp!(
      Path.join([original_app_dir, "ebin", "codex_pooler.app"]),
      Path.join(temporary_ebin_dir, "codex_pooler.app")
    )

    File.cp!(
      Path.join([original_priv_dir, "tokenizers", "ranks", "#{encoding}.tiktoken"]),
      Path.join(temporary_ranks_dir, "#{encoding}.tiktoken")
    )

    File.ln_s!("../../assets", temporary_priv_dir)

    refute File.exists?(temporary_priv_dir)
    assert Path.expand("../../assets", temporary_app_dir) == Path.join(temporary_root, "assets")
    assert :code.replace_path(:codex_pooler, String.to_charlist(temporary_app_dir)) == true
    assert List.to_string(:code.priv_dir(:codex_pooler)) == temporary_priv_dir

    :persistent_term.erase(cache_key)
    assert {:ok, ranks} = Ranks.load(encoding)
    assert map_size(ranks) > 0
  end

  test "load/1 loads CRLF-normalized copies of every bundled rank asset" do
    {:module, Ranks} = Code.ensure_loaded(Ranks)

    encodings = Ranks.supported_encodings()

    previous_cache =
      Map.new(encodings, fn encoding ->
        key = {Ranks, :ranks, encoding}
        {key, :persistent_term.get(key, :not_found)}
      end)

    original_app_dir = List.to_string(:code.lib_dir(:codex_pooler))
    original_priv_dir = resolved_priv_dir(List.to_string(:code.priv_dir(:codex_pooler)))
    expected_ebin_entry = Path.join(original_app_dir, "ebin")

    original_code_path_entry =
      Enum.find(:code.get_path(), fn entry -> List.to_string(entry) == expected_ebin_entry end)

    assert original_code_path_entry != nil,
           "expected the exact #{expected_ebin_entry} entry in :code.get_path/0"

    temporary_root =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-crlf-ranks-#{System.unique_integer([:positive])}"
      )

    temporary_app_dir = Path.join(temporary_root, Path.basename(original_app_dir))
    temporary_priv_dir = Path.join(temporary_app_dir, "priv")
    temporary_ranks_dir = Path.join([temporary_priv_dir, "tokenizers", "ranks"])

    on_exit(fn ->
      true = :code.replace_path(:codex_pooler, original_code_path_entry)

      for {key, previous} <- previous_cache do
        :persistent_term.erase(key)
        if previous != :not_found, do: :persistent_term.put(key, previous)
      end

      File.rm_rf!(temporary_root)

      code_path = Enum.map(:code.get_path(), &List.to_string/1)
      assert expected_ebin_entry in code_path
      refute temporary_app_dir in code_path

      bpe_beam_path = :code.where_is_file(@bpe_beam_file)
      assert is_list(bpe_beam_path)
      assert Path.dirname(List.to_string(bpe_beam_path)) == expected_ebin_entry

      refute File.exists?(temporary_root)
    end)

    File.mkdir_p!(Path.join(temporary_app_dir, "ebin"))
    File.mkdir_p!(temporary_ranks_dir)

    File.cp!(
      Path.join([original_app_dir, "ebin", "codex_pooler.app"]),
      Path.join([temporary_app_dir, "ebin", "codex_pooler.app"])
    )

    for encoding <- encodings do
      source = Path.join([original_priv_dir, "tokenizers", "ranks", "#{encoding}.tiktoken"])

      crlf_copy =
        source
        |> File.read!()
        |> String.replace("\r\n", "\n")
        |> String.replace("\n", "\r\n")

      File.write!(Path.join(temporary_ranks_dir, "#{encoding}.tiktoken"), crlf_copy)
    end

    assert :code.replace_path(:codex_pooler, String.to_charlist(temporary_app_dir)) == true
    assert List.to_string(:code.priv_dir(:codex_pooler)) == temporary_priv_dir

    for {key, _previous} <- previous_cache, do: :persistent_term.erase(key)

    for encoding <- encodings do
      assert {:ok, ranks} = Ranks.load(encoding)
      assert map_size(ranks) > 0
    end

    assert Ranks.load(:unsupported) == {:error, :unsupported_encoding}
    encoding = hd(encodings)
    key = {Ranks, :ranks, encoding}
    path = Path.join(temporary_ranks_dir, "#{encoding}.tiktoken")

    for invalid <- ["invalid", "%%% 0", "YQ== invalid"] do
      :persistent_term.erase(key)
      File.write!(path, invalid)
      assert Ranks.load(encoding) == {:error, :invalid_rank_file}
    end

    :persistent_term.erase(key)
    File.rm!(path)
    assert Ranks.load(encoding) == {:error, :rank_file_unavailable}

    true = :code.del_path(:codex_pooler)
    assert Ranks.load(encoding) == {:error, :rank_file_unavailable}
  end

  defp resolved_priv_dir(priv_dir) do
    if File.dir?(priv_dir) do
      priv_dir
    else
      {:ok, target} = File.read_link(priv_dir)
      Path.expand(target, Path.dirname(priv_dir))
    end
  end
end
