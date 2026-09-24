defmodule CodexPooler.Gateway.Metadata.CatalogRepresentationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Metadata.CatalogRepresentation
  alias CodexPooler.Gateway.Payloads.RequestOptions

  # findings#258 row 258-102: the catalog fetch and the turn select the
  # representation from the same `User-Agent`, so the version table is read
  # from the package version a Codex build writes there.
  defp codex(version), do: "codex_cli_rs/#{version} (Linux 6.8.0; x86_64) unknown"

  describe "version table" do
    test "clients whose every build prefers the instructions template get the template-only entry" do
      for version <- ["0.148.0", "0.153.4", "0.156.2", "0.157.0", "0.200.0", "1.0.0", "0.148.0-alpha.1"] do
        assert CatalogRepresentation.for_user_agent(codex(version)) == :instructions_template, version
      end
    end

    # findings#258 row 258-34: the clients whose catalog decode contract
    # CodexModelDecodeContract mirrors (0.154.0 through 0.156.1) also lose the
    # entries they would fail to decode; the representation is otherwise the
    # template-only one.
    test "clients inside the verified decode window get the decode-checked template-only entry" do
      for version <- ["0.154.0", "0.154.0-alpha.6.2", "0.155.0", "0.155.1", "0.156.0", "0.156.0-alpha.18", "0.156.1"] do
        assert CatalogRepresentation.for_user_agent(codex(version)) == :decode_checked, version
      end
    end

    test "older, 0.147.0 (alphas 1-5 still require the legacy field) and unparsable versions stay verbatim" do
      for version <- ["0.147.0", "0.147.0-alpha.3", "0.146.1", "0.146.0", "0.99.0", "0.1.0", "", "0.156", "v0.156.0", "latest", "0.156.x", "9999999999.0.0"] do
        assert CatalogRepresentation.for_user_agent(codex(version)) == :verbatim, version
      end
    end

    test "states the version boundary" do
      assert CatalogRepresentation.template_only_since() == "0.148.0"
    end
  end

  describe "for_user_agent/1" do
    test "reads the package version Codex puts after its originator" do
      for user_agent <- [
            "codex_cli_rs/0.156.0 (Mac OS 26.0.0; arm64) xterm-256color",
            "codex_exec/0.156.0 (Linux 6.10.14-linuxkit; aarch64) unknown",
            "Codex Desktop/0.155.0-alpha.16 (Mac OS 26.0.0; arm64) unknown (Codex Desktop; 26.917.11455)",
            "codex_vscode/0.154.0-alpha.6.2 (Windows 10.0.26100; x86_64) unknown (Code; 1.104.0)",
            "codex_cli_rs/0.156.1"
          ] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :decode_checked, user_agent
      end

      for user_agent <- ["codex_cli_rs/0.148.0", "codex_cli_rs/0.153.4 (Linux; x86_64)", "codex_exec/0.157.0 (Linux; aarch64)"] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :instructions_template, user_agent
      end
    end

    test "keeps the verbatim entry for older, 0.147.0 and unparsable agents" do
      for user_agent <- [
            "codex_cli_rs/0.147.0 (Mac OS 15.5.0; arm64) xterm",
            "codex_cli_rs/0.147.0-alpha.6 (Mac OS 15.5.0; arm64) xterm",
            "codex_cli_rs/0.146.1 (Linux 6.8.0; x86_64) unknown",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            "codex_cli_rs",
            "codex_cli_rs/",
            "codex_cli_rs/0.156",
            "codex_cli_rs/0.156.0a",
            "/0.156.0",
            "a/b/0.156.0",
            "codex\ncli/0.156.0",
            "",
            nil,
            156
          ] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :verbatim, inspect(user_agent)
      end
    end

    # Only a Codex build's own `User-Agent` names the catalog decoder that will
    # read the body (findings#206 row 206-447). A Codex build sends
    # `<originator>/<package version> (<os> <os version>; <arch>) <terminal>`
    # (`get_codex_user_agent`, rust-v0.156.1): the originator is `codex_cli_rs`,
    # `codex_exec`, `codex_vscode`, `Codex Desktop` and the other first-party
    # names, or whatever `clientInfo.name` an app-server host gives, and the
    # platform block is always there. Any other agent keeps the verbatim entry,
    # whatever version it reports.
    #
    # Every Codex `User-Agent` production sent to `/models` and
    # `/backend-api/codex/responses` from 2026-09-21 to 2026-09-24, verbatim:
    # the turn's `x-models-etag` is computed from this representation, so a
    # change here changes the catalog ETag every real client holds.
    @production_codex_user_agents [
      "Codex Desktop/0.155.0-alpha.9 (Mac OS 26.3.1; arm64) unknown (codex_chatgpt_android_remote; dev)",
      "Codex Desktop/0.155.0-alpha.9.2 (Mac OS 27.0.0; arm64) unknown (Codex Desktop; 26.915.31945)",
      "Codex Desktop/0.155.0-alpha.9.2 (Mac OS 26.5.1; arm64) unknown (codex_chatgpt_android_remote; dev)",
      "Codex Desktop/0.155.0-alpha.9.2 (Mac OS 26.5.1; arm64) unknown (Codex Desktop; 26.915.31945)",
      "Codex Desktop/0.155.0-alpha.9.2 (Mac OS 27.0.0; arm64) unknown",
      "Codex Desktop/0.155.0-alpha.16 (Mac OS 27.0.0; arm64) unknown (Codex Desktop; 26.917.51856)",
      "Codex Desktop/0.155.0-alpha.16 (Mac OS 27.0.0; arm64) unknown",
      "Codex Desktop/0.155.0-alpha.16.3 (Mac OS 27.0.0; arm64) unknown (Codex Desktop; 26.917.62051)",
      "Codex Desktop/0.155.0-alpha.16.3 (Mac OS 27.0.0; arm64) unknown",
      "codex_vscode/0.154.0-alpha.6.2 (Mac OS 26.3.1; arm64) unknown (VS Code; 26.908.40401)",
      "codex_vscode/0.154.0-alpha.6.2 (Mac OS 26.3.1; arm64) unknown",
      "codex_vscode/0.155.0-alpha.16 (Mac OS 26.3.1; arm64) unknown (VS Code; 26.917.51856)",
      "codex_vscode/0.155.0-alpha.16 (Mac OS 26.3.1; arm64) unknown",
      "codex_vscode/0.155.0-alpha.16.3 (Mac OS 26.3.1; arm64) unknown (VS Code; 26.917.62051)",
      "codex_vscode/0.155.0-alpha.16.3 (Mac OS 26.3.1; arm64) unknown",
      "codex_vscode/0.155.1 (Alpine Linux 3.24.1; aarch64) unknown (codex_vscode; 1)",
      "codex_vscode/0.156.0 (Alpine Linux 3.24.1; aarch64) unknown (codex_vscode; 1)",
      "codex_vscode/0.156.1 (Alpine Linux 3.24.1; aarch64) unknown (codex_vscode; 1)",
      "codex_cli_rs/0.155.0-alpha.9.2 (Mac OS 27.0.0; arm64) unknown",
      "codex_cli_rs/0.155.0-alpha.9.2 (Mac OS 26.5.1; arm64) unknown",
      "codex_cli_rs/0.155.0-alpha.16 (Mac OS 27.0.0; arm64) unknown",
      "codex_cli_rs/0.155.0-alpha.16.3 (Mac OS 27.0.0; arm64) unknown",
      "codex_cli_rs/0.156.0 (Alpine Linux 3.24.1; aarch64) unknown",
      "codex_cli_rs/0.156.1 (Alpine Linux 3.24.1; aarch64) unknown"
    ]

    test "every Codex user agent production sent keeps its decode-checked entry" do
      for user_agent <- @production_codex_user_agents do
        assert CatalogRepresentation.for_user_agent(user_agent) == :decode_checked, user_agent
      end
    end

    test "a non-Codex agent keeps the verbatim entry whatever version it reports" do
      # `curl/8.22.0` and `omp/18.2.8` were sent by production in the same
      # window and selected `instructions_template`; `p23-catalog-measure`
      # selected `decode_checked`.
      for user_agent <- ["curl/8.22.0", "omp/18.2.8", "p23-catalog-measure/0.156.0", "OpenAI/Python 2.24.0", "node", "synthetic-agent/0.155.0 (compatible)"] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :verbatim, user_agent
      end

      assert CatalogRepresentation.for_user_agent("codexcli/0.156.1") == :verbatim
    end

    # An app-server host initializes with its own `clientInfo.name`, which the
    # Codex build uses as the originator, while its catalog fetch sends the
    # build's version as `client_version`; the platform block identifies it.
    test "a Codex build under another originator is recognized by its platform block" do
      assert CatalogRepresentation.for_user_agent("synthetic-app-server-host/0.156.1 (Linux 6.10.14-linuxkit; aarch64) unknown (synthetic-app-server-host; 1.0.0)") == :decode_checked
      assert CatalogRepresentation.for_user_agent("synthetic-app-server-host/0.153.4 (Mac OS 26.0.0; arm64) unknown") == :instructions_template

      for user_agent <- ["codex-tui/0.156.1", "codex_sdk_ts/0.156.1", "CODEX_EXEC/0.156.0"] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :decode_checked, user_agent
      end
    end

    # An app-server host's originator is any header-valid `clientInfo.name`
    # (rust-v0.156.1 `initialize_processor.rs`), so it can hold a slash or run
    # past 64 bytes; its catalog fetch and its turns carry the same
    # `User-Agent`, and the version is the one the platform block follows.
    test "a Codex build whose originator holds a slash or is long is read from the version before its platform block" do
      long = String.duplicate("synthetic-app-server-host-", 4)

      assert CatalogRepresentation.for_user_agent("acme/agent/0.156.1 (Mac OS 26.0.0; arm64) unknown (acme/agent; 1.0.0)") == :decode_checked
      assert CatalogRepresentation.for_user_agent("#{long}/0.156.1 (Linux 6.8.0; x86_64) unknown") == :decode_checked
      assert CatalogRepresentation.for_user_agent("tool/1.2.3-thing/0.153.4 (Linux 6.8.0; x86_64) unknown") == :instructions_template
      assert CatalogRepresentation.for_user_agent("acme/agent/0.147.0 (Mac OS 15.5.0; arm64) iTerm.app/3.7.2 (acme/agent; 0.147.0)") == :verbatim
      assert CatalogRepresentation.for_user_agent("acme/agent/0.156.1-alpha.2 (Windows 10.0.26100; x86_64) unknown") == :decode_checked

      for user_agent <- [
            "acme/agent/0.156.1",
            "acme/agent/0.156.1 (compatible)",
            "acme/agent/0.156 (Linux 6.8.0; x86_64)",
            "acme/agent/0.156.1(Linux 6.8.0; x86_64)",
            "ai-sdk/openai-compatible/3.0.37 ai-sdk/provider-utils/5.0.30 runtime/bun/1.3.13",
            "#{String.duplicate("a", 513)}/0.156.1 (Linux 6.8.0; x86_64)",
            "acme\nagent/0.156.1 (Linux 6.8.0; x86_64)"
          ] do
        assert CatalogRepresentation.for_user_agent(user_agent) == :verbatim, user_agent
      end
    end

    test "for_request/1 reads the request's User-Agent" do
      template_request = RequestOptions.build(%{user_agent: "codex_cli_rs/0.156.0 (Linux; x86_64)"}, "/backend-api/codex/responses", %{})
      verbatim_request = RequestOptions.build(%{user_agent: "codex_cli_rs/0.146.1"}, "/backend-api/codex/responses", %{})
      absent_request = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

      assert CatalogRepresentation.for_request(template_request) == :decode_checked
      assert CatalogRepresentation.for_request(verbatim_request) == :verbatim
      assert CatalogRepresentation.for_request(absent_request) == :verbatim
    end
  end

  describe "apply_to_model/2" do
    @template "synthetic instructions template"

    test "drops base_instructions only when the entry carries a string instructions template" do
      entry = %{
        "slug" => "gpt-synthetic",
        "base_instructions" => @template,
        "model_messages" => %{"instructions_template" => @template, "instructions_variables" => nil}
      }

      assert CatalogRepresentation.apply_to_model(entry, :instructions_template) ==
               Map.delete(entry, "base_instructions")

      assert CatalogRepresentation.apply_to_model(entry, :decode_checked) ==
               Map.delete(entry, "base_instructions")

      assert CatalogRepresentation.apply_to_model(entry, :verbatim) == entry
    end

    test "drops it for a differing or empty template and keeps it when the template is absent, null or not a string" do
      differing = %{
        "slug" => "gpt-synthetic",
        "base_instructions" => "legacy text",
        "model_messages" => %{"instructions_template" => @template}
      }

      assert CatalogRepresentation.apply_to_model(differing, :instructions_template) ==
               Map.delete(differing, "base_instructions")

      empty_template = put_in(differing, ["model_messages", "instructions_template"], "")

      assert CatalogRepresentation.apply_to_model(empty_template, :instructions_template) ==
               Map.delete(empty_template, "base_instructions")

      for model_messages <- [
            nil,
            %{},
            %{"instructions_template" => nil},
            %{"instructions_template" => ["not", "a", "string"]},
            "not-a-map"
          ] do
        entry = %{"slug" => "gpt-synthetic", "base_instructions" => @template, "model_messages" => model_messages}
        assert CatalogRepresentation.apply_to_model(entry, :instructions_template) == entry
      end

      without_messages = %{"slug" => "gpt-synthetic", "base_instructions" => @template}
      assert CatalogRepresentation.apply_to_model(without_messages, :instructions_template) == without_messages

      template_only = %{"slug" => "gpt-synthetic", "model_messages" => %{"instructions_template" => @template}}
      assert CatalogRepresentation.apply_to_model(template_only, :instructions_template) == template_only
    end
  end
end
