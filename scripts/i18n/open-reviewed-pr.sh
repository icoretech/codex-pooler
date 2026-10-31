#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'translation-pr: %s\n' "$*" >&2; exit 2; }
if [[ ${1:-} == --help && $# == 1 ]]; then
  echo 'usage: open-reviewed-pr.sh (GitHub Actions main checkout after validated reviewed-only pull)'
  exit 0
fi
[[ $# == 0 ]] || fail 'unexpected arguments'
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == icoretech/codex-pooler && ${GITHUB_REF:-} == refs/heads/main ]] || fail 'canonical main workflow required'
[[ ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] || fail 'invalid run identity'
[[ $(git symbolic-ref --short HEAD) == main ]] || fail 'main checkout required'
git diff --cached --quiet || fail 'index must be empty'
[[ -z $(git ls-files --others --exclude-standard) ]] || fail 'unexpected untracked files'
while IFS= read -r -d '' path; do
  case "$path" in
    priv/gettext/zh_CN/LC_MESSAGES/default.po|priv/gettext/zh_CN/LC_MESSAGES/errors.po|priv/gettext/zh_CN/LC_MESSAGES/emails.po) ;;
    *) fail "unexpected changed path: $path" ;;
  esac
done < <(git diff --name-only -z)
if git diff --quiet; then
  echo 'translation-pr: no reviewed changes'
  exit 0
fi
existing=$(gh pr list --repo "$GITHUB_REPOSITORY" --state open --base main --json headRefName --jq '[.[] | select(.headRefName | startswith("feat/tolgee-translations-"))] | length')
[[ $existing =~ ^[0-9]+$ ]] || fail 'invalid pull request lookup result'
if [[ $existing != 0 ]]; then
  echo 'translation-pr: existing translation pull request requires review'
  exit 0
fi
branch="feat/tolgee-translations-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
git switch -c "$branch"
git add -- priv/gettext/zh_CN/LC_MESSAGES/default.po priv/gettext/zh_CN/LC_MESSAGES/errors.po priv/gettext/zh_CN/LC_MESSAGES/emails.po
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m 'fix(i18n): import reviewed Chinese translations'
gh auth setup-git
git push --set-upstream origin "$branch"
# GITHUB_TOKEN pushes do not trigger push workflows. Dispatch before opening a PR,
# so a rejected dispatch cannot leave an unvalidated PR blocking the next attempt.
gh workflow run development.yml --repo "$GITHUB_REPOSITORY" --ref "$branch" --field "expected_sha=$(git rev-parse HEAD)"
body=$(mktemp)
trap 'rm -f "$body"' EXIT
cat > "$body" <<'BODY'
Import reviewed Chinese translations from the translation project while preserving untranslated baseline entries and local catalog metadata.

The complete catalogs passed the offline localization gate. Development checks are dispatched for this branch; merge only after those checks and review pass.
BODY
gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" --title 'fix(i18n): import reviewed Chinese translations' --body-file "$body"
printf 'translation-pr: Development dispatched for %s at %s\n' "$branch" "$(git rev-parse HEAD)"
