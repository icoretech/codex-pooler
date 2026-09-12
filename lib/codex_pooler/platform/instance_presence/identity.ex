defmodule CodexPooler.Platform.InstancePresence.Identity do
  @moduledoc """
  Identity of one running VM: its node name plus the incarnation that minted it.

  The node name alone is not an instance identity. It derives from the pod IP,
  so a container that restarts in place comes back under the same name, and a
  presence row keyed by the name alone is simply refreshed by the successor:
  the row never goes stale and the work the previous VM left behind can never
  be recognised as orphaned. Only a pod that is genuinely replaced, and so gets
  a new address, ever produced an absent owner (measured in production on
  2026-09-12: an in-place restart republished against the same row with the
  row's `started_at` still pointing at the previous VM's start).

  The incarnation is a boot id minted once per VM start and held in
  `:persistent_term`: 80 random bits, because an identity that can repeat is
  exactly the defect being fixed. A start timestamp cannot carry it on its own
  — a restart inside the same clock tick, a clock stepped back by NTP, and a
  restored snapshot all repeat a start time — while a random boot id cannot
  collide across incarnations no matter what the clock does. `started_at` keeps
  its descriptive job and now genuinely marks when *this* incarnation began,
  because each incarnation owns its own row.

  `instance_id` is that row's key, `"<node>#<boot id>"`, one row per VM, so
  incarnations coexist and each ages on its own schedule. Absence therefore
  stays what it was: one row that stopped being refreshed, never an inference
  drawn from a successor publishing under the same name. Keeping the key in a
  single column also keeps a previous release's heartbeat upsert (`ON CONFLICT
  (instance_id)`) working through a rollout, while the `node_name` and
  `boot_id` columns are what recovery joins an attempt's owner against.
  """

  @enforce_keys [:instance_id, :node_name, :boot_id]
  defstruct [:instance_id, :node_name, :boot_id]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          node_name: String.t(),
          boot_id: String.t()
        }

  # A node name is `name@host`; neither half can contain `#`, so the separator
  # can never be ambiguous and an identity can always be read back apart.
  @separator "#"
  @boot_id_key {__MODULE__, :boot_id}
  @boot_id_bytes 10

  @doc """
  Identity of the instance this process runs on.
  """
  @spec local() :: t()
  def local, do: new(local_node_name(), boot_id())

  @spec local_node_name() :: String.t()
  def local_node_name, do: Atom.to_string(node())

  @doc """
  Mints this VM's incarnation.

  `CodexPooler.Application.start/2` calls it before any child starts, so every
  attempt this VM records and every presence row it publishes carry the same
  incarnation. A VM that reaches `boot_id/0` without having started the
  application (a Mix task, an `rpc` shell) mints lazily instead; two lazy
  callers racing would only make an attempt record an owner no heartbeat
  publishes, which reads as *unknown* and falls through to the six-hour sweep
  — the safe direction.
  """
  @spec mint_boot_id!() :: String.t()
  def mint_boot_id! do
    boot_id =
      Base.encode32(:crypto.strong_rand_bytes(@boot_id_bytes), case: :lower, padding: false)

    :persistent_term.put(@boot_id_key, boot_id)
    boot_id
  end

  @spec boot_id() :: String.t()
  def boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      boot_id when is_binary(boot_id) -> boot_id
      _unminted -> mint_boot_id!()
    end
  end

  @spec new(String.t(), String.t()) :: t()
  def new(node_name, boot_id) when is_binary(node_name) and is_binary(boot_id) do
    %__MODULE__{
      instance_id: node_name <> @separator <> boot_id,
      node_name: node_name,
      boot_id: boot_id
    }
  end

  @doc """
  Identity recorded on an owned row, or `nil` when it predates incarnations.

  An attempt written before this change carries a node name and no boot id.
  That pair names no incarnation, so it resolves to `nil` and every caller
  treats it as an owner it cannot reason about.
  """
  @spec owner(String.t() | nil, String.t() | nil) :: t() | nil
  def owner(node_name, boot_id) when is_binary(node_name) and is_binary(boot_id),
    do: new(node_name, boot_id)

  def owner(_node_name, _boot_id), do: nil

  @spec separator() :: String.t()
  def separator, do: @separator
end
