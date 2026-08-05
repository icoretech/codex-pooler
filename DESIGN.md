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
- Fixed top bar: `h-12`, wordmark left; right, in order, the GitHub resources
  dropdown, alert notifications, the live-updates toggle, and the WebSocket
  state dropdown.
- Fixed sidebar: `w-16` icon rail, `xl:w-64` with labels; active item gets
  `!border-l-primary bg-base-300` on a `border-l-[3px]` slot.
- The nav ends with the Observatory item, the one exit to the key-holder
  surface. It looks like its siblings — no arrow glyphs, separators, or
  group labels — and the protection is the interaction: it opens through the
  hold-to-launch ring (§7) instead of a plain click, and carries "hold to
  open in a new tab" in its accessible name and title. Plain left-click is
  owned by the hold; modified clicks, middle-click, and keyboard Enter
  follow `target="_blank"` natively (`HoldToLaunch` hook in
  `assets/js/hold_to_launch.mjs`).
- Content: `ml-16 xl:ml-64 pt-12`, inner column `flex flex-col gap-6 p-4
  sm:p-6 xl:p-8`.

**The rail holds until `xl`, and this is a content decision, not a nav one.**
The usable content column is `viewport − sidebar − padding`. With labels from
`md` the sidebar took 256px from every viewport at 768 and up, which is exactly
the band where the widest surfaces have the least room to give: an iPad
landscape at 1180 had 862px of content for a table that needs 896, so the last
column fell off the edge, and an iPad portrait at 820 had 502px and dropped to
a phone layout. Holding the 64px rail to `xl` returns ~192px to every admin
page in the 768–1280 band — landscape goes to 1054px and the table fits whole.
Nav labels are recoverable (each item keeps `title` and `aria-label`); a column
that has been pushed off the screen is not. When judging any layout change,
measure the content column, not the viewport.

**The live-updates toggle is global, and belongs to the reading session.** Eight
admin pages rebuild themselves when Pool events arrive, and the operators page
on its own domain's events. That is right while an operator is watching traffic
and wrong while they are reading, so one topbar control answers it for all of
them and no single surface — pagination least of all — has to guess. State
lives in `sessionStorage`: a second tab stays live, a new tab starts live, and
the choice survives moving between pages.

Three things follow for the UI. The accessible name stays "Pause live updates"
in both states, because a name that flips alongside `aria-pressed` announces a
contradiction ("Resume live updates, pressed"). Which icon shows is decided by a
`data-live-updates-paused` attribute on `:root`, written by an inline script
before first paint, so the button never renders the state it is about to be
corrected out of — the same technique the theme uses, and with the attribute
absent the resting "live" reading wins. And a change carries a flash, because
the icon swap is easy to miss on a control this small and a list that has simply
gone quiet does not explain itself; only an actual change speaks, since the
control also reports on mount and on reconnect.

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
  icon below `lg`, exposes `data-density`). Every card is label + value +
  one description line; a card that needs more than one supporting line is
  telling you the detail belongs elsewhere. The stats Tokens card once
  stacked an input/cached/output split under its value and read as an
  outlier in the strip — the split's one interesting number already lives
  in the dedicated Cache rate card, so Tokens went back to a single
  description like its siblings.
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

- Each assignment row heads with the pool label on the left and a live
  traffic stat on the right
  (`data-role="upstream-account-pool-assignment-traffic"`): settled tokens
  this account routed toward that Pool in the last 5 minutes, formatted
  `1.2M tok/5m` (`Format.token_count`, 11px `tabular-nums` at 60% ink,
  detail sentence in `title`). It reuses the token-burn window and ledger
  rows — the projection folds the same single settlement query by Pool —
  so it costs no extra query. A row whose recent requests all lack settled
  usage shows `? tok/5m`, never a false zero. This stat replaced the old
  binary "Eligible" label: readiness already lives gate-by-gate in the
  route meter below, so the label now says what the assignment is actually
  doing.
- The route path is always four gates in this order: **Assignment → Health →
  Quota → Circuit**. The compact account-card segment shortens only the first
  visible label to **Assign**; cockpit segments, the meter's accessible name,
  and every spoken detail keep **Assignment**. `Circuit` is a fourth gate, not
  a replacement for quota or a broad account-availability claim.
- `data-role="upstream-account-pool-route"` is a `role="meter"` with stable
  route and segment ids, `data-role="upstream-account-pool-route-segment"`,
  `aria-valuemin="0"`, `aria-valuemax={RoutePath.segment_count()}`,
  `aria-valuenow`, and matching `aria-label` / `aria-valuetext` spoken detail.
  The count is always out of four. A disabled assignment with no circuit rows
  can intentionally read **1/4**: its Circuit gate is clear because no circuit
  protection is active, while its Assignment, Health, and Quota gates retain
  their own state. Each `.route-chevron` segment carries tone classes
  `bg-success/80 text-success-content` (or warning/error/neutral) and clips
  into chevrons via `clip-path` (CSS in `app.css`). The gate model lives in the shared
  [`route_path.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/route_path.ex),
  reused by the cockpit's routing lanes (§5.16).
- Circuit presentation is a load/refresh-time snapshot. Persisted circuit
  lifecycle is retained across replicas, but current blocking is determined
  only by `CircuitHealth.blocked?/3` and its `blocked_reason/3`; a persisted
  active lifecycle row is not automatically current blocking. A blocked lane
  is not ready. Among non-blocked rows, an eligible `half_open` lane, or a lane
  with eligible `opened_at`/`last_failure_at` evidence inside the inclusive
  recovery window, is recovering and currently ready. A non-blocked `open` lane
  recovers only with that evidence; stale, future, or absent evidence leaves it
  clear. Recent evidence is never current blocking. Circuit rows are limited to
  current served models:
  retired or non-serving models are ignored before classification or recovery.
  For each exact lane, the latest row is selected by `updated_at DESC`, then
  `created_at DESC`, before history and recovery evidence are considered. The
  inclusive recovery presentation window is
  `clamp(10 * circuit_open_seconds, 300, 3600)`.
- The snapshot updates on page load/refresh only: there are no timers, polling,
  circuit PubSub subscriptions, or self-updating cooldowns. Circuit evidence
  can change visible account-verdict copy and tone, but it does not change the
  broad `routing_ready_now?` meaning or existing KPI meanings. The account
  circuit aggregate includes only independently active, health-active, eligible
  assignments; every assignment chevron still shows its own four-gate state.
  Observed circuit rows cannot prove complete availability and must never infer
  a `total blackout`. Telemetry, alerts, and dashboards already exist and are
  not changed by this presentation contract.

**Footer — routing readiness** (`data-role="upstream-account-card-footer"`):
the shared card fact strip (§5.17) with three facts. The Pools and Tokens/5m
cells are `interactive`: an absolutely positioned overlay `<button>`
(`phx-click="toggle_account_pools_panel"` / `"toggle_account_tokens_panel"`,
`aria-controls` + `aria-expanded`) sits under pointer-events-disabled text, and
the open panel keeps its cell in the hover tint (`text-primary/70` label).
Tokens/5m uses plain `{count} tokens` when usage accounting is complete,
`{count}+ tokens` when reported usage is only a verified lower bound, and
`Usage unavailable` when no token total can be claimed. Minimal cell:

```heex
<:fact role="upstream-routing-cell">
  <AdminComponents.card_fact_label>Routing</AdminComponents.card_fact_label>
  <AdminComponents.card_fact_value title={@routing_readiness.reason}>
    {@routing_readiness.label}
  </AdminComponents.card_fact_value>
</:fact>
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
- **Reset timing:** anchored reset labels use the `RelativeCountdown` hook to
  keep the compact `6d 23h` / `1h 30m` / `42m` value current without a
  LiveView round trip. Floating rolling windows remain static as
  `starts on use` until provider evidence anchors their reset.
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

- **Definition grid (`dl`)** — labeled facts in card footers (§5.17) and the
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
- **Hairline tables** — long homogeneous records (request logs, jobs) use
  daisyUI `table` with its default row hairlines and `hover:bg-base-200/80`;
  request logs and the jobs explorer additionally compact cell padding
  through `admin-log-table.table-sm` in `app.css` and follow the record-row
  contract in §5.18 for widths, tone, and reflow. The audit trail left this
  family for the prose ledger (§5.22). There
  is no `table-zebra` in the app — the only striping is the Observatory
  outcomes table (`nth-child(odd)` in `app.css`) and the pool serving-modes
  grid (`even:`). Row detail lives in the drawer, not in ever-wider columns.

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
  solid primary. From `sm` the tabs hold **one compact row** — marker plus
  uppercase label, with the descriptions `lg`-and-up — and below `sm` they
  collapse to a 2-column grid of slim rows (`policy-editor-tabs` CSS). The
  tablist never stacks one-per-row: five full-width rows pushed the step
  content below the fold on tablets.
- **Step panels:** `role="tabpanel"` sections toggled by `block`/`hidden`
  (state lives server-side in `current_step`).
- **Policy mode cards** (`policy_mode_card/1`, `reasoning_policy_mode/1`):
  single-choice selection cards following the §5.19 radio-less contract
  (sr-only radio, ✓ corner glyph while checked, `border-primary/60 +
  bg-primary/5` checked recipe, 13px/11px type scale). The checkbox flavor
  of this pattern (orange checkbox-card multi-select) is the reference
  multi-select list (`api-key-model-option-*` rows: `checkbox
  checkbox-primary` inside a `rounded-box border hover:border-primary/50
  hover:bg-primary/5` label) — the checkbox stays visible because
  multi-select state has no other per-card glyph channel.

Every single-choice card family — the pool routing step, the saved-reset
trigger, and the policy mode cards above — follows the radio-less selection
card contract (§5.19). Only multi-select checkbox cards keep a visible
control.

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
  is the same idea for plot areas. Use it when the **whole surface** has no
  records — it replaces the list, table, or card body.
- **`table_empty_row/1`:** the in-table counterpart. First child of the
  `tbody`, `hidden only:table-row`, one `td` spanning every column at
  `py-8 text-center text-sm text-base-content/60`. Use it when the column
  header should stay visible (audit logs, operators) instead of the table
  being swapped for a block. Never hand-roll the `colspan` row.
- **Compact lists** — a list inside a panel, dialog, or card body that is too
  small for a dashed block states its emptiness in one muted sentence
  (`text-xs`/`text-sm text-base-content/60`), e.g. the pool assignment picker
  and the account tokens panel. Every list still says something when empty;
  a header with nothing under it is a bug.
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
  then one row per Pool assignment: pool link, §5.4 four-gate route-chevron
  meter (via `RoutePath`), and the lane's share of 7-day successes. The stable
  `upstream-assignment-<assignment>-route` id and
  `data-role="upstream-assignment-route"` / `data-role="upstream-assignment-route-segment"`
  selectors expose the same `role="meter"`, dynamic four-gate maximum, current
  ready count, and full `Assignment → Health → Quota → Circuit` spoken text as
  the card. Cockpit labels never use the compact `Assign` form.
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

### 5.17 Card fact strip (shared card footer)

- **Source:** `card_fact_strip/1`, `card_fact_label/1`, `card_fact_value/1` in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex)
- **Purpose:** the band of two to four labeled facts that closes a card. This
  is the only sanctioned way to render a card footer strip; the upstream
  account card (§5.4), the jobs worker card, and the operator card (§5.21)
  all use it.
- **API:** strip attrs `id` (goes on the facts `dl`), `facts_role`
  (`data-role` for the `dl`), `class`, and a global `rest` that lands on the
  `footer` band; slot `fact` with `role` (cell `data-role`), `class`, and
  `interactive`. Label and value take `tone_class` (replaces the resting
  colour) and `class` (adds to the base).
- **Anatomy:** band `border-t border-base-300 bg-base-200/20 px-4 py-2.5`;
  facts `dl` `grid min-w-0 divide-x divide-base-300/70 text-xs leading-5` with
  the column count derived from the number of facts. Divider padding is
  positional and owned by the component — first cell `pr-3`, middle cells
  `px-3`, last cell `pl-3`. Labels are the §3 micro label
  (`text-[0.62rem] font-semibold uppercase tracking-[0.08em]`,
  `text-base-content/35` at rest); values truncate at `text-base-content/60`.
- **Interactive cells:** `interactive` makes the cell
  `group relative isolate` so the slot can host an absolutely positioned
  overlay `button` (panel toggles on the account card). Keep the visible label
  and value `pointer-events-none relative z-30` so the overlay stays clickable
  underneath them, and swap `tone_class` on both while the panel is open.

```heex
<AdminComponents.card_fact_strip
  facts_role="worker-schedule-grid"
  data-role="worker-schedule-facts"
  data-density="compact"
>
  <:fact role="next-run-group">
    <AdminComponents.card_fact_label>Next run</AdminComponents.card_fact_label>
    <AdminComponents.card_fact_value class="tabular-nums">{@card.next_run}</AdminComponents.card_fact_value>
  </:fact>
</AdminComponents.card_fact_strip>
```

- **Rules:** never re-declare the band, grid, divider padding, or micro-label
  classes at a call site; add a fact rather than a second strip; numeric values
  carry `tabular-nums`.

### 5.18 Record row — the ledger contract

The jobs explorer and the request-log table are the two record tables. They
share one contract, and a third record table should join it rather than invent
a fourth shape.

**One markup tree, two readings.** A record table is a real `<table>` that
reflows below its breakpoint instead of being duplicated as a card list. Add
`admin-ledger-table`; the CSS in `app.css` switches `display` and the template
places cells with `max-lg:` grid utilities. The `thead` becomes `sr-only`, never
absent. Never render a second tree for small screens: the explorer used to print
twenty articles beside twenty rows on every update.

**The breakpoint is `lg`, for every record table.** There was briefly a second
opt-in (`admin-ledger-table-md`) for tables whose columns "still fit a tablet."
They do not. The tablet band is precisely where a table stops giving way in its
elastic column and starts compressing all of them at once — on the request-log
table at 900px, model, attribution and transport all truncated together, which
is worse than the reflow the second breakpoint existed to postpone. One
breakpoint also means the reflow CSS is written once.

**A ledger entry is not automatically a phone layout.** The reflowed entry
stacks one field per line, which is right at 430px and wasteful at 700: on an
iPad portrait a record ran 141px tall with half its width empty and six records
filled the screen. From `sm` up to the reflow breakpoint a table opts in with
`data-ledger-dense`, the entry gets a second content column, and the template
places the paired fields with stacked `max-lg:sm:` utilities — on request logs
attribution and transport move beside the identity instead of under it, 141px
becomes 79px, and ten records fit. Two things to keep in mind: each `tr` is its
own grid container, so any `auto` track is measured per row and a record missing
that field will shift its neighbours' columns — the figures track is a fixed
`4.5rem` for exactly this reason; and the opt-in is per table, because a table
whose fields do not pair up gains nothing from a second column.

**Column widths belong to the `colgroup`, and only hold up with a floor under
the table.** Give every column a floor and leave exactly one elastic — the one
whose content already truncates with the full value in a `title`. Then give the
table `lg:min-w-[Nrem]` equal to the sum of those floors, and let the wrapper
scroll (`lg:overflow-x-auto`). Without it the floors are decoration: `<col>`
widths are hints, so a narrow container compresses every column at once and the
elastic column stops being the one that gives. The min-width is safe *because*
the table reflows below `lg` — it never applies at a width where it could push
content off a phone. Request logs: `8+9+10+17+6+6 = 56rem`. Jobs: `72rem`.

**Status tick.** Opt in with `admin-status-tick` and put `data-tone` on the row
(`success` / `warning` / `error` / `info`). A rounded 4px bar is painted inside
the leading cell's padding, and in ledger mode it becomes a grid item measuring
the record — the identity and its figures — and stopping before anything that
follows. Tone is never the only channel: the row spells its status out.

**The title is the trigger.** A row that opens a drawer makes its headline a
`<button>` — the worker name in jobs, the timestamp in request logs and audit
logs — and gives the row the same `phx-click`, so the whole row is clickable and
keyboards get a real target. No chevron column: it costs width on every row to
say what the cursor already says.

**Failures belong to their record.** A record table has no "Outcome" column,
which is empty on every healthy row and too narrow on the ones that matter. A
failed record emits a second `<tr>` carrying its reasons along one line, bound
to the record above by a continuing tone bar and by the suppressed rule between
them. It renders only when something actually failed.

**Figures.** Measures live in right-aligned `tabular-nums` columns, with the
qualifier under its figure — cached tokens under the total, compression under
the cost. Units and currency marks are notation, not figure: same weight as the
number, stepped back to `text-base-content/60`. Never repeat the column heading
in the cell (`235.3k`, not `235.3k tokens`).

**The count comes with the way to move, and the pager sticks.** A record table
draws from a set larger than a page, so it carries one nav: `Page X of Y` at the
start, `Showing a-b of N` in `tabular-nums`, and a `join` of Previous/Next at
the end, disabled as `btn-disabled` spans rather than removed so the control
keeps its shape. It sits **above** the rows and is `sticky top-0 z-20` on the
page-chrome background — fifty records is a long scroll to reach Next, and
taller on a tablet, so a pager only at the bottom is a pager you cannot reach.
Sticky rather than rendered twice: one tree. Request logs, audit logs and the
jobs explorer all render it from `LogPagination`, so there is no second copy of
either the markup or the arithmetic. It renders only where there are rows: an
empty result has nothing to page through, and the count it still owes a screen
reader is the `sr-only` total above it, not a range of zero.

The pager takes the type size of the records it counts — `text-xs` with
`btn-xs`, not `text-sm` — because a control set one step larger than everything
around it reads as though it came from another design, even in the same
typeface. And it stays **one row at every width**: the ordinal (`Page 2 of
11893`) is the range said less precisely, so below `sm` it is the part that
steps aside, leaving `51-100 of 587938` on the line with the buttons. Stacking
the three parts turned a control into four rows of chrome above the first
record.

The `<caption>` stays but goes `sr-only` —
it names the table and its total for a screen reader before the rows, which is
the only job a caption does that the pager cannot. It is written **first inside
the table**, before `<colgroup>`, because that is where the content model puts
it: a caption placed anywhere else is silently reparented by the parser, so the
markup stops saying what it renders. A visible caption reporting
"594617 matching" under fifty rows and no way to reach row 51 is the shape to
avoid; it reads as a total when it is a page. Paging is a list control: the links
carry the filters forward and drop the drawer selection, and changing any filter
drops the page, because a page number only means something against the result set
it was counted from.

**Offset paging only holds still if the list holds still.** These tables are
live — request logs debounce a rebuild on every Pool event — and an offset into
a growing set is not a stable address: rows shift down under the reader and
records already seen come back. So page one is the live reading and rebuilds on
every event, while **leaving page one pins the window**.

**Pin to the row, not to the clock.** The pin is a cursor in the list's own sort
key — the head row's `{admitted_at, id}`, carried as `as_of` + `as_of_id` — and
the window bounds on `admitted_at < t or (admitted_at = t and id <= id)`. A
timestamp alone is not enough: `admitted_at` is the transaction timestamp, so
requests admitted in one transaction share it exactly and only `id` separates
them, which means an `admitted_at <= t` bound admits a row inserted *after* the
pin that sorts *above* it — the drift the pin exists to prevent. Being its own
filter rather than a `date_to`, the cursor also composes with the operator's date
range by plain intersection, so nothing they set has to be merged or overridden.
Behind page one the list no longer rebuilds; the event refresh only recounts
arrivals, through the complement cursor, so the count and the page can never
disagree about which side of the pin a row falls on.

**The pin moves with the live page.** Page one rebuilds on every event, so the
cursor is re-derived from each rebuild. Left at the head of the last full load it
names a window that has already ended, and the record pushed off the bottom of
page one lands on neither page — a gap that grows for as long as the tab stays
open.

**A page number is address-bar input.** It becomes an OFFSET, so it is clamped
before it reaches the query — an unclamped one exceeds int64, raises while
handling the params, kills the LiveView, and is retried by the reconnecting
client, which is a crash loop from a single link. Past the end of the result set
the window is then corrected against the total and lands on the last page that
has rows: rendering the empty state over a set that has thousands, with the pager
hidden because there are no items, leaves no way back except editing the URL.

The pinned state rides on the range line rather than adding a row:
`Showing 51-100 of 587938 · 6679 newer · Back to latest`. It needs the count and
the exit, not a sentence naming the mechanism — an explanation of why the list
stopped moving is chrome, and chrome that only appears in one state is the kind
that gets written as an extra row. The range is what truncates when the line is
tight; the way back to live never does. Returning to page one drops the pin, so
live is always one click away and never something the operator has to arrange.

### 5.19 Selection card (radio-less choice card)

- **Source:** routing strategy cards in
  [`wizard_components.ex`](lib/codex_pooler_web/live/admin/components/pages/pools/wizard_components.ex)
  (pool wizard, Routing step), trigger-mode cards in
  [`saved_reset_components.ex`](lib/codex_pooler_web/live/admin/components/pages/upstreams/saved_reset_components.ex)
  (saved-reset policy panels), and the policy mode cards
  (`policy_mode_card/1`, `reasoning_policy_mode/1`) in the API-key
  [`wizard_components.ex`](lib/codex_pooler_web/live/admin/components/pages/api_keys/wizard_components.ex)
  (§5.14); decision record in the "Selection cards · Radio-less ✓" artifact
  (2026-08-05).
- **Purpose:** a single-choice option card whose border and wash carry the
  selection and whose check glyph is the non-color selected channel. There is
  no visible radio control.
- **Anatomy:** card shell `rounded-box border border-base-300 bg-base-100`;
  the `p-2.5` padding lives on the inner `<label>` so the entire card is the
  click target. Title `text-[13px] font-semibold leading-tight`; description
  `text-[11px] leading-4 text-base-content/55`, worded to hold **two lines at
  the narrowest column** the grid produces. Corner cluster
  `absolute right-2.5 top-2 pointer-events-none`: a `hero-check size-3
  text-primary` glyph rendered only while the card is checked, composing with
  a permanent micro tag when one exists (the Bridge ring card reads
  "✓ DEFAULT" while selected; the tag alone otherwise).
- **States:** hover `border-primary/50`; checked `border-primary/60
  bg-primary/5` (the §5.14 wash recipe is retired for these cards); focus
  ring `outline-2 outline-primary outline-offset-2` driven by the hidden
  radio's `:focus-visible`.
- **Mechanism:** the radio input stays in the DOM as `sr-only`, so radiogroup
  semantics, arrow-key navigation, and form submission are unchanged. The
  pool wizard drives state with Tailwind `has-[]`/`group-has-[]` utilities;
  the saved-reset cards use top-level `:has()` rules in `app.css` because the
  cockpit form is submit-only and nested `&:has` re-invalidation proved
  unreliable there. New call sites should prefer the utility form unless they
  hit the same constraint.
- **Dependent controls stay put:** a control owned by one option (Ring size
  for Bridge ring) is always rendered and dims to `opacity-45` while its
  option is unselected — never `hidden`, so changing the selection cannot
  shift the layout.
- **Toggle-gated tunables go read-only, not disabled:** when a whole panel
  of cards and fields is gated by a switch (auto-redeem and the saved-reset
  tunables), the off state keeps everything rendered and dimmed, makes text
  inputs `readonly`, and locks the card radiogroup with
  `pointer-events-none` + `tabindex="-1"` + `aria-disabled` on the fieldset.
  Never the `disabled` attribute: disabled controls drop out of the form
  submit, and saving with the gate off would silently clobber the stored
  policy values.

```heex
<div class="group/strategy relative min-w-0 rounded-box border border-base-300 bg-base-100 transition-colors hover:border-primary/50 has-[.strategy-radio:checked]:border-primary/60 has-[.strategy-radio:checked]:bg-primary/5 …">
  <span class="pointer-events-none absolute right-2.5 top-2 inline-flex items-center gap-1">
    <.icon name="hero-check" class="hidden size-3 text-primary group-has-[.strategy-radio:checked]/strategy:inline-block" />
    <span :if={default?} class="text-[0.56rem] font-bold uppercase tracking-wide text-primary/70">Default</span>
  </span>
  <label class="flex min-w-0 cursor-pointer items-start gap-2.5 p-2.5">
    <input type="radio" class="strategy-radio sr-only" … />
    <span class="grid min-w-0 gap-0.5">…title + two-line description…</span>
  </label>
</div>
```

### 5.20 Model info popover

- **Source:** `model_info_popover/1` in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/shared/components.ex),
  fed only by the safe presentation projection in
  [`model_info.ex`](lib/codex_pooler/catalog/model_info.ex).
- **Purpose:** explain an unfamiliar catalog entry without increasing every
  model row's height. The primary content is the short upstream description;
  exceptional catalog facts such as a hidden alias or lack of public API
  support appear in a quiet footer band. Raw provider metadata never reaches
  the component.
- **Trigger variants:** catalog and policy forms use a neutral 24px info-icon
  button immediately after the model name. Dense usage leaderboards make the
  model label itself the trigger, with a subtle underline affordance instead
  of adding an icon to every row. Both variants retain the full model label in
  their accessible name.
- **Mechanism:** use the native `popover`/`popovertarget` contract with the
  existing daisyUI anchored-dropdown treatment. The panel enters the browser
  top layer, so scrollable wizard bodies and cards cannot clip it. Invocation
  is click, tap, or keyboard activation. The shared admin overlay coordinator
  in `app.js` gives the open model popover precedence over its containing
  dialog for Escape, restores focus to the invoker, and provides deterministic
  outside-click dismissal inside modal top layers. Do not make the information
  hover-only and do not add a page-specific positioning hook.
- **Panel:** `w-72 max-w-[calc(100vw-2rem)] rounded-box border
  border-base-300 bg-base-100 shadow-2xl`; compact uppercase eyebrow, model
  label, and `text-xs leading-5` description. The optional facts footer uses
  `border-t border-base-300 bg-base-200/35` and text plus icon, never color
  alone.
- **Metadata drift:** one shared description is shown when all reporting
  upstreams that provide one agree. Conflicting descriptions are stated as a
  conflict rather than choosing an arbitrary source. Hidden/API facts are
  shown only when their aggregate state is known; mixed reports are named as
  mixed.
- **Accessibility and selectors:** the invoker owns `aria-controls` and
  `aria-describedby`; the panel is focusable and carries `role="tooltip"`.
  Preserve stable `data-role="model-info-popover"`, `model-info-trigger`,
  `model-info-content`, and `model-info-description` hooks for LiveView tests
  and browser QA. Focus-visible uses the standard primary outline.

### 5.21 Operator card

- **Source:** `operator_cards/1` and the private `operator_card/1` in
  [`operator_components.ex`](lib/codex_pooler_web/live/admin/components/shared/operator_components.ex);
  page state in
  [`operators_live.ex`](lib/codex_pooler_web/live/admin/pages/operators_live.ex).
- **Purpose:** `/admin/operators` renders a grid of profile cards
  (`md:grid-cols-2 xl:grid-cols-3`) instead of a table — operators are few
  and trusted, and the page's job is identity plus security posture at a
  glance. The filtered-empty surface is the dashed `empty_state` (§5.15).
- **Anatomy:** header band (`border-b bg-base-200/35 px-4 py-3`) holding the
  Gravatar avatar with lifecycle presence dot, the display name with a
  primary "you" marker on the viewer's own card, the email, and the role as
  a quiet uppercase micro-label — the single active **instance owner** in
  primary ink, **instance admins** muted, never a second chip — plus the
  §5.10 actions dropdown. Body is a 2×2 vitals `dl` (TOTP, Password policy,
  Last login, Joined) using the §3 micro-label recipe, warning-toned values
  for "Not set up" and a pending password change.
- **Footer:** the §5.17 fact strip with two facts. **Status** is written
  out (capitalized, `text-success`/`text-warning`). **Pools** is an
  interactive cell using the upstream account card's exact overlay-trigger
  contract, toggling `toggle_operator_pools_panel`; the assigned-Pools
  panel above the strip follows the §5.4 collapse contract (`aria-hidden`
  plus `inert`, 150ms opacity, reduced-motion safe). The owner's panel
  states that the role is not Pool-scoped instead of faking a list; an
  admin with no Pools says so in one muted sentence.
- Panel open state lives server-side in `operator_panel_views` (pruned on
  reload), mirroring the upstreams page.

### 5.22 Audit prose ledger

- **Source:** the ledger shell in
  [`components.ex`](lib/codex_pooler_web/live/admin/components/pages/audit_logs/components.ex)
  and the sentence builder in
  [`prose.ex`](lib/codex_pooler_web/live/admin/components/pages/audit_logs/components/prose.ex);
  the reading was piloted on the request-logs prose experiment
  (`feat/request-logs-prose`).
- **Purpose:** the audit trail told as sentences — who did what to whom —
  at every width, desktop included. One tree, no table, no reflow contract:
  a sentence wraps where a column would truncate.
- **Grammar:** values carry the contrast in full-ink `text-base-content` at
  regular weight — bold entities proved too loud in a dense ledger — while
  connective words step back to 45% ink at `text-[0.8rem] leading-relaxed`;
  the leading timestamp is time-only, set in the day kicker's own type
  (`text-[0.62rem] font-semibold tracking-[0.08em] tabular-nums`) at 35%
  ink, raised `-top-px` so the cap-height digit block sits optically
  centered on the line, and is a drawer trigger; the date lives once, in
  the kicker that heads each day card. Free-standing em dashes are the only punctuation
  that separates clauses. Every clause is optional because events genuinely
  differ; a failure outcome appends an error-toned tail
  ("— it failed: reason").
- **Derived clauses, no schema change:** already-recorded detail keys keep
  the sentence honest without new columns — an invite names the invited
  email, a Pool status change names the destination status, an operator
  update whose role actually moved appends "— role set to …" using the
  Operators-page role labels, and any labeled record owning a `pool_id`
  says "in the Pool …" with the Pool acting on the filter. Everything
  heavier (previous states, assignment id lists, trigger kinds) stays in
  the drawer.
- **Day cards and row anatomy:** each day group is its own `rounded-box`
  card headed by the kicker; rows are flex (`items-start gap-2.5`) with the
  family icon leading, the sentence `flex-1`, and a `hero-chevron-right`
  drawer trigger `self-center` at the row's end. Rows bleed to the card
  edge (`-mx-4 px-4`) for a full-width `hover:bg-base-200/40`, split by
  `border-base-300/55` hairlines. Both icon buttons are `flex` so they
  collapse to the glyph's 16px instead of inheriting the 24px base line
  box — that, plus the asymmetric `pt-[9.5px] pb-[6.5px]` (compensating
  the bottom hairline and the half-leading), is what centers a one-line
  sentence in its row; measure before changing either.
- **Entities act on the page's own filters, never navigate away:** the
  actor, the target operator, and the Pool render as inline buttons that set
  the matching filter (`select_actor_filter`, `select_target_filter`,
  `select_pool_filter`); the family icon (the §5.7-toned `audit_action_icon`
  set, `size-4`) filters by that exact action, and the "failed" word filters
  by outcome. A target with no email filters by its id while showing its
  presentation label; an entity with nothing to filter by falls back to a
  plain full-ink span.
- **Coverage is a contract:** every action in `Audit.action_options/0` has a
  handcrafted sentence in the prose map, enforced by a test that diffs the
  two lists; unknown actions degrade to a marked generic fallback. Porting
  this page surfaced two recorded-but-unlisted actions (the OAuth browser
  and device link flows), which joined the vocabulary and the filter.
- The sticky `LogPagination` pager, the filters (stacked `mobile_single_column`
  on phones like the other log pages), and the detail drawer are unchanged.

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

- Observatory hold-to-launch (`admin-nav-hold-*` in `app.css`, `HoldToLaunch`
  hook): the nav exit opens only after a ~1s press — the icon's ring fills as
  functional progress (JS-driven stroke offset), early release drains it in
  150ms, and the tab opens on the release gesture so popup blockers stay
  quiet. Only the 300ms launch pop is decorative, and it is motion-gated.

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
- The upstream route meters preserve stable ids and `data-role` selectors on
  both the route and each gate, expose their dynamic four-gate count through
  `aria-valuemin`, `aria-valuemax`, and `aria-valuenow`, and use the same full
  `aria-label` / `aria-valuetext` detail on both surfaces. Compact visual copy
  may say `Assign`; accessibility text says `Assignment`.
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
