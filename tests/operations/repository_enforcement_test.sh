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
  */branches/main/protection)
    [ -f "$FIXTURE_DIR/protection.json" ] || exit 22
    cat "$FIXTURE_DIR/protection.json"
    ;;
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

printf '%s\n' '{"name":"main","protected":true}' > "$TMP/fixtures/branch.json"

write_good_ruleset() {
  rm -f "$TMP/fixtures/protection.json"
  cat > "$TMP/fixtures/rulesets.json" <<'EOF'
[{"id":1,"name":"main-release","target":"branch","enforcement":"active"}]
EOF
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

write_good_protection() {
  printf '%s\n' '[]' > "$TMP/fixtures/rulesets.json"
  rm -f "$TMP/fixtures/ruleset-1.json"
  cat > "$TMP/fixtures/protection.json" <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "web (lint / typecheck / test / build)",
      "db (migrations / RLS / RPC / idempotency / quota)",
      "edge-functions (deno lint / check / auth-matrix lint)",
      "supabase-integration (real CLI stack)",
      "operational-safety (backup controls)"
    ]
  },
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "bypass_pull_request_allowances": {"users": [], "teams": [], "apps": []}
  },
  "enforce_admins": {"enabled": true},
  "allow_force_pushes": {"enabled": false},
  "allow_deletions": {"enabled": false}
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

# Complete Active ruleset path passes.
write_good_ruleset
run_verify >/dev/null

# Unprotected target branch is never acceptable.
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

# Force-push prevention is mandatory for rulesets.
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

# Branch deletion prevention is mandatory for rulesets.
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

# GitHub may omit bypass_actors without enough ruleset visibility. Absence
# must never be interpreted as an empty bypass list.
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

# A configured standing ruleset bypass is RED.
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

# A complete classic branch-protection path is an equivalent preventive
# mechanism and must pass when no ruleset is configured.
write_good_protection
run_verify >/dev/null

# Classic protection must include every release-critical check.
write_good_protection
python3 - "$TMP/fixtures/protection.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["required_status_checks"]["contexts"].remove("operational-safety (backup controls)")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# Admins must not retain a normal-path bypass under classic protection.
write_good_protection
python3 - "$TMP/fixtures/protection.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["enforce_admins"]["enabled"] = False
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# Force pushes and branch deletion must be explicitly disabled.
write_good_protection
python3 - "$TMP/fixtures/protection.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["allow_force_pushes"]["enabled"] = True
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

write_good_protection
python3 - "$TMP/fixtures/protection.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["allow_deletions"]["enabled"] = True
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# PR bypass allowances are standing bypasses and therefore RED.
write_good_protection
python3 - "$TMP/fixtures/protection.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["required_pull_request_reviews"]["bypass_pull_request_allowances"]["users"] = ["octocat"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
expect_fail run_verify

# Protected=true without either complete mechanism is still RED.
printf '%s\n' '[]' > "$TMP/fixtures/rulesets.json"
rm -f "$TMP/fixtures/ruleset-1.json" "$TMP/fixtures/protection.json"
expect_fail run_verify

bash "$VERIFY" --help >/dev/null
bash -n "$VERIFY"

echo "PASS: repository enforcement verifier regression tests"
