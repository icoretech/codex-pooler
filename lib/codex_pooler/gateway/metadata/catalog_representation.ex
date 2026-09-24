defmodule CodexPooler.Gateway.Metadata.CatalogRepresentation do
  @moduledoc """
  Chooses how a served native Codex catalog entry carries its instructions.

  The upstream catalog carries every model's instructions twice: once as
  `model_messages.instructions_template` and once mirrored into the deprecated
  top-level `base_instructions` for older clients. Codex clients whose catalog
  decoder prefers the template (every build reporting `0.148.0` or newer) ignore
  `base_instructions` whenever the template is present, so those clients get
  entries without the duplicate. Older clients, and requests whose version is
  absent or unparsable, keep the entry verbatim: up to 0.146.x the field is a
  required string, and 0.147.0 alphas 1-5 report the whole version `0.147.0`
  while still requiring it, so 0.147.0 itself stays on the verbatim entry.

  The representation is part of the body, so the catalog ETag is the digest of
  the representation actually served. The `/models` request and every
  Responses turn select it with the same function from the same input, the
  request's `User-Agent`, so the `x-models-etag` a turn carries is the ETag
  that client's own catalog fetch received and never triggers a catalog
  refetch loop (findings#206 row 206-459, findings#258 row 258-102). The
  catalog fetch's `client_version` query value is not read: a turn does not
  carry it, and a Codex build sends the same package version in both. The
  catalog body therefore varies with the `User-Agent`.

  Clients inside the window `CodexModelDecodeContract` was verified against
  get `:decode_checked`: the template-only entries minus every entry that
  client would fail to decode, because one such entry makes it discard the
  whole catalog (findings#258 row 258-34). Clients outside the window get the
  unchecked catalog, since the contract is not known to hold for them.
  """

  alias CodexPooler.Gateway.Metadata.CodexModelDecodeContract
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @type t :: :verbatim | :instructions_template | :decode_checked

  # First whole version whose every build decodes `model_messages` with the
  # template taking precedence (`deserialize_model_infos_with_legacy_base`
  # landed in rust-v0.147.0-alpha.6; alphas 1-5 still report `0.147.0`).
  @template_only_since {0, 148, 0}

  @user_agent_pattern ~r/\A([^\/\x00-\x1f\x7f]{1,64})\/(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?=[\s(+-]|\z)(.*)\z/s

  # A Codex build's `User-Agent` (`get_codex_user_agent`, rust-v0.156.1) is
  # `<originator>/<package version> (<os> <os version>; <arch>) <terminal>`.
  # The originator is a first-party name (`codex_cli_rs`, `codex_exec`,
  # `codex-tui`, `codex_vscode`, `codex_sdk_ts`, `Codex Desktop`, ...) or the
  # `clientInfo.name` an app-server host initializes with, and the platform
  # block is always present; the host's catalog fetch and its turns carry the
  # same `User-Agent` (findings#206 row 206-447).
  @codex_originator_pattern ~r/\Acodex(?:[ _-]|\z)/i
  @codex_platform_block_pattern ~r/\A\S*\s\([^();]+;[^();]+\)/

  # An app-server host may name the originator with any header-valid
  # `clientInfo.name` (`initialize_processor.rs`, rust-v0.156.1), including one
  # with a slash or longer than 64 bytes, which the pattern above cannot split
  # from the version. The version is then the first `/<x.y.z>` that the
  # platform block follows directly; a later product token such as a
  # terminal's `iTerm.app/3.7.2 (codex-tui; 0.154.0)` is never reached.
  @platform_block_user_agent_pattern ~r/\A[^\x00-\x1f\x7f]{1,512}?\/(\d{1,9})\.(\d{1,9})\.(\d{1,9})(?:[-+][0-9A-Za-z.+-]{0,64})?\s\([^();\x00-\x1f\x7f]+;[^();\x00-\x1f\x7f]+\)/

  @spec template_only_since() :: String.t()
  def template_only_since do
    {major, minor, patch} = @template_only_since
    "#{major}.#{minor}.#{patch}"
  end

  @doc """
  Representation for a request whose `User-Agent` is a Codex build's
  `<originator>/<version> ...`: a first-party Codex originator, or any
  originator (including one with a slash or longer than 64 bytes) followed by
  Codex's `(<os> <os version>; <arch>)` platform block.
  Every other agent (`curl/8.22.0`, an SDK, a probe) keeps the verbatim entry
  whatever version it reports, because no Codex catalog decoder reads its body.
  """
  @spec for_user_agent(term()) :: t()
  def for_user_agent(user_agent) when is_binary(user_agent) do
    case codex_build_version(user_agent) do
      [major, minor, patch] -> for_whole_version(major, minor, patch)
      nil -> :verbatim
    end
  end

  def for_user_agent(_user_agent), do: :verbatim

  @doc "Representation for a `/models` request or a Responses turn, from its `User-Agent`."
  @spec for_request(RequestOptions.t()) :: t()
  def for_request(%RequestOptions{request_metadata: %{user_agent: user_agent}}),
    do: for_user_agent(user_agent)

  def for_request(%RequestOptions{}), do: :verbatim

  @doc """
  Applies the representation to one projected catalog entry.

  Only an entry whose `model_messages.instructions_template` is a string loses
  `base_instructions`; an entry without the template keeps it, because the
  decoder promotes it into the template and rejects the whole catalog when both
  are missing.
  """
  @spec apply_to_model(map(), t()) :: map()
  def apply_to_model(model, representation)
      when is_map(model) and representation in [:instructions_template, :decode_checked] do
    case model do
      %{"model_messages" => %{"instructions_template" => template}, "base_instructions" => _base}
      when is_binary(template) ->
        Map.delete(model, "base_instructions")

      _other ->
        model
    end
  end

  def apply_to_model(model, :verbatim) when is_map(model), do: model

  defp codex_build_version(user_agent) do
    with [originator, major, minor, patch, rest] <- Regex.run(@user_agent_pattern, user_agent, capture: :all_but_first),
         true <- codex_user_agent?(originator, rest) do
      [major, minor, patch]
    else
      _other -> Regex.run(@platform_block_user_agent_pattern, user_agent, capture: :all_but_first)
    end
  end

  defp codex_user_agent?(originator, rest),
    do: Regex.match?(@codex_originator_pattern, originator) or Regex.match?(@codex_platform_block_pattern, rest)

  defp for_whole_version(major, minor, patch) do
    version = {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}

    cond do
      CodexModelDecodeContract.verified_version?(version) -> :decode_checked
      version >= @template_only_since -> :instructions_template
      true -> :verbatim
    end
  end
end
