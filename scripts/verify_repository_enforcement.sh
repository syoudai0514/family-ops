#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-}"
BRANCH="${REPOSITORY_ENFORCEMENT_BRANCH:-main}"
API_BASE="${GITHUB_API_URL:-https://api.github.com}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

usage() {
  cat <<'EOF'
Usage: verify_repository_enforcement.sh [--repo owner/repo] [--branch main] [--api-base URL]

Read GitHub's effective protection state and fail unless CF-15 preventive
controls are evidenced by either:
  - a complete Active branch ruleset; or
  - a complete classic branch-protection rule.

This script is read-only; it never changes repository settings.

Environment defaults:
  GITHUB_REPOSITORY                 owner/repo
  REPOSITORY_ENFORCEMENT_BRANCH     main
  GITHUB_API_URL                    https://api.github.com
  GH_TOKEN or GITHUB_TOKEN          bearer token. Ruleset verification needs
                                    enough visibility to expose bypass_actors;
                                    classic protection needs admin-readable
                                    branch-protection state.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "ERROR: --repo requires a value" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    --branch)
      [ "$#" -ge 2 ] || { echo "ERROR: --branch requires a value" >&2; exit 2; }
      BRANCH="$2"; shift 2 ;;
    --api-base)
      [ "$#" -ge 2 ] || { echo "ERROR: --api-base requires a value" >&2; exit 2; }
      API_BASE="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ ! "$REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "ERROR: repository must be owner/repo (use --repo or GITHUB_REPOSITORY)" >&2
  exit 2
fi
if [ -z "$BRANCH" ]; then
  echo "ERROR: branch must not be empty" >&2
  exit 2
fi
for cmd in curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command not found: $cmd" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

api_get() {
  local path="$1"
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2026-03-10"
  )
  if [ -n "$TOKEN" ]; then
    headers+=( -H "Authorization: Bearer $TOKEN" )
  fi
  curl --fail --silent --show-error "${headers[@]}" \
    "${API_BASE%/}/repos/${REPO}/${path}"
}

BRANCH_JSON="$TMP/branch.json"
RULESETS_JSON="$TMP/rulesets.json"
PROTECTION_JSON="$TMP/protection.json"
RULESET_IDS_FILE="$TMP/ruleset-ids.txt"

api_get "branches/$BRANCH" > "$BRANCH_JSON" || {
  echo "ERROR: failed to read branch state for $REPO:$BRANCH" >&2
  exit 2
}
api_get "rulesets" > "$RULESETS_JSON" || {
  echo "ERROR: failed to read repository rulesets for $REPO" >&2
  exit 2
}

python3 - "$BRANCH_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if data.get("protected") is not True:
    print("FAIL: target branch is not protected by branch protection or rulesets", file=sys.stderr)
    raise SystemExit(1)
PY

# Parse the list in a normal subprocess so malformed JSON / unexpected shape
# cannot be hidden by bash process-substitution exit-status behavior.
python3 - "$RULESETS_JSON" > "$RULESET_IDS_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, list):
    print("ERROR: rulesets response was not a list", file=sys.stderr)
    raise SystemExit(2)
for item in data:
    if item.get("enforcement") == "active" and item.get("target") == "branch" and item.get("id") is not None:
        print(item["id"])
PY
mapfile -t RULESET_IDS < "$RULESET_IDS_FILE"

DETAIL_FILES=()
for id in "${RULESET_IDS[@]}"; do
  detail="$TMP/ruleset-$id.json"
  api_get "rulesets/$id" > "$detail" || {
    echo "ERROR: failed to read ruleset $id" >&2
    exit 2
  }
  DETAIL_FILES+=("$detail")
done

# Classic branch-protection detail requires stronger repository permission and
# may legitimately return 404/403 when protection is supplied only by a
# ruleset or the caller cannot read admin protection state. That is not an
# error if a complete ruleset path independently proves CF-15.
PROTECTION_AVAILABLE=0
if api_get "branches/$BRANCH/protection" > "$PROTECTION_JSON" 2>/dev/null; then
  PROTECTION_AVAILABLE=1
else
  : > "$PROTECTION_JSON"
fi

python3 - "$BRANCH" "$PROTECTION_AVAILABLE" "$PROTECTION_JSON" "${DETAIL_FILES[@]}" <<'PY'
import fnmatch
import json
import sys

branch = sys.argv[1]
protection_available = sys.argv[2] == "1"
protection_path = sys.argv[3]
ruleset_paths = sys.argv[4:]
target_ref = f"refs/heads/{branch}"
required_checks = {
    "web (lint / typecheck / test / build)",
    "db (migrations / RLS / RPC / idempotency / quota)",
    "edge-functions (deno lint / check / auth-matrix lint)",
    "supabase-integration (real CLI stack)",
    "operational-safety (backup controls)",
}
required_rules = {"pull_request", "required_status_checks", "non_fast_forward", "deletion"}


def matches(pattern: str) -> bool:
    if pattern == "~DEFAULT_BRANCH":
        return branch == "main"
    if pattern == "~ALL":
        return True
    return fnmatch.fnmatchcase(target_ref, pattern) or fnmatch.fnmatchcase(branch, pattern)


def ruleset_result():
    found_rules = set()
    found_checks = set()
    matching = 0
    bypass_found = []
    bypass_visibility_missing = []

    for path in ruleset_paths:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if data.get("enforcement") != "active" or data.get("target") != "branch":
            continue

        ref = ((data.get("conditions") or {}).get("ref_name") or {})
        includes = ref.get("include") or []
        excludes = ref.get("exclude") or []
        if includes and not any(matches(str(p)) for p in includes):
            continue
        if any(matches(str(p)) for p in excludes):
            continue

        matching += 1
        name = data.get("name") or str(data.get("id"))
        if "bypass_actors" not in data:
            bypass_visibility_missing.append(name)
        elif data.get("bypass_actors"):
            bypass_found.append(name)

        for rule in data.get("rules") or []:
            rule_type = rule.get("type")
            if rule_type:
                found_rules.add(rule_type)
            if rule_type == "required_status_checks":
                params = rule.get("parameters") or {}
                for check in params.get("required_status_checks") or []:
                    context = check.get("context")
                    if context:
                        found_checks.add(context)

    errors = []
    if matching == 0:
        errors.append(f"no complete Active branch ruleset targets {branch}")
    missing_rules = sorted(required_rules - found_rules)
    missing_checks = sorted(required_checks - found_checks)
    if missing_rules:
        errors.append("ruleset missing rule types: " + ", ".join(missing_rules))
    if missing_checks:
        errors.append("ruleset missing status checks: " + "; ".join(missing_checks))
    if bypass_visibility_missing:
        errors.append(
            "cannot prove zero ruleset bypass actors because GitHub omitted bypass_actors for: "
            + ", ".join(bypass_visibility_missing)
        )
    if bypass_found:
        errors.append("ruleset bypass actors configured on: " + ", ".join(bypass_found))
    return not errors, errors


def protection_result():
    if not protection_available:
        return False, ["classic branch-protection detail is unavailable"]

    with open(protection_path, encoding="utf-8") as fh:
        data = json.load(fh)

    errors = []
    reviews = data.get("required_pull_request_reviews")
    if not isinstance(reviews, dict):
        errors.append("classic protection does not require pull requests")

    status = data.get("required_status_checks")
    checks = set()
    if isinstance(status, dict):
        checks.update(str(x) for x in (status.get("contexts") or []) if x)
        for item in status.get("checks") or []:
            if isinstance(item, dict) and item.get("context"):
                checks.add(str(item["context"]))
    else:
        errors.append("classic protection does not require status checks")

    missing_checks = sorted(required_checks - checks)
    if missing_checks:
        errors.append("classic protection missing status checks: " + "; ".join(missing_checks))

    if ((data.get("allow_force_pushes") or {}).get("enabled")) is not False:
        errors.append("classic protection does not explicitly block force pushes")
    if ((data.get("allow_deletions") or {}).get("enabled")) is not False:
        errors.append("classic protection does not explicitly block branch deletion")
    if ((data.get("enforce_admins") or {}).get("enabled")) is not True:
        errors.append("classic protection does not enforce rules for administrators")

    if isinstance(reviews, dict):
        bypass = reviews.get("bypass_pull_request_allowances") or {}
        for kind in ("users", "teams", "apps"):
            if bypass.get(kind):
                errors.append(f"classic protection has PR bypass {kind}")

    return not errors, errors


ruleset_ok, ruleset_errors = ruleset_result()
protection_ok, protection_errors = protection_result()

if ruleset_ok:
    print(f"PASS: {branch} release enforcement is active via repository ruleset(s)")
    print("PASS: PR + five release checks + no force push + no deletion + zero visible ruleset bypass actors")
    raise SystemExit(0)

if protection_ok:
    print(f"PASS: {branch} release enforcement is active via classic branch protection")
    print("PASS: PR + five release checks + admin enforcement + no force push + no deletion + no PR bypass allowances")
    raise SystemExit(0)

for error in ruleset_errors:
    print("RULESET: " + error, file=sys.stderr)
for error in protection_errors:
    print("PROTECTION: " + error, file=sys.stderr)
print("FAIL: neither GitHub protection mechanism independently satisfies CF-15", file=sys.stderr)
raise SystemExit(1)
PY
