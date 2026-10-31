defmodule CodexPooler.Dev.TolgeeSyncTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Dev.I18n.{TolgeeCatalogs, TolgeeClient}
  alias Expo.Message.{Plural, Singular}
  alias Expo.Messages
  alias Mix.Tasks.CodexPooler.I18n.Tolgee

  setup do
    root = Path.join(System.tmp_dir!(), "tolgee-catalog-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "en/LC_MESSAGES"))
    File.mkdir_p!(Path.join(root, "zh_CN/LC_MESSAGES"))

    for domain <- ~w(default errors emails) do
      File.cp!("test/fixtures/i18n/messages.pot", Path.join(root, "#{domain}.pot"))
      File.cp!("test/fixtures/i18n/en.po", Path.join(root, "en/LC_MESSAGES/#{domain}.po"))
      File.cp!("test/fixtures/i18n/zh_CN.po", Path.join(root, "zh_CN/LC_MESSAGES/#{domain}.po"))
    end

    %{root: root, bundles: TolgeeCatalogs.load!(root)}
  end

  test "push uses real multipart PO bytes, explicit namespaces and KEEP drafts", %{bundles: bundles} do
    owner = self()

    config =
      server(fn conn ->
        {parts, conn} = read_parts(conn, [])
        send(owner, {:import, conn.request_path, Plug.Conn.get_req_header(conn, "x-api-key"), parts})
        json(conn, 200, %{unresolvedConflicts: nil})
      end)

    assert :ok = TolgeeClient.push!(config, bundles)
    assert_receive {:import, "/v2/projects/1/single-step-import", ["synthetic-token"], parts}
    assert length(parts) == 7
    {_, param_bytes} = Enum.find(parts, fn {headers, _} -> header(headers, "content-type") == "application/json" end)
    params = Jason.decode!(param_bytes)
    assert params["forceMode"] == "KEEP"
    assert params["removeOtherKeys"] == false
    assert params["overrideKeyDescriptions"] == false
    assert params["convertPlaceholdersToIcu"] == false
    assert params["storeFilesToFileStorage"] == false
    assert Enum.sort(Enum.map(params["fileMappings"], &{&1["namespace"], &1["languageTag"]})) == for(domain <- ~w(default emails errors), locale <- ~w(en zh-CN), do: {domain, locale})
    files = Enum.reject(parts, fn {headers, _} -> header(headers, "content-type") == "application/json" end)

    for {headers, bytes} <- files do
      assert String.valid?(bytes)
      po = TolgeeCatalogs.parse!(bytes)
      assert length(po.messages) == 6

      if String.contains?(header(headers, "content-disposition"), "-en.po") do
        assert %Singular{msgid: ["Open"], msgstr: ["Open"]} = hd(po.messages)
        assert %{0 => ["%{count} request for %{name}"], 1 => ["%{count} requests for %{name}"]} = Enum.at(po.messages, 3).msgstr
      end
    end

    assert hd(bundles).original == File.read!(hd(bundles).path)
  end

  test "reviewed export uses actual query and decodes unlabelled UTF-8", %{bundles: [bundle | _]} do
    owner = self()
    remote = %{bundle.zh | messages: [%{hd(bundle.zh.messages) | msgstr: ["启动"]}]}

    config =
      server(fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(owner, {:export_query, conn.query_params})
        conn |> Plug.Conn.put_resp_content_type("text/x-gettext-translation") |> Plug.Conn.send_resp(200, TolgeeCatalogs.encode(remote))
      end)

    exported = TolgeeClient.export!(config, "default", "zh-CN", :reviewed)
    assert hd(exported.messages).msgstr == ["启动"]
    assert_receive {:export_query, %{"filterState" => "REVIEWED", "filterNamespace" => "default", "languages" => "zh-CN", "format" => "PO", "zip" => "false"}}
    {merged, counts} = TolgeeCatalogs.merge!(bundle, exported)
    assert counts == %{changed: 1, ignored: 0, exported: 1}
    assert Enum.drop(merged.messages, 1) == Enum.drop(bundle.zh.messages, 1)
    assert merged.headers == bundle.zh.headers
  end

  test "empty reviewed response means no changes; other errors are sanitized", %{bundles: [bundle | _]} do
    config = server(&json(&1, 400, %{code: "no_exported_result"}))
    empty = TolgeeClient.export!(config, "errors", "zh-CN", :reviewed)
    assert {bundle.zh, %{changed: 0, ignored: 0, exported: 0}} == TolgeeCatalogs.merge!(bundle, empty)
    failed = server(&json(&1, 403, %{secret: "must-not-appear"}))
    assert_raise ArgumentError, "Tolgee request failed (HTTP 403)", fn -> TolgeeClient.export!(failed, "errors", "zh-CN", :reviewed) end
    conflict = server(&json(&1, 200, %{unresolvedConflicts: [%{secret: "must-not-appear"}]}))
    assert_raise ArgumentError, "Tolgee import returned unresolved conflicts or an invalid result", fn -> TolgeeClient.push!(conflict, [bundle]) end
  end

  test "merge preserves local metadata, contexts, plural sources and obsolete entries", %{bundles: [bundle | _]} do
    [button, state | rest] = bundle.zh.messages
    button = %{button | comments: ["Local translator comment"], extracted_comments: ["Local description"], references: [[{"sample.ex", 12}]]}
    obsolete = %Singular{msgid: ["Retired"], msgstr: ["旧"], obsolete: true}
    bundle = %{bundle | zh: %{bundle.zh | messages: [button, state | rest] ++ [obsolete]}}
    remote = %Messages{messages: [%{button | msgstr: ["启动"], comments: [], extracted_comments: [], references: []}, %Singular{msgid: ["Unknown"], msgstr: ["新"]}, %{obsolete | msgstr: ["忽略"]}]}
    {merged, counts} = TolgeeCatalogs.merge!(bundle, remote)
    assert counts == %{changed: 1, ignored: 1, exported: 2}
    assert hd(merged.messages) == %{button | msgstr: ["启动"]}
    assert Enum.at(merged.messages, 1) == state
    assert List.last(merged.messages) == obsolete
    assert Enum.at(merged.messages, 3).__struct__ == Plural
  end

  test "invalid placeholder, shape, plural source and fuzzy updates fail closed", %{bundles: [bundle | _]} do
    placeholder = Enum.at(bundle.zh.messages, 2)
    plural = Enum.at(bundle.zh.messages, 3)

    for message <- [%{placeholder | msgstr: ["missing binding"]}, %{plural | msgid_plural: ["different source"]}, %{placeholder | flags: [["fuzzy"]]}, %Singular{msgid: plural.msgid, msgstr: ["wrong shape"]}] do
      assert_raise ArgumentError, fn -> TolgeeCatalogs.merge!(bundle, %Messages{messages: [message]}) end
    end

    assert bundle.original == File.read!(bundle.path)
  end

  test "full check fails missing or altered English and missing Chinese", %{bundles: [bundle | _]} do
    assert %{changed: 0, source_entries: 6} = TolgeeCatalogs.verify!(bundle, bundle.en, bundle.zh)

    for {en, zh} <- [{%{bundle.en | messages: []}, bundle.zh}, {bundle.en, %{bundle.zh | messages: []}}, {%{bundle.en | messages: [%{hd(bundle.en.messages) | msgstr: ["altered"]} | tl(bundle.en.messages)]}, bundle.zh}] do
      assert_raise ArgumentError, fn -> TolgeeCatalogs.verify!(bundle, en, zh) end
    end
  end

  test "candidate output is complete, exclusive and leaves baseline untouched", %{root: root, bundles: bundles} do
    destination = Path.join(root, "candidate")
    candidates = Enum.map(bundles, &{&1, &1.zh})
    assert :ok = TolgeeCatalogs.write_candidates!(candidates, destination)

    for bundle <- bundles do
      output = File.read!(Path.join(destination, "zh_CN/LC_MESSAGES/#{bundle.domain}.po")) |> TolgeeCatalogs.parse!()
      assert TolgeeCatalogs.index(output) |> Map.keys() == TolgeeCatalogs.index(bundle.zh) |> Map.keys()
      assert File.read!(bundle.path) == bundle.original
    end

    assert_raise ArgumentError, fn -> TolgeeCatalogs.write_candidates!(candidates, destination) end
  end

  test "apply checks all original files before writing any catalog", %{bundles: [first, second | _]} do
    candidate = %{first.zh | messages: [%{hd(first.zh.messages) | msgstr: ["启动"]} | tl(first.zh.messages)]}
    File.write!(second.path, second.original <> "\n# concurrent edit\n")
    assert_raise ArgumentError, "catalog changed concurrently; rerun pull", fn -> TolgeeCatalogs.apply!([{first, candidate}, {second, second.zh}]) end
    assert File.read!(first.path) == first.original
  end

  test "apply writes valid candidates and preserves English/POT", %{root: root, bundles: [bundle | _]} do
    english = File.read!(Path.join(root, "en/LC_MESSAGES/default.po"))
    template = File.read!(Path.join(root, "default.pot"))
    candidate = %{bundle.zh | messages: [%{hd(bundle.zh.messages) | msgstr: ["启动"]} | tl(bundle.zh.messages)]}
    assert :ok = TolgeeCatalogs.apply!([{bundle, candidate}])
    assert hd(TolgeeCatalogs.parse!(File.read!(bundle.path)).messages).msgstr == ["启动"]
    assert File.read!(Path.join(root, "en/LC_MESSAGES/default.po")) == english
    assert File.read!(Path.join(root, "default.pot")) == template
    assert Path.wildcard(bundle.path <> ".tolgee-*") == []
  end

  test "a later invalid candidate prevents all filesystem writes", %{root: root, bundles: [first, second | _]} do
    valid = %{first.zh | messages: [%{hd(first.zh.messages) | msgstr: ["启动"]} | tl(first.zh.messages)]}
    invalid = %{second.zh | messages: []}
    candidates = [{first, valid}, {second, invalid}]
    assert_raise ArgumentError, fn -> TolgeeCatalogs.apply!(candidates) end
    assert File.read!(first.path) == first.original
    destination = Path.join(root, "invalid-candidate")
    assert_raise ArgumentError, fn -> TolgeeCatalogs.write_candidates!(candidates, destination) end
    refute File.exists?(destination)
  end

  test "redirects never forward the project credential" do
    owner = self()

    destination =
      server(fn conn ->
        send(owner, :credential_destination_reached)
        json(conn, 200, %{})
      end)

    redirect = server(fn conn -> conn |> Plug.Conn.put_resp_header("location", destination.url) |> Plug.Conn.send_resp(302, "") end)
    assert_raise ArgumentError, "Tolgee request failed (HTTP 302)", fn -> TolgeeClient.export!(redirect, "default", "zh-CN", :reviewed) end
    refute_received :credential_destination_reached
  end

  test "configuration rejects unsafe origins and missing credentials" do
    base = %{"TOLGEE_URL" => "https://translations.example.com", "TOLGEE_PROJECT_ID" => "1", "TOLGEE_API_KEY" => "synthetic-token"}
    assert %{project: 1} = TolgeeClient.configuration!(base)

    for url <- ["http://translations.example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com?key=secret"] do
      assert_raise ArgumentError, fn -> TolgeeClient.configuration!(%{base | "TOLGEE_URL" => url}, true) end
    end

    assert_raise ArgumentError, "TOLGEE_URL must be a valid origin", fn -> TolgeeClient.configuration!(%{base | "TOLGEE_URL" => "https://example.com:invalid"}) end
    assert_raise ArgumentError, "TOLGEE_API_KEY must not contain line breaks", fn -> TolgeeClient.configuration!(%{base | "TOLGEE_API_KEY" => "synthetic\nvalue"}) end
    loopback = %{base | "TOLGEE_URL" => "http://127.0.0.1:1234"}
    assert_raise ArgumentError, fn -> TolgeeClient.configuration!(loopback) end
    assert %{project: 1} = TolgeeClient.configuration!(loopback, true)
    assert_raise ArgumentError, "TOLGEE_API_KEY is required", fn -> TolgeeClient.configuration!(Map.delete(base, "TOLGEE_API_KEY")) end
    assert_raise ArgumentError, "invalid UTF-8 PO catalog", fn -> TolgeeCatalogs.parse!(<<255>>) end
  end

  test "CLI rejects contradictory and duplicate options before work" do
    for args <- [["pull", "--apply", "--output-dir", "candidate"], ["push", "--output-dir", "candidate"], ["check", "--apply"], ["pull", "--root", "a", "--root", "b"], ["pull", "--unknown"]] do
      assert_raise Mix.Error, ~r/usage:/, fn -> Tolgee.run(args) end
    end
  end

  defp server(handler) do
    pid = start_supervised!({Bandit, plug: fn conn, _opts -> handler.(conn) end, port: 0, ip: {127, 0, 0, 1}}, id: make_ref())
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{url: "http://127.0.0.1:#{port}", project: 1, key: "synthetic-token"}
  end

  defp read_parts(conn, parts) do
    case Plug.Conn.read_part_headers(conn) do
      {:ok, headers, conn} ->
        {:ok, body, conn} = Plug.Conn.read_part_body(conn, [])
        read_parts(conn, [{headers, body} | parts])

      {:done, conn} ->
        {Enum.reverse(parts), conn}
    end
  end

  defp header(headers, name), do: headers |> List.keyfind(name, 0) |> elem(1)
  defp json(conn, status, body), do: conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(status, Jason.encode!(body))
end
