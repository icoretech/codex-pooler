defmodule CodexPooler.Alerts.RuleEvaluation do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Evaluator
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo

  @type evaluation_rule_result :: {:ok, AlertRule.t()} | {:error, :alert_rule_not_found}

  @spec list_active_rules_for_evaluation(keyword()) :: [AlertRule.t()]
  def list_active_rules_for_evaluation(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, 500) |> normalize_evaluation_limit()

    Repo.all(
      from rule in AlertRule,
        where: rule.state == "active",
        order_by: [asc: rule.created_at, asc: rule.id],
        limit: ^limit
    )
  end

  @spec fetch_rule_for_evaluation(Ecto.UUID.t()) :: evaluation_rule_result()
  def fetch_rule_for_evaluation(rule_id) when is_binary(rule_id) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> {:ok, rule}
      nil -> {:error, :alert_rule_not_found}
    end
  end

  def fetch_rule_for_evaluation(_rule_id), do: {:error, :alert_rule_not_found}

  @spec evaluate_rule(AlertRule.t(), Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_rule(rule, opts \\ []), do: Evaluator.evaluate_rule(rule, opts)

  @spec evaluate_active_rules(Evaluator.evaluation_opts()) :: [Evaluator.candidate()]
  def evaluate_active_rules(opts \\ []), do: Evaluator.evaluate_active_rules(opts)

  defp normalize_evaluation_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, 1_000)
  end

  defp normalize_evaluation_limit(_limit), do: 500
end
