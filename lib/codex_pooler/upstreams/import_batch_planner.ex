defmodule CodexPooler.Upstreams.ImportBatchPlanner do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.{CredentialFencing, IdentityLifecycle, IdentitySlotLock}
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @stale_import_message "credentials changed after import preparation; submit the current auth data again"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type target :: {:existing, Ecto.UUID.t()} | {:new, non_neg_integer()}
  @type plan :: [{PreparedAccount.t(), target()}]
  @type diagnostics :: %{
          required(:advisory_resources) => [String.t()],
          required(:candidate_loads) => %{
            required(:account) => non_neg_integer(),
            required(:email) => non_neg_integer()
          },
          required(:candidate_domains) => %{
            required(:account) => non_neg_integer(),
            required(:email) => non_neg_integer()
          },
          required(:expected_identity_count) => non_neg_integer(),
          required(:current_identity_count) => non_neg_integer(),
          required(:locked_identity_count) => non_neg_integer(),
          required(:locked_assignment_count) => non_neg_integer(),
          required(:locked_active_secret_count) => non_neg_integer()
        }

  @doc false
  @spec plan_prepared_batch_in_transaction(Scope.t(), Pool.t(), [PreparedAccount.t()]) ::
          {:ok, plan(), IdentitySlotLock.locked_rows(), diagnostics()} | {:error, term()}
  def plan_prepared_batch_in_transaction(%Scope{} = scope, %Pool{} = pool, prepared_accounts)
      when is_list(prepared_accounts) do
    if Repo.in_transaction?() do
      with {:ok, prepared_accounts} <- validate_prepared(prepared_accounts, scope, pool) do
        build_plan(prepared_accounts)
      end
    else
      {:error,
       lifecycle_error(:transaction_required, "batch import requires a caller-owned transaction")}
    end
  end

  def plan_prepared_batch_in_transaction(_scope, _pool, _prepared_accounts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @spec validate_prepared_batch_in_transaction(Scope.t(), Pool.t(), [PreparedAccount.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def validate_prepared_batch_in_transaction(%Scope{} = _scope, %Pool{} = _pool, []),
    do: {:ok, 0}

  def validate_prepared_batch_in_transaction(%Scope{} = scope, %Pool{} = pool, prepared_accounts)
      when is_list(prepared_accounts) do
    if Repo.in_transaction?() do
      with {:ok, prepared_accounts} <- validate_prepared(prepared_accounts, scope, pool),
           {:ok, plan, _locked_rows, _diagnostics} <- build_plan(prepared_accounts) do
        {:ok, length(plan)}
      end
    else
      {:error,
       lifecycle_error(:transaction_required, "batch import requires a caller-owned transaction")}
    end
  end

  def validate_prepared_batch_in_transaction(_scope, _pool, _prepared_accounts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @doc false
  @spec diagnose_prepared_batch_in_transaction(Scope.t(), Pool.t(), [PreparedAccount.t()]) ::
          {:ok, plan(), diagnostics()} | {:error, term()}
  def diagnose_prepared_batch_in_transaction(%Scope{} = _scope, %Pool{} = _pool, []),
    do: {:ok, [], empty_diagnostics()}

  def diagnose_prepared_batch_in_transaction(%Scope{} = scope, %Pool{} = pool, prepared_accounts)
      when is_list(prepared_accounts) do
    if Repo.in_transaction?() do
      with {:ok, prepared_accounts} <- validate_prepared(prepared_accounts, scope, pool),
           {:ok, plan, _locked_rows, diagnostics} <- build_plan(prepared_accounts) do
        {:ok, plan, diagnostics}
      end
    else
      {:error,
       lifecycle_error(:transaction_required, "batch import requires a caller-owned transaction")}
    end
  end

  def diagnose_prepared_batch_in_transaction(_scope, _pool, _prepared_accounts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  defp validate_prepared(prepared_accounts, scope, pool) do
    Enum.reduce_while(prepared_accounts, {:ok, []}, fn
      %PreparedAccount{import_witness: %{incoming: incoming}} = prepared, {:ok, validated}
      when is_map(incoming) ->
        case PreparedAccount.validate(prepared, scope, pool) do
          {:ok, prepared} -> {:cont, {:ok, [prepared | validated]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _prepared, _validated ->
        {:halt, {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}}
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp build_plan(prepared_accounts) do
    declared_attrs = Enum.flat_map(prepared_accounts, &witness_attrs/1)

    candidate_domains = %{
      account:
        declared_attrs
        |> Enum.map(&IdentitySlotLock.normalize(&1).chatgpt_account_id)
        |> compact()
        |> length(),
      email:
        declared_attrs
        |> Enum.map(&IdentitySlotLock.normalize(&1).account_email)
        |> compact()
        |> length()
    }

    email_candidates = load_email_candidates(declared_attrs)

    account_attrs =
      declared_attrs ++
        Enum.map(email_candidates, &IdentitySlotLock.normalize(Map.from_struct(&1)))

    account_candidates = load_account_candidates(account_attrs)
    closure_attrs = account_attrs ++ Enum.map(account_candidates, &Map.from_struct/1)
    locked_resources = IdentitySlotLock.lock_slots!(closure_attrs)
    candidates_before_lock = load_candidates(closure_attrs)

    with :ok <- validate_declared_closure(candidates_before_lock, locked_resources) do
      expected_ids = Enum.map(prepared_accounts, &expected_identity_id/1)

      locked_rows =
        IdentitySlotLock.lock_identity_rows!(
          expected_ids ++ Enum.map(candidates_before_lock, & &1.id)
        )

      candidates_after_lock = load_candidates(closure_attrs)

      with :ok <- validate_declared_closure(candidates_after_lock, locked_resources),
           :ok <- validate_initial_witnesses(prepared_accounts, candidates_after_lock),
           {:ok, plan} <- simulate(prepared_accounts, candidates_after_lock) do
        diagnostics = %{
          advisory_resources: locked_resources,
          candidate_loads: %{
            account: if(candidate_domains.account == 0, do: 0, else: 3),
            email: if(candidate_domains.email == 0, do: 0, else: 3)
          },
          candidate_domains: candidate_domains,
          expected_identity_count: expected_ids |> compact() |> length(),
          current_identity_count: length(candidates_after_lock),
          locked_identity_count: length(locked_rows.identities),
          locked_assignment_count: length(locked_rows.assignments),
          locked_active_secret_count: length(locked_rows.secrets)
        }

        {:ok, plan, locked_rows, diagnostics}
      end
    end
  end

  defp empty_diagnostics do
    %{
      advisory_resources: [],
      candidate_loads: %{account: 0, email: 0},
      candidate_domains: %{account: 0, email: 0},
      expected_identity_count: 0,
      current_identity_count: 0,
      locked_identity_count: 0,
      locked_assignment_count: 0,
      locked_active_secret_count: 0
    }
  end

  defp validate_initial_witnesses(prepared_accounts, candidates) do
    Enum.reduce_while(prepared_accounts, :ok, fn prepared, :ok ->
      with {:ok, selected} <- choose_identity(prepared.attrs, candidates),
           {:ok, current} <- current_evidence(selected),
           true <- current == prepared.import_witness.persisted do
        {:cont, :ok}
      else
        {:error, %{code: :invalid_credential_epoch} = reason} -> {:halt, {:error, reason}}
        _changed -> {:halt, {:error, stale_import_error()}}
      end
    end)
  end

  defp simulate(prepared_accounts, candidates) do
    prepared_accounts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], candidates}, &simulate_entry/2)
    |> case do
      {:ok, plan, _projected} -> {:ok, Enum.reverse(plan)}
      {:error, _reason} = error -> error
    end
  end

  defp simulate_entry({prepared, index}, {:ok, plan, projected}) do
    case choose_identity(prepared.attrs, projected) do
      {:ok, selected} ->
        target = if selected, do: {:existing, selected.id}, else: {:new, index}
        projected = project_identity(projected, selected, prepared.attrs, target)
        {:cont, {:ok, [{prepared, target} | plan], projected}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp load_candidates(attrs) do
    (load_email_candidates(attrs) ++ load_account_candidates(attrs))
    |> Map.new(&{&1.id, &1})
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp load_email_candidates(attrs) do
    emails = attrs |> Enum.map(&IdentitySlotLock.normalize(&1).account_email) |> compact()

    if emails == [] do
      []
    else
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.account_email in ^emails,
          order_by: [asc: identity.account_email, asc: identity.created_at, asc: identity.id]
      )
    end
  end

  defp load_account_candidates(attrs) do
    account_ids =
      attrs |> Enum.map(&IdentitySlotLock.normalize(&1).chatgpt_account_id) |> compact()

    if account_ids == [] do
      []
    else
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.chatgpt_account_id in ^account_ids,
          order_by: [asc: identity.chatgpt_account_id, asc: identity.created_at, asc: identity.id]
      )
    end
  end

  @doc false
  @spec validate_declared_closure([UpstreamIdentity.t()], [String.t()]) ::
          :ok | {:error, lifecycle_error()}
  def validate_declared_closure(candidates, locked_resources)
      when is_list(candidates) and is_list(locked_resources) do
    candidate_resources =
      candidates
      |> Enum.flat_map(&(Map.from_struct(&1) |> IdentitySlotLock.advisory_resources()))
      |> Enum.uniq()

    if Enum.all?(candidate_resources, &(&1 in locked_resources)) do
      :ok
    else
      {:error, stale_import_error()}
    end
  end

  defp choose_identity(attrs, candidates) do
    case IdentityLifecycle.select_upsert_identity_from_candidates(attrs, candidates) do
      {:ok, selected} -> {:ok, selected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_identity(candidates, nil, attrs, {:new, index}) do
    projected =
      struct!(UpstreamIdentity, %{
        id: projected_identity_id(index),
        chatgpt_account_id: attrs.chatgpt_account_id,
        chatgpt_user_id: attrs.chatgpt_user_id,
        account_email: normalize_email(attrs.account_email),
        account_label: attrs.account_label,
        workspace_id: attrs.workspace_id,
        workspace_label: attrs.workspace_label,
        seat_type: attrs.seat_type,
        plan_label: attrs.plan_label,
        plan_family: plan_family(attrs.plan_label),
        status: "active",
        created_at: DateTime.from_unix!(index, :microsecond),
        metadata: %{"credential_epoch" => 1}
      })

    [projected | candidates]
  end

  defp project_identity(candidates, %UpstreamIdentity{id: id} = selected, attrs, _target) do
    projected = %{
      selected
      | chatgpt_account_id: attrs.chatgpt_account_id,
        chatgpt_user_id: attrs.chatgpt_user_id,
        account_email: normalize_email(attrs.account_email),
        workspace_id: attrs.workspace_id,
        workspace_label: attrs.workspace_label,
        seat_type: attrs.seat_type,
        plan_label: attrs.plan_label,
        plan_family: plan_family(attrs.plan_label),
        status: "active"
    }

    Enum.map(candidates, fn
      %UpstreamIdentity{id: ^id} -> projected
      identity -> identity
    end)
  end

  defp current_evidence(nil), do: {:ok, :absent}

  defp current_evidence(%UpstreamIdentity{} = identity) do
    with {:ok, epoch} <- CredentialFencing.validate_current_credential_epoch(identity) do
      normalized = IdentitySlotLock.normalize(Map.from_struct(identity))

      {:ok,
       Map.merge(normalized, %{
         identity_id: identity.id,
         credential_epoch: epoch,
         status: identity.status
       })}
    end
  end

  defp witness_attrs(%PreparedAccount{attrs: attrs, import_witness: %{persisted: :absent}}),
    do: [attrs]

  defp witness_attrs(%PreparedAccount{attrs: attrs, import_witness: %{persisted: persisted}}),
    do: [attrs, persisted]

  defp expected_identity_id(%PreparedAccount{import_witness: %{persisted: :absent}}), do: nil

  defp expected_identity_id(%PreparedAccount{import_witness: %{persisted: persisted}}),
    do: persisted.identity_id

  defp compact(values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  defp projected_identity_id(index) do
    "00000000-0000-0000-0000-#{index |> Integer.to_string() |> String.pad_leading(12, "0")}"
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(_value), do: nil

  defp plan_family(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp plan_family(_value), do: nil
  defp stale_import_error, do: lifecycle_error(:stale_import, @stale_import_message)
  defp lifecycle_error(code, message), do: %{code: code, message: message}
end
