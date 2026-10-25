defmodule CodexPooler.Alerts.Rules.RuleEvaluation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Evaluation.Evaluator
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo

  @type evaluation_rule_result :: {:ok, AlertRule.t()} | {:error, :alert_rule_not_found}

  @spec list_active_rules_for_evaluation(keyword()) :: [AlertRule.t()]
  def list_active_rules_for_evaluation(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 500) |> normalize_evaluation_limit()

    query =
      from rule in AlertRule,
        where: rule.state == "active",
        order_by: [asc: rule.created_at, asc: rule.id],
        limit: ^limit

    query
    |> after_cursor(Keyword.get(opts, :after))
    |> before_cutoff(Keyword.get(opts, :created_before))
    |> Repo.all()
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, {created_at, id}), do: where(query, [rule], rule.created_at > ^created_at or (rule.created_at == ^created_at and rule.id > ^id))
  defp before_cutoff(query, nil), do: query
  defp before_cutoff(query, cutoff), do: where(query, [rule], rule.created_at <= ^cutoff)

  @spec fetch_rule_for_evaluation(Ecto.UUID.t()) :: evaluation_rule_result()
  def fetch_rule_for_evaluation(rule_id) when is_binary(rule_id) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> {:ok, rule}
      nil -> {:error, :alert_rule_not_found}
    end
  end

  def fetch_rule_for_evaluation(_rule_id), do: {:error, :alert_rule_not_found}

  @doc "Records one candidate only while the evaluated rule snapshot is still current."
  @spec record_current_evaluation(AlertRule.t(), (-> :ok | {:error, reason})) :: :ok | {:error, reason} when reason: term()
  def record_current_evaluation(%AlertRule{} = expected, record) do
    Repo.transact(fn ->
      current = Repo.one(from rule in AlertRule, where: rule.id == ^expected.id, lock: "FOR UPDATE")

      # Keep the rule lock through one incident's persistence and enqueue, not
      # the entire candidate set: workers for different rules may share many
      # incidents and must not accumulate their locks in conflicting orders.
      result = if current == expected, do: record.(), else: :ok

      case result do
        :ok -> {:ok, :ok}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec evaluate_rule(AlertRule.t(), Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_rule(rule, opts \\ []), do: Evaluator.evaluate_rule(rule, opts)

  @spec evaluate_active_rules(Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_active_rules(opts \\ []), do: Evaluator.evaluate_active_rules(opts)

  defp normalize_evaluation_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, 1_000)
  end

  defp normalize_evaluation_limit(_limit), do: 500
end
