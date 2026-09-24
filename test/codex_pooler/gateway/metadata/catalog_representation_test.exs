defmodule CodexPooler.Gateway.Metadata.CatalogRepresentationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Metadata.CatalogRepresentation
  alias CodexPooler.Gateway.Payloads.RequestOptions

  describe "for_client_version/1" do
    test "clients whose every build prefers the instructions template get the template-only entry" do
      for version <- ["0.148.0", "0.153.4", "0.156.2", "0.157.0", "0.200.0", "1.0.0", "0.148.0-alpha.1"] do
        assert CatalogRepresentation.for_client_version(version) == :instructions_template, version
      end
    end

    # findings#258 row 258-34: the clients whose catalog decode contract
    # CodexModelDecodeContract mirrors (0.154.0 through 0.156.1) also lose the
    # entries they would fail to decode; the representation is otherwise the
    # template-only one.
    test "clients inside the verified decode window get the decode-checked template-only entry" do
      for version <- ["0.154.0", "0.154.0-alpha.6.2", "0.155.0", "0.155.1", "0.156.0", "0.156.0-alpha.18", "0.156.1"] do
        assert CatalogRepresentation.for_client_version(version) == :decode_checked, version
      end
    end

    test "older, 0.147.0 (alphas 1-5 still require the legacy field), absent and unparsable versions stay verbatim" do
      for version <- [
            "0.147.0",
            "0.147.0-alpha.3",
            "0.146.1",
            "0.146.0",
            "0.99.0",
            "0.1.0",
            nil,
            "",
            "0.156",
            "v0.156.0",
            "0.156.0 ",
            "latest",
            "0.156.0\n",
            "0.156.x",
            "9999999999.0.0",
            ["0.156.0"],
            %{"version" => "0.156.0"},
            156
          ] do
        assert CatalogRepresentation.for_client_version(version) == :verbatim, inspect(version)
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
