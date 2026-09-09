#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="$ROOT/scripts/verify_repository_enforcement.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fixtures"

cat > "$TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
case "$url" in
  */branches/main)
    cat "$FIXTURE_DIR/branch.json"
    ;;
  */rulesets)
    cat "$FIXTURE_DIR/rulesets.json"
    ;;
  */rulesets/1)
    cat "$FIXTURE_DIR/ruleset-1.json"
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 22
    ;;
esac
FAKE_CURL
chmod +x "$TMP/bin/curl"

cat > "$TMP/fixtures/branch.json" <<'EOF'
{"name":"main","protected":true}
EOF
cat > "$TMP/fixtures/rulesets.json" <<'EOF'
[{"id":1,"name":"main-release","target":"branch","enforcement":"active"}]
EOF

write_good_ruleset() {
  cat > "$TMP/fixtures/ruleset-1.json" <<'EOF'
{
  "id": 1,
  "name": "main-release",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "web (lint / typecheck / test / build)"},
        {"context": "db (migrations / RLS / RPC / idempotency / quota)"},
        {"context": "edge-functions (deno lint / check / auth-matrix lint)"},
        {"context": "supabase-integration (real CLI stack)"},
        {"context": "operational-safety (backup controls)"}
      ]
    }},
    {"type": "non_fast_forward"},
    {"type": "deletion"}
  ]
}
EOF
}

run_verify() {
  env \
    PATH="$TMP/bin:$PATH" \
    FIXTURE_DIR="$TMP/fixtures" \
    GITHUB_REPOSITORY="syoudai0514/family-ops" \
    GITHUB_API_URL="https://api.example.test" \
    bash "$VERIFY"
}

expect_fail() {
  set +e
  "$@" >/dev/null 2>&1
  local status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "FAIL: expected command to fail: $*" >&2
    exit 1
  fi
}

write_good_ruleset
run_verify >/dev/null

# Unprotected target branch is never acceptable even if a ruleset fixture exists.
printf '%s\n' '{"name":"main","protected":false}' > "$TMP/fixtures/branch.json"
expect_fail run_verify
printf '%s\n' '{"name":"main","protected":true}' > "$TMP/fixtures/branch.json"

# Missing a release-critical context must remain RED.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
for rule in data["rules"]:
    if rule["type"] == "required_status_checks":
        rule["parameters"]["required_status_checks"] = [
            item for item in rule["parameters"]["required_status_checks"]
            if item["context"] != "operational-safety (backup controls)"
        ]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# Force-push prevention is mandatory.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["rules"] = [r for r in data["rules"] if r["type"] != "non_fast_forward"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# Branch deletion prevention is mandatory.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["rules"] = [r for r in data["rules"] if r["type"] != "deletion"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# GitHub may omit bypass_actors for a caller without enough ruleset visibility.
# Absence must never be interpreted as an empty bypass list.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data.pop("bypass_actors", None)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# A configured routine bypass makes the control non-mechanical for this contract.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["bypass_actors"] = [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# A ruleset that excludes main is not an effective main control.
write_good_ruleset
python3 - "$TMP/fixtures/ruleset-1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["conditions"]["ref_name"] = {"include": ["refs/heads/*"], "exclude": ["refs/heads/main"]}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

bash "$VERIFY" --help >/dev/null
bash -n "$VERIFY"

echo "PASS: repository enforcement verifier regression tests"
