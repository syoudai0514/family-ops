#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-}"
BRANCH="${REPOSITORY_ENFORCEMENT_BRANCH:-main}"
API_BASE="${GITHUB_API_URL:-https://api.github.com}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

usage() {
  cat <<'EOF'
Usage: verify_repository_enforcement.sh [--repo owner/repo] [--branch main] [--api-base URL]

Read GitHub's effective branch/ruleset state and fail unless CF-15 preventive
controls are active. This script is read-only; it never changes repository
settings.

Environment defaults:
  GITHUB_REPOSITORY                 owner/repo
  REPOSITORY_ENFORCEMENT_BRANCH     main
  GITHUB_API_URL                    https://api.github.com
  GH_TOKEN or GITHUB_TOKEN          bearer token; privileged ruleset visibility
                                    is required to prove zero bypass actors
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --api-base)
      API_BASE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
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
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 2
  fi
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

if ! api_get "branches/$BRANCH" > "$BRANCH_JSON"; then
  echo "ERROR: failed to read branch state for $REPO:$BRANCH" >&2
  exit 2
fi
if ! api_get "rulesets" > "$RULESETS_JSON"; then
  echo "ERROR: failed to read repository rulesets for $REPO" >&2
  exit 2
fi

python3 - "$BRANCH_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if data.get("protected") is not True:
    print("FAIL: target branch is not protected", file=sys.stderr)
    raise SystemExit(1)
PY

mapfile -t RULESET_IDS < <(python3 - "$RULESETS_JSON" <<'PY'
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
)

if [ "${#RULESET_IDS[@]}" -eq 0 ]; then
  echo "FAIL: no active branch ruleset exists" >&2
  exit 1
fi

DETAIL_FILES=()
for id in "${RULESET_IDS[@]}"; do
  detail="$TMP/ruleset-$id.json"
  if ! api_get "rulesets/$id" > "$detail"; then
    echo "ERROR: failed to read ruleset $id" >&2
    exit 2
  fi
  DETAIL_FILES+=("$detail")
done

python3 - "$BRANCH" "${DETAIL_FILES[@]}" <<'PY'
import fnmatch
import json
import sys

branch = sys.argv[1]
paths = sys.argv[2:]
target_ref = f"refs/heads/{branch}"
required_checks = {
    "web (lint / typecheck / test / build)",
    "db (migrations / RLS / RPC / idempotency / quota)",
    "edge-functions (deno lint / check / auth-matrix lint)",
    "supabase-integration (real CLI stack)",
    "operational-safety (backup controls)",
}

found_rules = set()
found_checks = set()
matching_rulesets = 0
bypass_found = []
bypass_visibility_missing = []

def matches(pattern: str) -> bool:
    if pattern == "~DEFAULT_BRANCH":
        return branch == "main"
    return fnmatch.fnmatchcase(target_ref, pattern) or fnmatch.fnmatchcase(branch, pattern)

for path in paths:
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

    matching_rulesets += 1
    ruleset_name = data.get("name") or str(data.get("id"))
    if "bypass_actors" not in data:
        bypass_visibility_missing.append(ruleset_name)
    elif data.get("bypass_actors"):
        bypass_found.append(ruleset_name)

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

if matching_rulesets == 0:
    print(f"FAIL: no active branch ruleset targets {branch}", file=sys.stderr)
    raise SystemExit(1)

required_rules = {"pull_request", "required_status_checks", "non_fast_forward", "deletion"}
missing_rules = sorted(required_rules - found_rules)
missing_checks = sorted(required_checks - found_checks)

errors = []
if missing_rules:
    errors.append("missing required rule types: " + ", ".join(missing_rules))
if missing_checks:
    errors.append("missing required status checks: " + "; ".join(missing_checks))
if bypass_visibility_missing:
    errors.append(
        "cannot prove zero bypass actors because GitHub omitted bypass_actors for: "
        + ", ".join(bypass_visibility_missing)
        + "; rerun with credentials that have sufficient ruleset visibility"
    )
if bypass_found:
    errors.append("configured bypass actors exist on matching ruleset(s): " + ", ".join(bypass_found))

if errors:
    for error in errors:
        print("FAIL: " + error, file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: {branch} release enforcement is active")
print("PASS: PR + five release checks + no force push + no deletion + zero visible bypass actors")
PY
