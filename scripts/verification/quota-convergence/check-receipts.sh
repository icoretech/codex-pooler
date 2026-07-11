#!/usr/bin/env bash
set -euo pipefail

mode=""
receipt=""

validate() {
  local expected_mode="$1"
  local receipt_path="$2"

  [[ -f "$receipt_path" ]] || return 1
  [[ "$expected_mode" == "equivalent" || "$expected_mode" == "changed-second" ]] || return 1

  RECEIPT_MODE="$expected_mode" ruby -rbigdecimal -rtime - "$receipt_path" <<'RUBY'
path = ARGV.fetch(0)
mode = ENV.fetch("RECEIPT_MODE")
lines = File.readlines(path, chomp: true)
raise "wrong line count" unless lines.length == 7
raise "blank line" if lines.any?(&:empty?)

fields = lines.map { |line| line.split("\t", -1) }
raise "unexpected record order" unless fields.map(&:first) == %w[transition transition row row projection cleanup provenance]

transitions = fields.first(2)
raise "duplicate transition scope" unless transitions.map { |row| row[2] }.sort == %w[account model]

expected = if mode == "equivalent"
  {"account" => %w[22 22 14], "model" => %w[22 22 1]}
else
  {"account" => %w[22 22 22], "model" => %w[22 22 22]}
end

transitions.each do |row|
  raise "invalid transition schema" unless row.length == 7 && row[1] == mode && row[6] == "passed"
  actual = row[3, 3].map { |value| BigDecimal(value).to_s("F") }
  wanted = expected.fetch(row[2]).map { |value| BigDecimal(value).to_s("F") }
  raise "invalid transition values" unless actual == wanted
end

rows = fields[2, 2]
raise "duplicate row scope" unless rows.map { |row| row[1] }.sort == %w[account model]
rows.each do |row|
  raise "invalid row schema" unless row.length == 11 && row[0] == "row"
  raise "invalid window metadata" unless row[4] == "primary" && row[5] == "codex_usage_api" && row[6] == "observed" && row[7] == "fresh"
  observed = Time.iso8601(row[8])
  reset = Time.iso8601(row[9])
  raise "invalid chronology" unless reset > observed
  percent = BigDecimal(row[10])
  raise "invalid percentage" unless percent >= 0 && percent <= 100
end

raise "invalid account identity" unless rows.find { |row| row[1] == "account" }[2, 2] == %w[account account]
model = rows.find { |row| row[1] == "model" }
raise "invalid model identity" unless model[2] == "codex_model" && model[3] == "example_model"

projection = fields[4]
expected_projection = "quota_scope,quota_family,quota_key,window_kind,source,source_precision,freshness_state,observed_at,reset_at,used_percent"
raise "invalid projection" unless projection == ["projection", expected_projection, "passed"]
raise "invalid cleanup" unless fields[5] == %w[cleanup proof-fixture passed]

provenance = fields[6]
raise "invalid provenance" unless provenance.length == 4 && provenance[0] == "provenance" && provenance[3] == "passed"
raise "invalid source sha" unless provenance[1].match?(/\A[0-9a-f]{40}\z/)
raise "invalid image digest" unless provenance[2].match?(/\Asha256:[0-9a-f]{64}\z/)

unsafe = /(postgres(?:ql)?:\/\/|bearer |authorization|token|password|chatgpt|account_id|raw_limit|raw_metered|metadata)/i
raise "unsafe receipt content" if lines.any? { |line| line.match?(unsafe) }
RUBY
}

if [[ "${1:-}" == "--self-test" ]]; then
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  valid="$temp_dir/valid.tsv"
  cat >"$valid" <<'EOF'
transition	equivalent	account	22	22	14	passed
transition	equivalent	model	22	22	1	passed
row	account	account	account	primary	codex_usage_api	observed	fresh	2026-01-01T00:00:00Z	2026-01-01T02:00:00Z	14
row	model	codex_model	example_model	primary	codex_usage_api	observed	fresh	2026-01-01T00:00:00Z	2026-01-01T02:00:00Z	1
projection	quota_scope,quota_family,quota_key,window_kind,source,source_precision,freshness_state,observed_at,reset_at,used_percent	passed
cleanup	proof-fixture	passed
provenance	0123456789abcdef0123456789abcdef01234567	sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef	passed
EOF
  validate equivalent "$valid"
  cp "$valid" "$temp_dir/duplicate.tsv"
  printf 'cleanup\tproof-fixture\tpassed\n' >>"$temp_dir/duplicate.tsv"
  ! validate equivalent "$temp_dir/duplicate.tsv"
  cp "$valid" "$temp_dir/chronology.tsv"
  perl -pi -e 's/2026-01-01T02:00:00Z/2025-01-01T02:00:00Z/' "$temp_dir/chronology.tsv"
  ! validate equivalent "$temp_dir/chronology.tsv"
  cp "$valid" "$temp_dir/unsafe.tsv"
  printf 'authorization: bearer unsafe\n' >>"$temp_dir/unsafe.tsv"
  ! validate equivalent "$temp_dir/unsafe.tsv"
  ! validate changed-second /dev/null
  printf 'receipt self-test passed\n'
  exit 0
fi

while (($#)); do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --receipt) receipt="${2:-}"; shift 2 ;;
    *) printf 'unsupported argument\n' >&2; exit 2 ;;
  esac
done

validate "$mode" "$receipt" || { printf 'invalid receipt\n' >&2; exit 1; }
