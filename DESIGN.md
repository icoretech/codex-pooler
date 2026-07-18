# Design System: Codex Pooler

This document is the source-linked contract for the Codex Pooler web UI. Every
component section cites the module that renders it; every markup example is
extracted from that source. When this document and the code disagree, the code
wins and this file must be corrected in the same change.

Token source of truth: [`assets/css/app.css`](assets/css/app.css) (Tailwind v4 +
daisyUI 5 theme plugins). Verified against the live app (light and dark) on
2026-07-17 across `/admin/upstreams`, `/admin/stats`, `/admin/api-keys`, and
`/admin/request-logs`.

Contents:

1. [Atmosphere](#1-atmosphere)
2. [Color](#2-color)
3. [Typography](#3-typography)
4. [Spacing and layout](#4-spacing-and-layout)
5. [Components — current admin system](#5-components--current-admin-system)
6. [Components — API Key Observatory extension](#6-components--api-key-observatory-extension)
7. [Motion](#7-motion)
8. [Depth](#8-depth)
9. [Accessibility and design rules](#9-accessibility-and-design-rules)

---

## 1. Atmosphere

**Creative north star: "The Operator Bench."** Codex Pooler is a compact
operations surface for trusted users who inspect routing, upstream capacity,
API keys, request history, quota evidence, and maintenance state without ever
seeing sensitive payloads. The interface should feel like a well-labeled bench
of controls: precise, flat, readable, built for repeated use under pressure.

Key characteristics, all observable in the current admin pages:

- **Dense but scan-friendly.** Cards, definition lists, and zebra rows carry
  many small facts; type stays legible because labels are uppercase micro-text
  and values are tabular numerals.
- **Orange is scarce.** `--color-primary` (#ff9900) marks the primary action,
  the active nav item, selected states, and section eyebrows — never
  decoration. If two things on one panel are orange, one of them is wrong.
- **Flat first.** Separation comes from `border-base-300` hairlines and tonal
  `base-200` washes. Shadows are reserved for overlays (dropdowns, drawers,
  dialogs, toasts).
- **Text plus color.** Every status is written out (chip label, `sr-only`
  prefix, `title` attribute); color only reinforces it.
- **Metadata only.** Secrets, prompts, payloads, and tokens never appear in
  the UI, in examples, or in screenshots. Evidence is fingerprinted or
  redacted (`redacted_status_badge`, sanitized drawer rows).

Anti-goals (enforced, not aspirational): no glassmorphism, no neon/terminal
styling, no gradient text, no decorative grid backgrounds, no oversized hero
typography on admin screens, no equal-tile KPI boilerplate as filler.

## 2. Color

Both themes are daisyUI theme plugins in `assets/css/app.css`. The `dark`
variant is selected by `data-theme="dark"` on `<html>` (a custom variant maps
Tailwind's `dark:` to it); `light` is the default, `dark` is `prefersdark`.

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `--color-base-100` | `oklch(98% 0 0)` | `#0e0e0e` | Card/work surface |
| `--color-base-200` | `oklch(96% 0.001 286.375)` | `#131313` | Page chrome, tonal washes |
| `--color-base-300` | `oklch(92% 0.004 286.32)` | `#252626` | Borders, dividers, inactive fills |
| `--color-base-content` | `oklch(21% 0.006 285.885)` | `#e7e5e5` | Ink |
| `--color-primary` | `#ff9900` | `#ff9900` | Primary action, selection, emphasis |
| `--color-primary-content` | `#000000` | `#000000` | Text on primary |
| `--color-secondary` | `oklch(55% 0.027 264.364)` | `#3c3b3b` | Secondary buttons, muted series |
| `--color-accent` | `oklch(0% 0 0)` | `#4d2b0f` | Rare accent (generated plan badges) |
| `--color-info` | blue oklch | blue oklch | In-progress, WebSocket transport |
| `--color-success` | teal oklch | teal oklch | Healthy, succeeded, eligible |
| `--color-warning` | amber oklch | amber oklch | Paused, refresh due, attention |
| `--color-error` | red oklch | red oklch | Failed, revoked, blocked, destructive |

Custom properties for the primary button's hand-tuned edge states (defined for
both themes in `app.css`): `--codex-primary-border: #e17d00`,
`--codex-primary-hover: #f2a000`, `--codex-primary-active: #d87400`.

Conventions:

- Translucent tone washes use `color-mix`-style opacity utilities:
  `bg-success/10 border-success/20 text-success` is the canonical chip recipe
  (see `chip_class/1` in
  [`badge_components.ex`](lib/codex_pooler_web/live/admin/components/shared/badge_components.ex)).
- Muted ink is expressed as content opacity (`text-base-content/60`,
  `/55`, `/45`, `/35`), not extra gray tokens.
- **The Orange Scarcity Rule** and **The Text Plus Color Rule** from the
  atmosphere section are binding for any new color use.

Beyond the daisyUI slots, two custom token families live in `app.css`:
`--color-reset-bank` (per-theme violet for the banked-reset resource — a
stored charge, deliberately outside the status vocabulary) and the
theme-invariant `--codex-rank-gold`/`--codex-rank-bronze` (+`-ink`) podium
metals. Components reference them as `text-(--color-reset-bank)`-style
utilities; never hardcode raw violet/oklch literals in `lib/`.

## 3. Typography

- **Family:** Roboto Condensed, self-hosted TTFs at weights 400–900
  (`@font-face` in `app.css`), wired as `--font-sans` and on `body`.
  Fallbacks: `ui-sans-serif, system-ui, sans-serif`. Note the face's
  asymmetric vertical metrics: centered labels often need `leading-none` plus
  flex centering rather than line-height tricks.
- **Mono:** the Tailwind `font-mono` stack (`ui-monospace`, Menlo, …) is data
  dress, used for IDs, prefixes, versions, tabular values
  (`font-mono tabular-nums`), the sidebar nav labels, and the OTP slots. Mono
  is never product personality.

Observed hierarchy (all from live pages):

| Role | Recipe | Where |
| --- | --- | --- |
| Page title | `text-3xl font-bold text-base-content` | `page_header` |
| Eyebrow | `text-sm font-semibold uppercase tracking-wide text-primary` | `page_header`, dialogs |
| Surface title | `text-base font-semibold leading-5` | `admin_surface`, card headers |
| Section heading | `text-xs font-semibold uppercase tracking-wide text-base-content/45` | drawer sections |
| Micro label | `text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35` | metric cards, card footers |
| Value | `font-mono font-semibold tabular-nums` (`text-xl`/`text-lg` compact) | metric cards, leaderboards |
| Body / help | `text-sm leading-6 text-base-content/65` | wizard copy, descriptions |
| Fine print | `text-xs` / `text-[11px] leading-4 text-base-content/55` | card details, sublabels |

Rules: no fluid hero type on admin screens; tracked uppercase only at micro
sizes (labels, chips, nav); prose capped around 65–75ch.

## 4. Spacing and layout

Radii come from the theme: `--radius-field: 0.25rem` (controls, `rounded`,
inputs), `--radius-box: 0.5rem` (`rounded-box`, cards, popovers), pills are
`rounded-full`. Border width token is 1.5px for daisyUI controls; hairlines
elsewhere are 1px `border-base-300` (often at `/70` opacity).

**Admin shell** (source:
[`shell.ex`](lib/codex_pooler_web/live/admin/components/shared/components/shell.ex),
wrapped by `Layouts.app chrome={:admin}` in
[`layouts.ex`](lib/codex_pooler_web/components/layouts.ex)):

- Root: `h-svh overflow-hidden bg-base-200`; only the main region scrolls
  (`#admin-shell-scroll-region`, `overflow-y-auto`). `:root` carries
  `scrollbar-gutter: stable`.
- Fixed top bar: `h-12`, wordmark left, GitHub/notifications/WebSocket-state
  dropdowns right.
- Fixed sidebar: `w-16` icon rail on mobile, `md:w-64` with labels; active item
  gets `!border-l-primary bg-base-300` on a `border-l-[3px]` slot.
- Content: `ml-16 md:ml-64 pt-12`, inner column `flex flex-col gap-6 p-4
  sm:p-6 xl:p-8`.

Spacing rhythm inside content: page sections stack at `gap-6`; metric strips
use `gap-2`; card bodies use `p-4` with `gap-3`/`gap-4` grids; surface headers
and footers use `px-4 py-3` / `py-2.5`.

Grid conventions:

- Cards and lists always guard with `min-w-0` and `truncate` so long labels
  cannot break the grid; wide chart content scrolls inside its own
  `overflow-x-auto` region (`data-role="chart-scroll-region"`) — the page
  never scrolls horizontally.
- Two-column stat rows use `grid-cols-[minmax(0,1fr)_auto]`.
- Responsive breakpoints in active use: `sm` (640), `md` (768), `lg` (1024),
  `xl` (1280), plus one bespoke `min-[1900px]` on the stats KPI strip.

### Observatory token extension

The Observatory keeps its exact approved geometry while using the existing
Tailwind/daisyUI vocabulary wherever a named value already exists. Standard
spacing and control geometry in the Observatory CSS are applied through named
Tailwind v4 utilities (`min-h-12`, the `gap-*`/`p-*`/`m*` scale, `size-*`,
`min-w-160`, `border`/`border-b`/`border-s-2`, and `leading-5`). The 576px
chart minimum is the existing Tailwind `--container-xl` token; compact body
type is `--text-xs`; weights and tight leading use `--font-weight-*` and
`--leading-tight`. Cards and field controls remain on `--radius-box` and
`--radius-field`; colors remain on the §2 semantic theme slots.

Only values with no exact framework token receive an Observatory-local token.
This is the complete inventory; it is not a new global scale:

| Token | Resolved value | Role |
| --- | --- | --- |
| `--observatory-radius-pill` | `999px` | Exact existing pill geometry for the key chip, segmented controls, live dot, and minibar |
| `--observatory-shell-max-width` | `87.5rem` (1400px) | Exact existing maximum width of the centered Observatory content column |
| `--observatory-model-label-column-width` | `8.5rem` | Exact model-name column width in ranked model rows |
| `--observatory-model-value-column-width` | `4.5rem` | Exact right-aligned token-value column width in ranked model rows |
| `--observatory-type-wordmark-size` | `0.95rem` | Observatory wordmark size |
| `--observatory-type-wordmark-tracking` | `-0.04em` | Observatory wordmark tracking |
| `--observatory-type-wordmark-suffix-size` | `0.625rem` | "Codex Pooler" wordmark suffix size |
| `--observatory-type-wordmark-suffix-tracking` | `0.14em` | Wordmark suffix tracking |
| `--observatory-type-control-size` | `0.6875rem` | Window and chart-mode segmented button type |
| `--observatory-type-control-leading` | `1.3` | Segmented button line height |
| `--observatory-type-fine-size` | `0.71875rem` | Freshness and fact-detail type |
| `--observatory-type-fine-compact-size` | `0.65625rem` | Freshness type on phones at or below 420px |
| `--observatory-type-fact-label-size` | `0.625rem` | Telemetry fact labels and Observatory micro metadata chips |
| `--observatory-type-fact-label-tracking` | `0.08em` | Telemetry fact-label tracking |
| `--observatory-type-fact-value-size` | `1.3125rem` | Standard telemetry fact value |
| `--observatory-type-fact-value-leading` | `1.15` | Telemetry fact-value line height |
| `--observatory-type-fact-value-lead-size` | `1.6875rem` | Lead success-rate value |
| `--observatory-focus-ring-width` | `2px` | Segmented, pause/resume, and logout focus ring |
| `--observatory-focus-ring-offset` | `2px` | Focus-ring separation from the control edge |
| `--observatory-motion-control-duration` | `150ms` via `--default-transition-duration` | Border/background/text state transition |
| `--observatory-motion-control-easing` | `ease` | Control state-transition curve |
| `--observatory-motion-live-duration` | `2.4s` | Live freshness-dot pulse period |
| `--observatory-motion-live-easing` | `ease-in-out` | Live freshness-dot pulse curve |
| `--observatory-motion-live-dim-opacity` | `0.35` | Midpoint opacity that makes the live pulse readable |

Responsive conditions are named Tailwind custom variants rather than custom
properties (custom properties cannot be evaluated in media-query conditions):

| Variant | Concrete condition | Role |
| --- | --- | --- |
| `observatory-split` | `width >= 1100px` | 4/8 telemetry split and sticky facts rail |
| `observatory-toolbar-stacked` | `width <= 45rem` (720px) | Two-row toolbar and compact gutters |
| `observatory-freshness-compact` | `width <= 26.25rem` (420px) | Smaller freshness label |
| `observatory-wordmark-compact` | `width <= 23.4375rem` (375px) | Hide only the wordmark suffix |

The variants are declared once with `@custom-variant`; component CSS consumes
them through `@variant`, and HEEx uses `observatory-split:*`. Tailwind 4 emits
the concrete media queries during the asset build. The ordinary `sm` variant
continues to control safe-prefix visibility at 640px.

## 5. Components — current admin system

Each entry: source, purpose, anatomy/API, tones and states, responsive/scroll
ownership, accessibility, and a minimal real markup example.

### 5.1 Page header

- **Source:** `page_header/1` in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex)
- **Purpose:** page identity + primary page actions.
- **API:** attrs `id` (req), `eyebrow` (default "Admin"), `title` (req),
  `description`, `actions_breakpoint` (`:sm` | `:lg`); slot `actions`.
- **Responsive:** single column; with actions it becomes
  `sm:grid-cols-[minmax(0,1fr)_auto]` (or `lg:` when the actions row is wide).

```heex
<AdminComponents.page_header
  id="upstreams-header"
  title="Upstreams"
  description="Link upstream accounts, monitor routing capacity, ..."
>
  <:actions>
    <AdminComponents.action_button id="link-upstream" icon="hero-link" label="Link" variant={:primary} phx-click="open_link" />
  </:actions>
</AdminComponents.page_header>
```

### 5.2 Metric strip and metric card

- **Source:** `metric_strip/1`, `metric_card/1` in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex);
  the stats KPI strip composes both via a `class` override
  (`kpi_strip/1` in
  [`stats/presentation.ex`](lib/codex_pooler_web/live/admin/components/pages/stats/presentation.ex)).
- **Purpose:** compact headline facts. Not a dashboard filler pattern: each
  card must answer an operator question, and tone is reserved for cards whose
  state deserves attention.
- **metric_card API:** attrs `id`, `icon`, `label`, `value` (req);
  `description`; `tone` (`:neutral | :primary | :success | :warning |
  :error`, colors the icon only); `compact_mobile` (denser paddings, hides
  icon below `lg`, exposes `data-density`); slot `breakdown` (rendered under
  the value — the stats Tokens card uses it for the input/cached/output
  split).
- **Anatomy:** micro uppercase label + trailing icon, `font-mono tabular-nums`
  value (`data-role="metric-card-value"`), optional muted description.
- **metric_strip API:** attrs `id`, `compact_mobile`, `desktop_columns`
  (`:four | :five`), `class` (full grid override — the stats KPI strip passes
  its 8-column recipe); mobile-first `grid-cols-2 → sm:3 → xl:4/5` by
  default. All metric strips (pools, upstreams cockpit, stats) compose this
  component.

```heex
<AdminComponents.metric_card
  id="stats-kpi-success-rate"
  icon="hero-check-circle"
  label="Success rate"
  value="99.4%"
  description="Completed"
  tone={:success}
  compact_mobile
/>
```

### 5.3 Admin surface (card with header, count, actions, toolbar, footer)

- **Source:** `admin_surface/1` in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex)
- **Purpose:** the standard sectioned card for tables, lists, and charts
  (leaderboard, traffic distribution, request-log table shells).
- **API:** attrs `id`, `title` (req), `description`, `count` (string pill),
  `header` (boolean), `overflow` (`:hidden | :visible` — set `:visible` only
  when header popovers must escape); slots `header_actions`, `toolbar`,
  `inner_block` (req), `footer`.
- **Anatomy:** `rounded-box border border-base-300 bg-base-100` shell; header
  `border-b bg-base-200/35 px-4 py-3` with `h2` title and optional
  `tabular-nums` count chip; optional toolbar band; optional `border-t`
  footer.

```heex
<AdminComponents.admin_surface id="stats-api-key-surface" title="Leaderboard" description="Top API keys by token usage in the last 24 hours">
  <:header_actions>… segmented pill (§5.12) …</:header_actions>
  <ol class="list-none divide-y divide-base-300/70">…rows…</ol>
</AdminComponents.admin_surface>
```

### 5.4 Upstream account card

- **Source:** `account_card/1` in
  [`account_card.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card.ex)
  with subcomponents in
  [`account_card/`](lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card).
- **Purpose:** one upstream identity's health, quota, token burn, and Pool
  routing at a glance, with recovery actions.
- **Root:** `<article data-role="upstream-account-card">`, classes
  `min-w-0 rounded-box border border-base-300 bg-base-100 transition-colors`
  plus `admin-token-burn-active` when tokens burned in the last 5 minutes.
  The routing tone is exposed as `data-routing-tone="success|warning|error"`;
  `app.css` paints the card's left border from it (the status stripe — a
  reinforcement of the footer routing label, never the sole channel).
  Request-log rows get the same treatment from their `data-status`
  attribute. Inline style feeds `--shine-delay` / `--shine-period`
  (per-card stagger; period shortens as burn level rises).

**Header** (`data-role="upstream-account-card-header"`, `flex … border-b
border-base-300 bg-base-200/35 px-4 py-3`):

- Identity block: `h3` label as a `<.link navigate>` (hover `text-primary`,
  `focus-visible` outline), optional workspace chip
  (`data-role="upstream-workspace-context"`, neutral metadata chip with the
  `!px-2 !py-0.5 !text-[10px]` micro override + `max-w-48 truncate`),
  auth-expiration line (`data-role="upstream-auth-expiration"`, `text-xs
  text-base-content/55`, full timestamp in `title`).
- Header actions cluster: saved-reset count badge (§5.6), plan badge (§5.9) or
  `diagnostic_popover` when the plan is unreported, and the actions dropdown
  (§5.10).

**Body — panel switcher:** three stacked `<section>` panels (usage / tokens /
pools) inside `data-role="upstream-account-panel-switcher"` with
`data-panel-view` reflecting the open one. The hidden panels use `max-h-0
opacity-0 pointer-events-none` plus `aria-hidden` and `inert`; the visible one
`max-h-[28rem] opacity-100` with a 150ms opacity transition
(`motion-reduce:transition-none`). Usage panel holds the quota rows (§5.5) and
saved-reset meter (§5.6); tokens panel holds a model leaderboard list (§5.8);
pools panel renders per-assignment route chevrons:

- `data-role="upstream-account-pool-route"` is a `role="meter"` with
  `aria-valuemin/max/now` = ready gate count and a spoken label; each
  `.route-chevron` segment (Assignment → Health → Quota) carries tone classes
  `bg-success/80 text-success-content` (or warning/error/neutral) and clips
  into chevrons via `clip-path` (CSS in `app.css`). The gate model lives in
  the shared
  [`route_path.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/route_path.ex),
  reused by the cockpit's routing lanes (§5.16).

**Footer — metric blocks** (`data-role="upstream-account-card-footer"`,
`border-t border-base-300 bg-base-200/20 px-4 py-2.5`): a three-column `dl`
(`grid grid-cols-3 divide-x divide-base-300/70 text-xs`). The Pools and
Tokens/5m cells double as the panel toggles: an absolutely positioned overlay
`<button>` (`phx-click="toggle_account_pools_panel"` /
`"toggle_account_tokens_panel"`, `aria-controls` + `aria-expanded`) sits under
pointer-events-disabled text, and the open panel keeps its cell in the hover
tint (`text-primary/70` label). Minimal cell:

```heex
<div class="min-w-0 pr-3" data-role="upstream-routing-cell">
  <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">Routing</dt>
  <dd class="truncate text-base-content/60" title={@routing_readiness.reason}>{@routing_readiness.label}</dd>
</div>
```

**States:** routing tone (success/warning/error stripe + footer label),
token-burn shine active/idle, per-panel open state, deleted/paused disabling
of actions, lifecycle warning block via `ReconciliationStatus`.

### 5.5 Quota progress row (including striped credit-backed state)

- **Source:** `quota_limit_row/1` in
  [`quota_limit_row.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card/quota_limit_row.ex);
  meter CSS (`admin-live-progress`, `progress-striped`, shine keyframes) in
  `app.css`.
- **Purpose:** one reported quota window (e.g. Weekly, 30d) as label +
  remaining percent + live `<progress>` meter + optional count/reset detail.
- **Tones:** percent ≥ 70 → `progress-success`/`text-success`; ≥ 30 →
  warning; below → error; unreported → `progress-neutral` and muted percent.
- **Striped state:** `credit_backed: true` appends `progress-striped` —
   45° white stripes over the tone color signal that remaining value burns
  credits rather than a percent window (visible live on credit-backed
  accounts). Stripes stay pinned during the burn shine (a second
  background-position layer in the keyframes).
- **Motion:** width/color transitions 260/180ms; cards with recent burn run
  the gloss sweep. Firefox falls back to a static bar; `prefers-reduced-motion`
  disables all of it.
- **A11y:** the `<progress>` carries `aria-label` "{label} remaining {pct}"
  and the percent renders as text besides the bar.

```heex
<progress
  id={"#{@id}-progress"}
  data-role="upstream-limit-progress"
  aria-label={"#{@limit.label} remaining #{@limit.percent_label}"}
  class="progress admin-live-progress progress-warning progress-striped h-1.5 w-full"
  value={@limit.percent_value}
  max="100"
>
  {@limit.percent_label}
</progress>
```

### 5.6 Saved-reset badge and meter

- **Source:** `saved_reset_count_badge/1` and `saved_reset_meter/1` in
  [`saved_reset_meter.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card/saved_reset_meter.ex)
- **Purpose:** the banked-reset economy: how many resets an account holds and
  whether auto-redeem is active.
- **Count badge** (`data-role="upstream-saved-reset-count-badge"`): a pill
  `<button>` in the card header (battery icon + count) that opens the policy
  dialog (`aria-haspopup="dialog"`, `aria-controls`). Tones: auto-redeem
  enabled → success recipe; disabled → the `--color-reset-bank` token (§2).
  Renders nothing when no resets are reported.
- **Meter** (`data-role="upstream-saved-reset-meter"`): title "Banked Resets",
  `x{count}` counter, then a `role="meter"` bar of five `h-1.5 rounded-full`
  segments (`grid grid-cols-5 gap-1`), filled segments reset-bank-toned, empty
  `bg-base-300/70`, with `aria-valuemin/max/now` and a text label. Footer line
  states "Auto redeem active/inactive" and next expiry with a clock icon.

### 5.7 Chips (status, count, metadata, severity, protocol, redacted)

- **Source:** `chip_class/1` and helpers in
  [`badge_components.ex`](lib/codex_pooler_web/live/admin/components/shared/badge_components.ex);
  protocol badge in
  [`request_logs/presentation.ex`](lib/codex_pooler_web/live/admin/components/pages/request_logs/presentation.ex)
  + class map in
  [`request_logs/display.ex`](lib/codex_pooler_web/live/admin/components/pages/request_logs/display.ex);
  `redacted_status_badge/1` in shared
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex).
- **Base recipe:** `inline-flex items-center rounded-full border
  border-{tone}/20 bg-{tone}/10 px-2.5 py-1 text-xs font-medium leading-none
  text-{tone}` (neutral uses `border-base-300 bg-base-200
  text-base-content/70`).
- **Status mapping** (`status_chip_class/1`): success = active, accepted,
  succeeded, eligible, present, known, ok; warning = disabled, paused,
  cancelled, interrupted, refresh_due, half_open, resetless_unprimed,
  weekly_only_*; error = archived, revoked, failed, rejected, refresh_failed,
  reauth_required, expired, blocked, open, deleted; info = in_progress,
  pending, refreshing, stale; everything else neutral.
- **Count chip** (`count_chip_class/0`): `rounded-box bg-base-200 …
  tabular-nums` — squarer, for totals ("4 keys", "12 options").
- **Protocol chip** (`data-role="protocol-badge"`): micro variant
  (`h-4.5 px-2 text-[10px] font-semibold uppercase tracking-[0.04em]`), tones:
  websocket → info, http_sse → success, http_multipart → warning, http_json →
  primary, fallback neutral. Full transport in `title`.
- **Redacted status badge:** `rounded-box bg-{tone}/15` square chip whose
  visible text is only ok/attention needed/error/redacted with an `sr-only`
  label prefix — the pattern for evidence that must not leak values.

Two chip families, by shape:

- **Pill chips** (`rounded-full`, the base recipe): status, metadata,
  severity, lifecycle, protocol, and plan chips — anything classifying a
  record.
- **Boxy tags** (`rounded-box bg-base-200`): `count_chip_class/0` for totals
  and mono identifiers (cockpit safe-account-id/subject-ref add
  `font-mono break-all`), and the redacted status badge.

daisyUI `badge badge-*` classes are not used for status/metadata — every
chip comes from `BadgeComponents`. The single sanctioned `badge` is the
notification-count bubble on the top-bar bell (`shell.ex`), which is a
counter overlay, not a status chip.

```heex
<span class={AdminBadges.status_chip_class(@key.status)}>{@key.status}</span>
<span class={AdminBadges.count_chip_class()}>{@count} keys</span>
```

### 5.8 Compact and definition lists

Three recurring list shapes, all `text-xs`-scale and truncation-guarded:

- **Definition grid (`dl`)** — labeled facts in card footers (§5.4) and the
  request-log drawer rows. Drawer row (`detail_row/1` in
  [`detail_drawer.ex`](lib/codex_pooler_web/live/admin/components/pages/request_logs/detail_drawer.ex)):

```heex
<div id={@row.id} data-role="request-log-detail-field" class="grid gap-1 rounded-box bg-base-200/60 px-3 py-2">
  <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">{@row.label}</dt>
  <dd class="break-words text-base-content/80 font-mono text-xs tabular-nums">{@row.value}</dd>
</div>
```

- **Ranked compact rows** — the account tokens panel
  (`data-role="upstream-account-token-model"`,
  `grid-cols-[minmax(0,1fr)_4rem_3.5rem_3.5rem] … odd:bg-base-200/40` with an
  inline share bar `h-1 rounded-full bg-primary/70`) and the stats leaderboard
  runner rows (`divide-y divide-base-300/70`, rank medallion, name+pool stack,
  right-aligned mono values).
- **Zebra tables** — long homogeneous records (request logs, jobs, audit)
  use `table table-zebra`, compacted by `admin-log-table.table-sm` padding in
  `app.css`. Row detail lives in the drawer, not in ever-wider columns.

### 5.9 Plan badge — all tones

- **Source:** `plan_badge/1` in
  [`badge_components.ex`](lib/codex_pooler_web/live/admin/components/shared/badge_components.ex)
- **API:** attrs `id`, `label`, `family`, `placeholder` (default
  "Plan unknown"), `class`, global rest. Labels are canonicalized
  ("chatgpt plus" → "ChatGPT Plus"); when a family is present and differs it
  renders as "Label (Family)". Always renders as a §5.7 pill chip.
- **Tone map:**

| Tone | Plans | Chip |
| --- | --- | --- |
| free | Free | success chip |
| pro | Pro, Plus, ChatGPT Pro/Plus | primary chip |
| team | Team, Business, ChatGPT Team | info chip |
| enterprise | Enterprise, Edu, Education | warning chip |
| generated | any other non-empty label | phash2-stable tone chip |
| unknown | blank | neutral chip |

Used on upstream card headers, the upstream cockpit header, request-log rows
(with `!`-override micro sizing), and the pool wizard's identity options —
verified live as the orange "Pro" / green "Free" pills.

```heex
<AdminBadges.plan_badge id={"#{@dom}-plan-label"} label={@account.plan_label} aria-label={"Account plan: #{@account.plan_label}"} />
```

### 5.10 Dropdown action menu

- **Source:** `dropdown_action_item/1` in shared
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex);
  canonical composition in `upstream_account_actions/1`
  ([`account_card.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/account_card.ex)).
- **Anatomy:** daisyUI `dropdown dropdown-end` with a `btn btn-ghost btn-sm
  btn-square` ellipsis trigger (`aria-label="Actions for {label}"`) and a
  `menu dropdown-content z-20 mt-2 w-60 rounded-box border border-base-300
  bg-base-100 p-2 shadow-xl` list. Items are full-width icon+label rows.
- **Variants:** `:secondary` (neutral), `:warning` (Pause), `:positive`
  (Reactivate), `:danger` (Delete) — text-toned with `hover:bg-{tone}/10`;
  disabled state drops to `text-base-content/35` with `pointer-events-none`.
  Items render as `<.link>` when given `href/navigate/patch`, else buttons.
  `copy_feedback?` opts into the copy-label swap hook contract.

### 5.11 Object inspector and request-log drawer

- **Source:** `object_inspector/1` in shared
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex);
  used by
  [`detail_drawer.ex`](lib/codex_pooler_web/live/admin/components/pages/request_logs/detail_drawer.ex).
- **Purpose:** detail-heavy single-record inspection with sanitized rows.
- **API:** attrs `id`, `title` (req), `subtitle`, `status` + `status_class`,
  `class` (override the shell), `close_event`/`close_label`, `role`,
  `aria_modal`; slots `tabs`, `inner_block`, `quick_links`.
- The drawer composes it inside `drawer-side z-[70]` with a click-away
  overlay label, `role="dialog"` + `aria-modal`, `max-w-2xl`, `shadow-2xl`,
  and section groups ("Final outcome", "Attempts timeline", "Sanitized
  metadata") each headed by the §3 section-heading recipe. Attempt cards are
  `rounded-box border border-base-300 bg-base-200/35`; transport failures use
  the error wash (`border-error/20 bg-error/5`).

### 5.12 Segmented pill control

- **Source:** the private `chart_mode_control/1` is rendered only through the
  public `traffic_charts/1` composition in
  [`presentation_charts.ex`](lib/codex_pooler_web/live/admin/components/pages/stats/presentation_charts.ex);
  the same visual pattern is also used by `leaderboard_sort_button_class/1` in
  [`stats/presentation.ex`](lib/codex_pooler_web/live/admin/components/pages/stats/presentation.ex)
  (Interval/Cumulative and Tokens/Cost).
- **Showcase contract:**
  [`ComponentShowcaseStats.contract/0`](dev_support/codex_pooler_web/dev/component_showcase_stats.ex)
  maps stable entry `5.12-segmented-control` to the real public
  `StatsPresentation.Charts.traffic_charts/1` export and scopes its selectors
  beneath `#showcase-stats-traffic-charts`. The showcase never exposes or
  calls the private leaf directly.
- **Anatomy:** `rounded-full border border-base-300 bg-base-200/60 p-0.5`
  group (`role="group"` + `aria-label`) of `text-[11px]` pill buttons; the
  active option reads as a raised thumb (`border-base-300 bg-base-100
  text-base-content`), inactive are borderless muted text. State is exposed as
  `aria-pressed`; every option keeps its border so the thumb never shifts
  layout.

```heex
<div id="stats-traffic-chart-mode-control" class="flex shrink-0 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/60 p-0.5" role="group" aria-label="Traffic chart mode">
  <button type="button" class="cursor-pointer rounded-full border border-transparent px-2.5 py-0.5 text-[11px] font-medium leading-4 … aria-pressed:border-base-300 aria-pressed:bg-base-100" data-chart-mode="interval" aria-pressed="true">Interval</button>
  …
</div>
```

### 5.13 Time-series chart surface

- **Source:** `traffic_charts/1` in
  [`presentation_charts.ex`](lib/codex_pooler_web/live/admin/components/pages/stats/presentation_charts.ex);
  hook `ApexTimeSeriesChart` in `assets/js` (series math in
  `assets/js/chart_series.mjs`); tooltip/container CSS
  (`admin-apex-bar-chart`, `admin-chart-mobile-wide`) in `app.css`.
- **Showcase contract:** the same structured
  [`ComponentShowcaseStats.contract/0`](dev_support/codex_pooler_web/dev/component_showcase_stats.ex)
  maps stable entry `5.13-time-series-chart` to that public export, its
  deterministic inputs, and the scoped `#stats-traffic-chart` surface. Tests
  consume the structured export/root/selector identities, not this human
  documentation prose.
- **Anatomy:** an `admin_surface`-style card whose header holds the title, a
  live `tabular-nums` total line, and a mode pill (§5.12); the plot `div`
  carries `phx-hook="ApexTimeSeriesChart" phx-update="ignore"` and a
  `data-chart-*` contract (categories/series/units/value-kinds/yaxis/colors/
  height/legend/stacked/zoom/mode-control...). Colors are CSS variables
  (`var(--color-primary)` etc.) so charts re-skin per theme.
- **Scroll ownership:** the plot sits in
  `data-role="chart-scroll-region"` (`overflow-x-auto overscroll-x-contain`);
  below `48rem` the plot keeps `min-width: 36rem` and scrolls inside the card.
- **A11y:** the plot is `role="img"` labeled by an `sr-only` title and a
  description summarizing buckets/totals; an `sr-only` `<ul
  data-chart-source="interval">` mirrors every interval value; mode changes
  announce through an `aria-live="polite"` description.

### 5.14 Policy editor dialog and wizard

- **Source:** `policy_editor_dialog/1` in
  [`policy_editor_components.ex`](lib/codex_pooler_web/live/admin/components/shared/policy_editor_components.ex);
  API-key composition and step panels in
  [`wizard_components.ex`](lib/codex_pooler_web/live/admin/components/pages/api_keys/wizard_components.ex);
  tab CSS (`policy-editor-tab`, `is-current`, step-marker hover) in `app.css`.
- **Anatomy:** a `dialog.modal` (`modal-bottom sm:modal-middle`) with a
  `modal-box … max-w-4xl p-0 shadow-2xl` panel split into header (eyebrow,
  title, description, step tablist), scrollable body, and a sticky
  `dialog_footer` (docs link left, actions right).
- **Step tabs:** `role="tablist"` of numbered buttons; each has a `size-5`
  mono step marker; the current tab gets `.is-current` (orange-tinted border +
  wash) and `aria-current="step"`/`aria-selected`; hover promotes the marker to
  solid primary. Below `lg` the tabs collapse to a 2-column grid
  (`policy-editor-tabs` CSS).
- **Step panels:** `role="tabpanel"` sections toggled by `block`/`hidden`
  (state lives server-side in `current_step`).
- **Policy mode cards** (`policy_mode_card/1`, `reasoning_policy_mode/1`): a
  radio wrapped in a selectable card label — selected state
  `border-primary bg-primary/10`, idle `border-base-300 bg-base-100
  hover:bg-base-200`. The checkbox flavor of this pattern (orange
  checkbox-card multi-select) is the reference multi-select list
  (`api-key-model-option-*` rows: `checkbox checkbox-primary` inside a
  `rounded-box border hover:border-primary/50 hover:bg-primary/5` label).

```heex
<label class={["grid cursor-pointer gap-2 rounded-box border p-3 transition-colors hover:bg-base-200",
  selected? && "border-primary bg-primary/10", !selected? && "border-base-300 bg-base-100"]}>
  <input type="radio" class="radio radio-primary radio-sm mt-1" … />
  <span class="grid gap-1">
    <span class="font-semibold text-base-content">All models</span>
    <span class="text-sm leading-5 text-base-content/60">Allow current and future routable models.</span>
  </span>
</label>
```

### 5.15 Filters, empty state, notices, buttons, flash, theme toggle

- **`filter_form/1`** (shared components.ex): a `.form` with
  `phx-hook="AdminFilterDropdowns"`, arbitrary-variant class surgery that
  compacts nested daisyUI fields (`[&_.input]:input-sm`,
  `[&_.label]:uppercase …`), optional `<details>` "Advanced filters", and a
  `data-role="filter-actions"` cluster. `cally_date_filter/1` provides the
  anchored calendar popover.
- **`empty_state/1`:** dashed-border `rounded-box` panel, icon at
  `text-base-content/40`, title + optional description + actions, all
  centered. The chart-free variant (`pool-activity-empty-state` in `app.css`)
  is the same idea for plot areas.
- **`extended_notice/1`:** daisyUI `alert alert-{info|success|warning|error}
  items-start` with icon, bold title, and body; `role="status"` by default.
- **`diagnostic_popover/1`:** hover/focus dropdown for warnings that need
  explanation (e.g. plan not reported): warning-toned `btn btn-ghost btn-xs
  btn-circle` trigger with `aria-describedby` pointing at a `role="tooltip"`
  card.
- **`action_button/1`:** icon+label control; `:primary` → `btn btn-primary`
  (custom edge/hover vars from §2), `:danger` → `btn btn-error btn-outline
  btn-sm`, default `btn btn-secondary btn-sm`. Renders as link when given a
  navigation attr. Primary buttons keep the inset top highlight and a
  `focus-visible` orange outline (CSS in `app.css`); disabled goes flat
  `base-300` with `cursor-not-allowed`.
- **Flash / toast** (`flash_group/1` in layouts.ex, `flash/1` in
  [`core_components.ex`](lib/codex_pooler_web/components/core_components.ex)):
  `toast toast-top toast-end z-50` stack, `aria-live="polite"`; each flash is
  `role="alert"`, tone-washed border (`border-success/25 bg-success/10` /
  error), auto-dismiss hook, plus the client/server disconnect flashes with a
  spinning reconnect icon (`motion-safe:animate-spin`).
- **`theme_toggle/1`** (layouts.ex): pill with a sliding thumb
  (`transition-[left]`) across system/light/dark buttons dispatching
  `phx:set-theme`; the persisted theme is applied in the root layout before
  paint.
- **Inputs** (core_components.ex `input/1`): daisyUI `fieldset`/`label`/
  `input|select|textarea|checkbox` recipes, `w-full` fields, error state adds
  `input-error` etc. plus an icon+text error line — never color alone.
  `otp_input/1` renders the grouped mono OTP slots styled by `codex-otp-*`
  CSS.

### 5.16 Upstream cockpit (detail-page pattern)

- **Source:**
  [`cockpit_components.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/cockpit_components.ex)
  composing
  [`cockpit/summary.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/cockpit/summary.ex),
  [`cockpit/sections.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/cockpit/sections.ex),
  and
  [`cockpit/charts.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/cockpit/charts.ex).
- **Purpose:** the per-account diagnosis page (`/admin/upstreams/:id`) — the
  house pattern for entity detail pages: a sticky identity rail beside a
  content stack.
- **Layout:** `grid xl:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]` with 16px
  gaps; the rail is `xl:sticky xl:top-16` (below the fixed top bar); single
  column below `xl`. Reconciliation warnings and OAuth activity render
  full-width above the split.
- **Credential card** (`#upstream-cockpit-header`): the account as a badge —
  Gravatar avatar from the account email (`AvatarComponents.gravatar_url`,
  monogram tile fallback) with a lifecycle-toned presence dot
  (`#upstream-cockpit-presence`, green active / amber paused-refresh /
  red reauth-failed), name + humanized status text, plan chip top-right,
  onboarding meta line, and a **fingerprint band**: labeled mono rows
  (account hash / subject ref / workspace, `–` when absent) on a tonal
  footer with `ClipboardCopy` buttons and a 5%-ink key-glyph watermark.
  Mono is reserved for the fingerprint values.
- **Vitals** (`#upstream-status-summary`): a dl of freshness facts (access
  token expiry, token refresh, auth verified, quota refresh, quota evidence
  age, reconciliation) — sentence prefixes stripped so dt/dd don't repeat,
  values tone-colored by state, sans `tabular-nums`.
- **Actions rail** (`#upstream-actions`): every lifecycle/recovery action as
  a full-width list row (icon + label); unavailable actions stay visible but
  disabled with the gating reason as `title` and an "unavailable" hint —
  never hidden, never a reason-chip wall. Destructive actions are
  error-toned and confirm via dialog.
- **Routing lanes** (`#upstream-assignments`): a readiness verdict strip
  (status chip + reason + a calm 24h failure note — a share of failed
  upstream calls is expected and only escalates past the domain threshold),
  then one row per Pool assignment: pool link, §5.4 route-chevron gate meter
  (via `RoutePath`), and the lane's share of 7-day successes.
- **Quota & banked resets** (`#upstream-quota`): account-level window rows
  (reusing the index card's `quota_limit_row`, §5.5), the saved-reset meter
  (§5.6), expiration table, and the auto-redeem policy form behind a
  `<details>` disclosure with an on/off state chip.
- **Request health** (`#request-health-chart`): inline facts (24h/7d
  volumes, failure rate, p50 latency), the ApexTimeSeriesChart plot
  (§5.13 contract), a 24h error-code breakdown list, and the on-demand
  refresh control.
- **Recent activity** (`#upstream-event-summary`): compact metadata-only
  event rows (timestamp · title/subtitle · source chip · "Evidence →" link)
  with header links to filtered request logs, audit logs, and the account's
  jobs.
- **Rules:** identity facts render exactly once (card, vitals, or lanes —
  never repeated); machine codes appear only inside evidence contexts
  (error breakdown, event subtitles); no raw UUIDs in prose — deep links
  carry them instead.

## 6. Components — API Key Observatory extension

The Observatory (`live /observatory`) is a **separate, key-holder-facing
surface**. It reuses the token system, chips, metric cards, chart contract,
and states above, but not the admin chrome. The layout below was chosen from
five browser-verified candidates on 2026-07-17 ("Ledger" composition with the
"Console" facts rail) and this section is its authoritative description.

### 6.1 Shell and toolbar

**Sources:** [`Layouts.app`](lib/codex_pooler_web/components/layouts.ex),
[`ObservatoryLive`](lib/codex_pooler_web/live/observatory_live.ex),
[`Toolbar.toolbar`](lib/codex_pooler_web/live/observatory/components/toolbar.ex),
and [Observatory rules in `app.css`](assets/css/app.css).

- Own minimal layout (own `live_session`, no `Shell.admin_shell`, no sidebar,
  no operator identity, no Pool selector). Root is a single scroll region on
  `bg-base-200`; the `observatory-shell-content` column is centered with
  `mx-auto` and capped by `--observatory-shell-max-width` at the existing
  87.5rem (1400px), with `p-4 sm:p-5` and `gap-4` section stacking.
- Dark-first: default presentation is the dark theme; light must remain fully
  supported through the same `data-theme` mechanism. No neon/glass/gradient
  decoration — Observatory distinctiveness comes from layout density and the
  toolbar, not new ornamentation.
- **Toolbar** (sticky, 48px, `bg-base-100 border-b border-base-300/70`), left
  to right:
  1. Wordmark: "Codex Pooler" (900 weight, `text-primary`, `-0.04em`, matching
     the admin brand) with a small uppercase "Observatory" suffix in muted ink.
  2. Key chip: pill (`border-base-300 bg-base-200 rounded-full`) with a tiny
     key glyph in a `primary/14` circle, the key's display name (600), and
     the safe prefix (`font-mono`, muted, e.g. `sk-cxp-8308…d412`) — never
     the raw key. Prefix hides below `sm`.
  3. Spacer, then the time-window segmented pill (§5.12): `1h / 5h / 24h /
     7d`, `aria-pressed` state, server-validated selection.
  4. Freshness: live dot (success tone, 2.4s opacity pulse, warning + static
     when paused, `prefers-reduced-motion` disables) + "Updated Ns ago".
  5. Pause/resume icon button, a "Log out" ghost button, and the shared
     `theme_toggle` (system/light/dark) so the holder can switch themes. The
     ApexTimeSeries chart hook re-renders on `data-theme` change so the chart
     re-themes immediately rather than on the next data refresh.
- Toolbar responsiveness: the toolbar is two flex groups — identity
  (wordmark + key chip) and controls (window pill, freshness, pause, logout).
  Above 720px they share one 48px row; the named
  `observatory-toolbar-stacked` variant applies at 720px and below and wraps
  them into two stacked rows: identity on top, controls full-width below with
  the pill left and freshness/pause/logout right. The key prefix hides below
  `sm`; `observatory-freshness-compact` applies through 420px and
  `observatory-wordmark-compact` hides the suffix through 375px. The toolbar
  stays sticky in both shapes.
- Vocabulary rule: no "Pool", "upstream", or operator terminology anywhere in
  Observatory copy; statuses use the holder's perspective (usage, models,
  outcomes).

### 6.2 Telemetry grid

**Sources:** [`ObservatoryLive`](lib/codex_pooler_web/live/observatory_live.ex),
[`Telemetry.telemetry`](lib/codex_pooler_web/live/observatory/components/telemetry.ex),
[`Activity.activity`](lib/codex_pooler_web/live/observatory/components/activity.ex),
and [Observatory rules in `app.css`](assets/css/app.css).

- At 1100px and above (`observatory-split`): a two-column split,
  `grid-template-columns:
  minmax(0,4fr) minmax(0,8fr)` with 16px gap. The **left rail is sticky**
  below the toolbar (`position: sticky; top: 64px`) and stacks two cards; the
  right column is cardless and stacks the traffic section over the outcome
  table (an instrument-panel rail beside an open canvas). Below 1100px
  everything collapses to one column (rail first, static) and charts scroll
  inside their own `overflow-x-auto` region. No horizontal scroll of primary
  content at any width (375/768/1280 are the checked breakpoints).
- **Left rail, card 1 — facts** (§5.2 metric-card anatomy, stacked as one
  card with hairline row dividers, never an equal-tile KPI grid; row weight
  follows priority):
  1. *Success rate* (lead row, larger value): value + trend delta, detail
     line "N succeeded · N failed", and a 4px mini progress bar in success
     tone.
  2. *Cache rate*: value + delta, detail "X of Y input tokens served from
     cache".
  3. *Cost*: settled value + `settled` neutral micro-chip, detail line for
     the estimated remainder ("+ $N estimated, awaiting settlement").
  4. *Throughput*: tok/s value + delta.
  5. *Latency*: p50 as the value with a smaller p95 beside it, detail "Mean
     Ns · slowest settled Ns".
  Values are `font-mono tabular-nums`; labels are §3 micro labels; deltas are
  small mono figures in success/error ink.
- **Left rail, card 2 — models**: §5.8 ranked compact rows
  (`name | bar | tokens`), bars relative to the leader, series colors in
  fixed order primary → info → success → muted ink mixes; every row is
  direct-labeled so identity never rides on color alone.
- **Right column — traffic** (cardless: a heading with a hairline rule, no
  bordered wrapper): the window total in the sub-line ("138.2M tokens ·
  $79.62" — total tokens and total cost, echoing the chart), an
  Interval/Cumulative segmented pill (§5.12) beside the heading, and the
  ApexTimeSeriesChart contract (§5.13) in a `chart-scroll` body: stacked token
  columns **broken down by model** (top models plus a folded "Other" so the
  stack sums to total tokens) with a settled+estimated **cost line** on a
  second (right) axis — the app's shipped "Traffic over time" pattern. Green
  is reserved for the cost line, so the model columns draw from
  primary/info/warning/accent/secondary and never collide with it. ~264px tall.
- **Right column — recent outcomes** (cardless: heading + hairline rule): a
  zebra table (§5.8 idiom, `table-sm` density) inside its own
  `overflow-x-auto`. Columns: Time (mono, muted, readable "Jul 16, 23:22:23"
  format) · Model (500 weight, truncated) · Endpoint class (muted) · Status
  (§5.7 micro chips: ok/warn/err/neutral) · Latency · Tokens · Cost (all
  right-aligned mono). Bounded at 12 rows; only sanitized fields ever appear
  (timestamp, model, endpoint class, safe status/code, latency, settled
  tokens/cost). No per-row status stripe and no `sanitized` chip — the status
  chip and the section's "metadata only" subtext carry that.

### 6.3 Window control and refresh states

**Sources:** [`ObservatoryLive`](lib/codex_pooler_web/live/observatory_live.ex),
[`States.state`](lib/codex_pooler_web/live/observatory/components/states.ex),
[`Observatory.Presentation`](lib/codex_pooler_web/live/observatory/presentation.ex),
and [`Toolbar.toolbar`](lib/codex_pooler_web/live/observatory/components/toolbar.ex).

- Windows are the allowlisted `1h / 5h / 24h / 7d` as a segmented pill;
  selection is server-validated (client ids are never authority).
- Freshness states, each with a stable selector and visible text: `loading`,
  `empty` (§5.15 empty-state anatomy), `stale` (paused or hidden-tab), and
  `error`. Partial (still-settling) accounting is not a banner — the dashboard
  renders normally and the settled/estimated split is carried by the Cost fact
  (§5.2). Connection loss surfaces in the freshness pill, not a banner. Refresh
  cadence is 30s only while visible; pause/resume is explicit and reflected in
  the toolbar.
- The named state rendering, window allowlist, and initial loading behavior are
  implemented in the linked sources. The 30-second visibility-aware cadence and
  stale-result behavior are a separate runtime contract and are not claimed as
  implemented by these source links.

## 7. Motion

Motion carries state meaning or it does not exist. Current inventory (all in
`app.css` or component classes, all `prefers-reduced-motion`-guarded where
animated):

- Quota meters: width 260ms / color 180ms transitions
  (`admin-live-progress`); token-burn gloss sweep with per-card
  `--shine-delay` stagger and burn-scaled `--shine-period` (§5.4/§5.5).
- Panel switcher: 150ms opacity ease-out with `motion-reduce:transition-none`.
- Pool compat disclosure: 160ms slide/fade in (`pool-compat-panel-in`),
  disabled under reduced motion.
- Hover/focus color transitions: `transition-colors` (~200ms) on nav items,
  chips, pills, dropdown items.
- Flash show/hide: 200–300ms fade/scale via `CoreComponents.show/hide`;
  reconnect spinner is `motion-safe:animate-spin`.
- Theme toggle thumb: `transition-[left]`.
- Observatory segmented/pause/logout controls: the semantic control motion
  role is 150ms `ease` for border/background/text state changes; the live-dot
  role is a 2.4s `ease-in-out` opacity pulse whose midpoint is 0.35. These map
  to the `--observatory-motion-*` tokens in §4; pause makes the dot static and
  `prefers-reduced-motion: reduce` removes the pulse and control transitions.

Rule: no looping decorative animation; the burn shine is the ceiling for
ambient motion and it is evidence-driven (recent token burn).

## 8. Depth

Flat-first. Two sanctioned separation methods, never combined on a resting
surface:

- **Content layering:** `border border-base-300` (+ `/70` for internal
  dividers) over tonal `bg-base-200/*` washes; header bands `bg-base-200/35`,
  footer bands `bg-base-200/20`.
- **Overlay shadows:** `shadow-xl` for dropdown menus and flash, `shadow-2xl`
  for dialogs, drawers, and top-bar popovers. `shadow-sm` appears only on the
  object-inspector default shell.

z-index ladder in use: dropdowns in cards `z-20`, chart/tooltip internals,
top-bar popovers and toasts `z-50`, request-log drawer `z-[70]`.

## 9. Accessibility and design rules

### Accessibility baseline (verified patterns to preserve)

- Status is always text + color (chips carry labels; redacted badge prefixes
  an `sr-only` label; meters expose `aria-valuetext`/labels).
- Every interactive control has a visible `focus-visible` outline (orange, 2px
  offset) — buttons, links, footer panel triggers, pills.
- Meters/progress use native `<progress>` or `role="meter"` with proper
  value attributes; charts have `sr-only` data mirrors and `aria-live` mode
  announcements; toggles expose `aria-pressed`/`aria-expanded`/
  `aria-controls`; hidden panels are `aria-hidden` **and** `inert`.
- Reduced motion disables shine, transitions, and disclosure animations.
- Icons are decorative (`aria-hidden` spans) unless paired with `sr-only`
  text.

### Do / Don't

- **Do** keep admin surfaces dense, table long homogeneous records, drawer the
  detail, and preserve light/dark parity for every new color or state.
- **Do** reuse the chip/metric/surface/pill primitives above before inventing
  new ones — chips come from `BadgeComponents`, metric strips from
  `metric_strip`/`metric_card`, and the Observatory explicitly composes them.
- **Do** paint status stripes from data attributes (`data-routing-tone`,
  `data-status`) in `app.css` — domain read models never emit CSS class
  names, and a stripe always reinforces visible status text.
- **Don't** hardcode raw color literals (`violet-*`, bracket-escaped oklch)
  in `lib/`, hand-manage `dark:` pairs for custom hues, or introduce a second
  token store — per-theme values live in `app.css` (§2).
- **Don't** render prompts, bearer tokens, raw payloads, cookies, upstream
  secrets, raw idempotency keys, or raw API keys in UI, examples, tests, or
  screenshots.
- **Don't** add color-only status channels (a stripe is fine only as
  reinforcement of visible status text, painted from a data attribute),
  gradient/glass/neon decoration, monospace-as-personality, or motion without
  state meaning.
