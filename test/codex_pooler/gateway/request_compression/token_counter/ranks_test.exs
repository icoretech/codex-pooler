defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.RanksTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks

  @bpe_beam_file ~c"Elixir.CodexPooler.Gateway.RequestCompression.TokenCounter.BPE.beam"

  test "load/1 loads CRLF-normalized copies of every bundled rank asset" do
    {:module, Ranks} = Code.ensure_loaded(Ranks)

    encodings = Ranks.supported_encodings()

    previous_cache =
      Map.new(encodings, fn encoding ->
        key = {Ranks, :ranks, encoding}
        {key, :persistent_term.get(key, :not_found)}
      end)

    original_app_dir = List.to_string(:code.lib_dir(:codex_pooler))
    original_priv_dir = List.to_string(:code.priv_dir(:codex_pooler))
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
  end
end
