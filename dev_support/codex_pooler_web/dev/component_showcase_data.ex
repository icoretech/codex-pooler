defmodule CodexPoolerWeb.Dev.ComponentShowcaseData do
  @moduledoc false

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Observatory.Presentation

  def primitive_variants do
    %{
      metrics: [
        %{
          id: "neutral",
          icon: "hero-chart-bar",
          label: "Requests",
          value: "1,284",
          tone: :neutral
        },
        %{id: "primary", icon: "hero-bolt", label: "Input", value: "8.4M", tone: :primary},
        %{
          id: "success",
          icon: "hero-check-circle",
          label: "Success",
          value: "97.5%",
          tone: :success
        },
        %{id: "warning", icon: "hero-clock", label: "Pending", value: "7", tone: :warning},
        %{id: "error", icon: "hero-x-circle", label: "Failures", value: "32", tone: :error}
      ],
      statuses: [
        %{id: "active", value: :active, label: "Active"},
        %{id: "paused", value: :paused, label: "Paused"},
        %{id: "failed", value: :failed, label: "Failed"},
        %{id: "pending", value: :pending, label: "Pending"},
        %{id: "unknown", value: :unknown, label: "Unknown"}
      ],
      plans: [
        %{id: "free", label: "Free"},
        %{id: "pro", label: "Pro"},
        %{id: "team", label: "Team"},
        %{id: "enterprise", label: "Enterprise"},
        %{id: "generated", label: "Sample"},
        %{id: "unknown", label: nil}
      ],
      redacted: [
        %{id: "ok", status: :ok},
        %{id: "warning", status: :warning},
        %{id: "error", status: :error},
        %{id: "redacted", status: :redacted}
      ],
      buttons: [
        %{id: "primary", icon: "hero-plus", label: "Primary", variant: :primary},
        %{
          id: "secondary",
          icon: "hero-adjustments-horizontal",
          label: "Secondary",
          variant: :secondary
        },
        %{id: "danger", icon: "hero-trash", label: "Danger", variant: :danger},
        %{id: "ghost", icon: "hero-arrow-path", label: "Ghost", variant: :ghost}
      ],
      notices: [
        %{id: "info", title: "Information", tone: :info},
        %{id: "success", title: "Succeeded", tone: :success},
        %{id: "warning", title: "Attention", tone: :warning},
        %{id: "error", title: "Unavailable", tone: :error}
      ],
      dropdown_items: [
        %{id: "secondary", label: "Inspect", icon: "hero-eye", variant: :secondary},
        %{id: "warning", label: "Pause", icon: "hero-pause", variant: :warning},
        %{id: "positive", label: "Reactivate", icon: "hero-play", variant: :positive},
        %{id: "danger", label: "Delete", icon: "hero-trash", variant: :danger}
      ]
    }
  end

  def observatory_presentation do
    Presentation.build(%{
      window: %{key: "24h"},
      accounting: %{status: "partial"},
      totals: %{
        requests: %{total: 16, succeeded: 12, failed: 3, in_progress: 1},
        tokens: %{input: 12_000, cached_input: 4_000, total: 18_400},
        cost: %{
          settled: %{status: "settled", micros: 1_250_000},
          estimated: %{status: "estimated", micros: 300_000},
          confidence: "partial"
        }
      },
      trends: %{
        success_rate: %{delta: -2.5},
        cache_rate: %{delta: 4.0}
      },
      models: [
        %{
          label: "alpha-model",
          request_count: 412,
          total_tokens: 10_000,
          share_percent: 57.1,
          cost_micros: 4_820_000
        },
        %{
          label: "beta-model",
          request_count: 205,
          total_tokens: 5_000,
          share_percent: 28.6,
          cost_micros: 2_110_000
        },
        %{
          label: "gamma-model",
          request_count: 96,
          total_tokens: 2_500,
          share_percent: 14.3,
          cost_micros: 940_000
        }
      ],
      buckets: [
        bucket(~U[2026-07-17 11:00:00Z], 7_000, 2_000, 9),
        bucket(~U[2026-07-17 12:00:00Z], 5_000, 2_000, 7)
      ],
      model_buckets: [
        %{bucket_index: 0, label: "alpha-model", total_tokens: 5_500},
        %{bucket_index: 1, label: "alpha-model", total_tokens: 4_000},
        %{bucket_index: 0, label: "beta-model", total_tokens: 2_800},
        %{bucket_index: 1, label: "beta-model", total_tokens: 2_000},
        %{bucket_index: 0, label: "gamma-model", total_tokens: 1_200},
        %{bucket_index: 1, label: "gamma-model", total_tokens: 1_000}
      ],
      outcomes: [
        outcome(~U[2026-07-17 12:00:00Z], "succeeded", "alpha-model", nil),
        outcome(~U[2026-07-17 11:58:00Z], "in_progress", "beta-model", nil),
        outcome(~U[2026-07-17 11:54:00Z], "failed", "gamma-model", "timeout"),
        outcome(~U[2026-07-17 11:50:00Z], "succeeded", "alpha-model", nil),
        outcome(~U[2026-07-17 11:46:00Z], "succeeded", "beta-model", nil),
        outcome(~U[2026-07-17 11:42:00Z], "failed", "gamma-model", "rate_limited"),
        outcome(~U[2026-07-17 11:38:00Z], "succeeded", "alpha-model", nil),
        outcome(~U[2026-07-17 11:34:00Z], "in_progress", "beta-model", nil),
        outcome(~U[2026-07-17 11:30:00Z], "succeeded", "gamma-model", nil),
        outcome(~U[2026-07-17 11:26:00Z], "succeeded", "alpha-model", nil),
        outcome(~U[2026-07-17 11:22:00Z], "failed", "beta-model", "upstream_error"),
        outcome(~U[2026-07-17 11:18:00Z], "succeeded", "gamma-model", nil)
      ]
    })
  end

  def account_card do
    identity_id = "00000000-0000-4000-8000-000000000042"

    %{
      identity: %UpstreamIdentity{
        id: identity_id,
        account_label: "Sample account",
        chatgpt_account_id: nil,
        status: "paused"
      },
      label: "Sample account",
      plan_label: "Pro",
      plan_reported?: true,
      refresh_status: "succeeded",
      token_refresh_label: "token refresh completed",
      refresh_job_state: nil,
      quota_refresh_status: "completed",
      auth_fresh_label: "auth imported recently",
      auth_verified_label: "auth verified recently",
      identity_observability: %{
        reconciliation: %{
          status: nil,
          code: nil,
          message: nil,
          finished_at: nil,
          attempt_age: nil
        },
        last_successful_quota_refresh_at: nil,
        last_successful_quota_refresh_age: nil,
        quota_evidence_at: nil,
        quota_evidence_age: nil,
        credential_expiry: %{state: "available", expires_at: nil, age: nil}
      },
      access_token_label: "access token expiry not reported",
      reauth_required?: false,
      reauth_reason_code: nil,
      reauth_reason_message: nil,
      token_burn: %{
        level: 2,
        label: "x2",
        title: "last 5m: 1,200 tokens; previous 1h: 4,800 tokens",
        recent_tokens: 1_200,
        baseline_tokens: 4_800
      },
      assignments: [],
      quota_readiness: %{
        state: "known",
        label: "Routing ready",
        tone: :success,
        routing_ready_now?: true,
        reason_codes: [],
        primary_window: nil,
        primary_30d_window: nil,
        weekly_window: nil
      },
      quota_limits: quota_limits(),
      saved_resets: saved_resets(),
      saved_reset_policy: saved_reset_policy(true)
    }
  end

  def quota_limits do
    [
      quota_limit("success", "Weekly", "82%", "82", Decimal.new("82"), false),
      quota_limit("warning", "Five hour", "48%", "48", Decimal.new("48"), false),
      quota_limit("error", "Burst", "18%", "18", Decimal.new("18"), false),
      quota_limit("neutral", "Unreported", "–", "0", nil, false),
      quota_limit("credit", "Credit backed", "64%", "64", Decimal.new("64"), true)
    ]
  end

  def saved_resets do
    %{
      reported?: true,
      available_count: 3,
      label: "3 saved resets",
      next_expires_label: "12 days",
      next_expires_title: "Synthetic expiry in 12 days",
      reset_lifecycle: nil
    }
  end

  def saved_reset_policy(enabled), do: %{enabled?: enabled}

  def protocols do
    for {id, transport} <- [
          {"websocket", "websocket"},
          {"sse", "http_sse"},
          {"multipart", "http_multipart"},
          {"json", "http_json"},
          {"fallback", "other"}
        ] do
      %{id: id, request_log: %{id: id, transport: transport}}
    end
  end

  defp bucket(started_at, input, cached_input, requests) do
    %{
      started_at: started_at,
      tokens: %{input: input, cached_input: cached_input, total: input + div(input, 2)},
      requests: %{total: requests},
      cost: %{
        settled: %{status: "settled", micros: input * 100},
        estimated: %{status: "estimated", micros: 0}
      }
    }
  end

  defp outcome(timestamp, status, model, code) do
    %{
      timestamp: timestamp,
      status: status,
      model: model,
      endpoint_class: "responses",
      code: code,
      total_tokens: 640,
      cost: %{status: "settled", micros: 20_000}
    }
  end

  defp quota_limit(id, label, percent_label, percent_value, percent, credit_backed) do
    %{
      id: id,
      key: id,
      label: label,
      percent_label: percent_label,
      percent_value: percent_value,
      percent: percent,
      credit_backed: credit_backed,
      count_label: nil,
      reset_label: nil,
      reset_title: nil
    }
  end
end
