# Localization workflow

The application ships English (`en`) and Simplified Chinese (`zh_CN` in Gettext, `zh-CN` in the browser and stored preferences). English source text is the message identifier and fallback. See [glossary.md](glossary.md) before changing terminology.

## Developer commands

Run commands through the repository's pinned toolchain:

```sh
mise x -- mix codex_pooler.i18n.extract
mise x -- mix quality.i18n
mise x -- mix codex_pooler.i18n.scan
mise x -- mix codex_pooler.i18n.scan --check
```

Extraction merges source messages and validates the resulting catalogs. New untranslated Chinese entries intentionally fail validation: fill and review them, then rerun the gate. Extraction never guesses translations. Run extraction after source movement too: source reference-line changes are checked strictly.

The `quality.i18n` gate checks extraction drift, catalog integrity and scanner non-regression. It runs locally through `mix quality` and in the hosted static lane. It requires no translation-service credentials or network access.

## Message conventions

- Use exact natural English literals with `gettext`, named `%{name}` bindings, and `ngettext` for counts. Do not concatenate sentences or pass dynamic msgids.
- Translate at render time, never inside module attributes, persisted data, logs, broadcasts, webhook payloads or runtime API responses.
- Use `pgettext` for genuinely different meanings and `gettext_comment` for translator context. In HEEx, comments use non-output `<% gettext_comment("context") %>` expressions.
- Translate all human-facing attributes, including hints, placeholders, accessible names, titles and JavaScript labels supplied as `data-*` attributes. Do not change identifiers, DOM ids, event names, routes or machine values.
- Never put HTML tags in messages. Keep HTML structure outside translations and let Phoenix escape interpolated data.
- Custom Ecto messages remain English literals in changesets; register them with `dgettext_noop("errors", ...)` in `CodexPoolerWeb.ValidationMessages` and translate through the shared error component.
- Request and LiveView processes set a resolved locale. Tasks do not inherit it: capture `Gettext.get_locale()` before starting a task, and render inside `Gettext.with_locale(locale, fn -> ... end)`.

## Catalog contract

Committed PO catalogs are the build artifacts under `priv/gettext/{en,zh_CN}/LC_MESSAGES/`. Domains are `default` (UI), `errors` (validation) and `emails` (explicitly localized mail). Matching POT templates are extraction-owned; do not edit extracted msgids manually. The manually maintained standard Ecto entries in `errors.pot` are preserved by extraction.

Every PO declares `Language`, `Content-Type: text/plain; charset=UTF-8`, and `Plural-Forms`. English uses `nplurals=2; plural=(n != 1);`; Chinese uses `nplurals=1; plural=0;`. English translations may be empty because the source is the fallback. Chinese translations must be complete and non-fuzzy. Named placeholders must match exactly, with one reserved plural exception: Gettext automatically supplies `%{count}`, so English singular/plural forms may differ in that name when the singular omits “1”; translations may use it when either source form does. No other introduced or missing placeholder is allowed. Gettext overwrites the `count` binding with the raw plural-selection integer: use another placeholder such as `%{tokens}` when the displayed count is compact or grouped.

Contexts (`msgctxt`), extracted comments (`#.`), plural forms and `%{name}` placeholders must survive any external round trip. Source references (`#:`) are expected extraction noise. Do not convert committed placeholders to ICU syntax or replace natural msgids with synthetic keys. Translation platforms are editing tools, not runtime dependencies; synchronization and publication require their own reviewed change.

## Language preferences

The resolved browser language follows explicit account preference, explicit cookie, `Accept-Language`, then English. Only explicit choices are persisted. “Browser default” clears both the account preference and the cookie. Language changes use an ordinary CSRF-protected HTTP POST and a full reload; unsaved forms are discarded, and other mounted tabs keep their language until reloaded. Traditional Chinese does not select Simplified Chinese automatically.

Public authentication, Observatory login and invite pages share one language chooser in the footer; do not add copies inside their cards. The mobile footer stays on a single row: compact version and copyright at the left, GitHub and language controls at the right. Full product and company names remain accessible, with their expanded text visible on larger screens. Compact language triggers are icon-only and match the neighboring controls: circular/muted in the footer, square/muted in the admin toolbar. The current language remains in the accessible text, tooltip and menu. Footer menus open upward and align to the right edge of their trigger. Clicking outside dismisses the menu without swallowing the clicked action; Escape closes it and returns focus to the trigger. Verify opened menus and actual option clicks on both static and LiveView pages.

The Settings Appearance chooser opens upward. Its menu uses start alignment in the stacked mobile layout and end alignment at the same `md` breakpoint that moves the trigger to the right. Keep these responsive positions together; verify opened-menu bounds and option hit targets immediately below and above the breakpoint as well as at narrow and short desktop window sizes.

Email language is independent of the invite acceptance page. Pool invitations store a language chosen by the inviter; the initial choice follows a known recipient account, then the inviter's current UI locale, then English. Resends reuse the stored choice. Email alert channels store one language, defaulting to English; webhook payloads stay English. Operator access mail uses the recipient account language. SMTP test mail uses the requesting operator's current language. Unknown stored email locales fall back to English rather than preventing delivery.

Dates keep the selected timezone. Chinese long dates use `年/月/日`; numeric and ISO formats, compact durations, currency and number units remain unambiguous and unchanged.

## Hardcoded-string scanner

The scanner reports heuristic candidates per file; it is not a linguistic completeness proof. Its baseline is `hardcoded_baseline.json`. Review every candidate and every allowlist regex; each allowlist entry needs a reason comment and must describe non-translatable brand names, identifiers, units or machine-only text, not hide an unconverted UI surface.

Normal scans never rewrite the baseline. After reviewing a reduction, update it explicitly:

```sh
mise x -- mix codex_pooler.i18n.scan --write-baseline
mise x -- mix codex_pooler.i18n.scan --check
```

A deliberate new human-facing string must be translated, not accommodated by raising the baseline. Human Chinese review and rendered checks at narrow and desktop widths remain required even when structural checks pass.
