defmodule CodexPoolerWeb.DevFeatures do
  @moduledoc false

  @build_enabled Application.compile_env(:codex_pooler, :dev_features_build_enabled, false)

  alias CodexPooler.Jobs.DevelopmentControls

  @type helper :: %{port: pos_integer(), token: String.t(), origin: String.t()}
  @type live_status ::
          :unavailable
          | :disabled
          | :helper_missing
          | :externally_injected
          | {:helper_unreachable, String.t()}
          | {:ready, String.t()}

  @spec enabled?() :: boolean()

  if @build_enabled do
    def enabled? do
      Application.get_env(:codex_pooler, :dev_features_enabled, false) == true and
        CodexPooler.Dev.support_available?()
    end
  else
    def enabled?, do: false
  end

  @spec impeccable_live_enabled?() :: boolean()

  if @build_enabled do
    def impeccable_live_enabled? do
      enabled?() and
        CodexPooler.InstanceSettings.current().development.impeccable_live_enabled == true
    end
  else
    def impeccable_live_enabled?, do: false
  end

  @spec account_reconciliation_paused?() :: boolean()
  def account_reconciliation_paused?, do: DevelopmentControls.account_reconciliation_paused?()

  @doc """
  Script src for the running Impeccable helper, or `nil` when the app must not
  render its own tag.

  Returns `nil` whenever the toggle is off, no helper handshake file exists, or
  the live injector already placed a tag in the document.
  """
  @spec impeccable_live_script_src() :: String.t() | nil

  if @build_enabled do
    def impeccable_live_script_src do
      with false <- externally_injected?(),
           %{origin: origin, token: token} <- active_helper() do
        "#{origin}/live.js?token=#{URI.encode_www_form(token)}"
      else
        _ -> nil
      end
    end
  else
    def impeccable_live_script_src, do: nil
  end

  @doc """
  Current state of the local Impeccable live setup, for the development admin
  surface. Never carries the helper session token.
  """
  @spec impeccable_live_status() :: live_status()

  if @build_enabled do
    def impeccable_live_status do
      cond do
        not enabled?() -> :unavailable
        not impeccable_live_enabled?() -> :disabled
        true -> helper_status()
      end
    end
  else
    def impeccable_live_status, do: :unavailable
  end

  @spec browser_csp_extra_sources() :: keyword([String.t()])

  if @build_enabled do
    def browser_csp_extra_sources do
      # The allowance follows the helper, not the tag: an injected tag needs the
      # same origin allowed even though the app renders nothing itself.
      case active_helper() do
        %{origin: origin} ->
          [script_src: [origin], connect_src: [origin], img_src: ["blob:"]]

        nil ->
          []
      end
    end
  else
    def browser_csp_extra_sources, do: []
  end

  # These constants are read only by the private helpers below, which are
  # themselves compiled away when dev features are off. Declaring them inside
  # the same guard keeps a release build from carrying five orphaned module
  # attributes, which `--warnings-as-errors` rejects outright.
  if @build_enabled do
    # Impeccable keeps its local live state here. Overridable so the test env
    # can point at a directory that never exists and stay deterministic while a
    # real helper is running on the developer's machine.
    @live_dir ".impeccable/live"

    # The helper writes `{pid, port, token}` to server.json when it starts and
    # deletes the file on a clean stop. Both values have to be read at render
    # time: `/live.js` is token-gated and the token is a fresh UUID per start,
    # so a hardcoded src can only ever be answered with 401. Reading the
    # handshake file also frees the helper from having to bind one fixed port.
    @helper_info_file "server.json"

    # Impeccable's own injector (`live.mjs` / `live-inject.mjs`) writes a
    # literal script tag wrapped in these markers into the files listed by
    # config.json. `live.js` has no double-init guard, so an injected tag plus
    # the app-rendered one means two floating widgets. When a marker is present
    # the injected tag owns the page and this module stands down.
    @live_config_file "config.json"
    @injected_marker "impeccable-live-start"

    @helper_probe_timeout_ms 200

    defp helper_status do
      # A leftover injected tag is reported first: it is the one state that
      # dirties tracked source and duplicates the widget.
      case {externally_injected?(), running_helper()} do
        {true, _} -> :externally_injected
        {false, nil} -> :helper_missing
        {false, %{origin: origin, port: port}} -> reachability_status(origin, port)
      end
    end

    defp reachability_status(origin, port) do
      if helper_reachable?(port), do: {:ready, origin}, else: {:helper_unreachable, origin}
    end

    defp active_helper do
      if impeccable_live_enabled?(), do: running_helper(), else: nil
    end

    defp running_helper do
      with {:ok, body} <- File.read(live_path(@helper_info_file)),
           {:ok, %{"port" => port, "token" => token}} <- Jason.decode(body),
           true <- is_integer(port) and port > 0 and port < 65_536,
           true <- is_binary(token) and token != "" do
        %{port: port, token: token, origin: "http://localhost:#{port}"}
      else
        _ -> nil
      end
    end

    defp externally_injected? do
      Enum.any?(injection_targets(), fn pattern ->
        pattern
        |> project_path()
        |> Path.wildcard()
        |> Enum.any?(&marked?/1)
      end)
    end

    # The live config names the injector's own targets, so this check keeps
    # following them if that config ever changes. No config means no injector is
    # set up for this checkout, so there is nothing to have been injected.
    defp injection_targets do
      with {:ok, body} <- File.read(live_path(@live_config_file)),
           {:ok, %{"files" => files}} <- Jason.decode(body),
           true <- is_list(files) do
        Enum.filter(files, &is_binary/1)
      else
        _ -> []
      end
    end

    defp marked?(path) do
      case File.read(path) do
        {:ok, contents} -> String.contains?(contents, @injected_marker)
        _ -> false
      end
    end

    defp helper_reachable?(port) do
      case :gen_tcp.connect(
             ~c"127.0.0.1",
             port,
             [:binary, active: false],
             @helper_probe_timeout_ms
           ) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _reason} ->
          false
      end
    end

    defp live_path(file) do
      :codex_pooler
      |> Application.get_env(:impeccable_live_dir, @live_dir)
      |> Path.join(file)
      |> project_path()
    end

    defp project_path(relative) do
      case File.cwd() do
        {:ok, cwd} -> Path.expand(relative, cwd)
        _ -> relative
      end
    end
  end
end
