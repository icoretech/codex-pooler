defmodule CodexPooler.Dev.LocalTarget do
  @moduledoc """
  Explicit local targets for the development seeds and fixture tasks.

  By default the fixtures accept only `codex_pooler_dev` (some also a
  `codex_pooler_relqa_*` isolated QA database) and loopback fake upstreams. A
  local replica, for example a kind cluster whose Postgres is reached through a
  loopback port-forward, needs two explicit widenings and nothing more:

    * `--target-database NAME`: the task runs against `NAME` only when the Repo
      is configured for exactly that database on a loopback host, with no URL
      or socket that could point anywhere else;
    * an upstream base URL the replica's pods can reach: besides the loopback
      default, an origin-only `http` URL whose host is an in-cluster service
      name (`fake-upstream`, `svc.namespace.svc` or
      `svc.namespace.svc.cluster.local`). Public hosts stay refused, so
      synthetic tokens are never sent to a real provider.
  """

  @loopback_hosts ["127.0.0.1", "localhost", "::1"]
  @database_pattern ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @dns_label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @single_label_service Regex.compile!("\\A#{@dns_label}\\z")
  @namespaced_service Regex.compile!("\\A#{@dns_label}\\.#{@dns_label}\\.svc(?:\\.cluster\\.local)?\\z")
  @development_database "codex_pooler_dev"
  @default_fake_upstream_base_url "http://127.0.0.1:4058"

  @doc "The seeds' default synthetic upstream: the local gateway performance fake."
  @spec default_fake_upstream_base_url() :: String.t()
  def default_fake_upstream_base_url, do: @default_fake_upstream_base_url

  @doc """
  Accepts an explicitly named target database only when the Repo configuration
  points at exactly that database over loopback TCP.
  """
  @spec validate_target_database(String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_target_database(target, repo_config) when is_binary(target) and is_list(repo_config) do
    cond do
      not Regex.match?(@database_pattern, target) ->
        {:error, "target database name is invalid"}

      Keyword.get(repo_config, :database) != target ->
        {:error, "target database #{target} does not match the configured Repo database"}

      not loopback_repo?(repo_config) ->
        {:error, "target database #{target} must be reached over a loopback host (a port-forward is fine)"}

      true ->
        :ok
    end
  end

  def validate_target_database(_target, _repo_config), do: {:error, "target database name is invalid"}

  @doc """
  Returns the fixture's receipt path for a target database: the default path
  for the development database, and a per-database path otherwise, so a lease
  held against one database is never reused for, or restored into, another.
  """
  @spec receipt_path(String.t(), String.t(), String.t() | nil) :: String.t()
  def receipt_path(default_path, _receipt_root, nil), do: default_path
  def receipt_path(default_path, _receipt_root, @development_database), do: default_path

  def receipt_path(_default_path, receipt_root, target) when is_binary(target) do
    unless Regex.match?(@database_pattern, target), do: raise(ArgumentError, "target database name is invalid")
    Path.expand(Path.join([receipt_root, "target-" <> target, "setup.json"]), File.cwd!())
  end

  @doc """
  Validates a synthetic upstream origin: loopback, or an in-cluster service a
  replica's pods can reach. `nil` selects `default`.
  """
  @spec upstream_base_url(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def upstream_base_url(nil, default), do: upstream_base_url(default, default)

  def upstream_base_url(value, _default) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "http" and allowed_upstream_host?(uri.host) and is_integer(uri.port) and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, "", "/"] do
      {:ok, String.trim_trailing(value, "/")}
    else
      {:error, "upstream base URL must be an origin-only loopback HTTP URL with a port, or an in-cluster service origin"}
    end
  end

  def upstream_base_url(_value, _default), do: {:error, "upstream base URL is invalid"}

  @doc "True for loopback hosts."
  @spec loopback_host?(term()) :: boolean()
  def loopback_host?(host), do: host in @loopback_hosts

  defp allowed_upstream_host?(host) when is_binary(host) do
    loopback_host?(host) or Regex.match?(@single_label_service, host) or Regex.match?(@namespaced_service, host)
  end

  defp allowed_upstream_host?(_host), do: false

  # A URL or socket in the repo config could point anywhere, so either one
  # refuses the target regardless of the hostname.
  defp loopback_repo?(repo_config) do
    loopback_host?(Keyword.get(repo_config, :hostname)) and is_nil(Keyword.get(repo_config, :url)) and
      is_nil(Keyword.get(repo_config, :socket_dir)) and is_nil(Keyword.get(repo_config, :socket))
  end
end
