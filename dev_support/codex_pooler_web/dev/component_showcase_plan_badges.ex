defmodule CodexPoolerWeb.Dev.ComponentShowcasePlanBadges do
  @moduledoc false
  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Dev.ComponentShowcaseData

  attr :theme, :string, required: true

  def gallery(assigns) do
    assigns =
      assign(assigns,
        directions: [
          {"enamel", "A / Enamel", "Crisp colour, solid tint and a clean edge."},
          {"satin", "B / Satin", "A restrained metallic finish with a rounded gold Pro capsule."},
          {"split", "C / Split", "Compact plaque; the palette demonstrates a separate tier segment."}
        ],
        plans: [
          {"free", "Free"},
          {"go", "Go"},
          {"plus", "Plus"},
          {"pro", "Pro"},
          {"prolite", "Pro Lite"},
          {"team", "Team"},
          {"business", "Business"},
          {"enterprise", "Enterprise"},
          {"edu", "Edu"}
        ]
      )

    ~H"""
    <main
      id="plan-badge-review"
      class="plan-badge-review min-h-svh bg-base-200 p-4 text-base-content sm:p-6"
    >
      <header class="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
            Component study
          </p>
          <h1 class="mt-1 text-2xl font-semibold">Account plan badges</h1>
          <p class="mt-2 max-w-2xl text-sm text-base-content/65">
            Three directions in the existing account cards. 5x and 20x are hypothetical layout examples, not verified plan mappings.
          </p>
        </div>
        <nav aria-label="Preview theme" class="flex gap-2">
          <a
            :for={theme <- ["light", "dark"]}
            class="btn btn-sm btn-outline"
            aria-current={if theme == @theme, do: "page"}
            href={"/dev/component-showcase/#{theme}?state=plan-badges"}
          >{String.capitalize(theme)}</a>
        </nav>
      </header>
      <div
        class="mb-6 flex flex-wrap items-center gap-2 text-xs text-base-content/65"
        aria-label="Current product badges"
      >
        <span class="mr-2">Current badges</span>
        <BadgeComponents.plan_badge
          :for={label <- ["Go", "Plus", "Pro", "Pro Lite", "Enterprise"]}
          label={label}
        />
      </div>
      <div class="plan-proposal-columns">
        <section
          :for={{direction, title, description} <- @directions}
          id={"plan-direction-#{direction}"}
          data-direction={direction}
          class="min-w-0"
        >
          <h2 class="text-lg font-semibold">{title}</h2><p class="mb-4 mt-1 text-sm text-base-content/65">
            {description}
          </p>
          <div class="plan-proposal-palette mb-4 rounded-box border border-base-300 bg-base-100 p-4">
            <span :for={{family, label} <- @plans} data-family={family} class="plan-proposal-badge">{label}</span>
            <span data-family="pro" class="plan-proposal-badge">Pro <span class="plan-proposal-tier">5x</span></span>
            <span data-family="pro" class="plan-proposal-badge">Pro <span class="plan-proposal-tier">20x</span></span>
          </div>
          <div class="grid gap-4">
            <div
              :for={
                {family, label, index} <- [
                  {"go", "Go", 1},
                  {"pro", "Pro 5x", 2},
                  {"enterprise", "Enterprise", 3}
                ]
              }
              data-family={family}
              class="plan-proposal-account"
            >
              <AccountCard.account_card
                account={account(direction, label, index)}
                account_index={index}
              />
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp account(direction, label, index) do
    account = ComponentShowcaseData.account_card()
    identity = %{account.identity | id: "proposal-#{direction}-#{index}"}

    %{
      account
      | identity: identity,
        label: "Sample #{label}",
        plan_label: label,
        quota_limits: Enum.take(account.quota_limits, 2)
    }
  end
end
