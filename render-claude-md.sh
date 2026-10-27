#!/usr/bin/env bash
#
# render-claude-md.sh: write the Markdown files in claude-md/ into the
# `claudeMd` key of the policy, so the shared instructions are edited as
# Markdown instead of as one escaped JSON string.
#
#   render-claude-md.sh          rewrite the claudeMd line in place
#   render-claude-md.sh --check  exit 1 when the committed claudeMd does not
#                                match the committed Markdown
#   --repo PATH                  the policy checkout, default the enclosing one
#   --policy REL                 the policy within it, default managed-settings.json
#
# claude-md/ sits beside the policy. Every *.md in it is joined in file name
# order with one blank line between files. Without that directory claudeMd is
# written by hand and --check passes.

set -euo pipefail

POLICY_REL="${POLICY_REL:-managed-settings.json}"
REPO_DIR="${REPO_DIR:-}"
# Managed claudeMd loads into every session and every subagent on the machine,
# so its size is paid on every turn. Nothing else measures it.
CLAUDE_MD_MAX_BYTES="${CLAUDE_MD_MAX_BYTES:-16384}"
CHECK=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK=true ;;
    --repo)    REPO_DIR="${2:-}"; shift ;;
    --policy)  POLICY_REL="${2:-}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *)         die "unknown flag: $1" ;;
  esac
  shift
done

if [[ -z "$REPO_DIR" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not in a git checkout. Pass --repo PATH."
fi

POLICY_DIR="$(dirname "$POLICY_REL")"
[[ "$POLICY_DIR" == "." ]] && POLICY_DIR=""
MD_REL="${POLICY_DIR:+${POLICY_DIR}/}claude-md"

# Prints the files named on stdin joined by one blank line, whatever their
# trailing newlines. $1 prints one file given its path relative to the repo.
join_md() {
  local reader="$1" first=true f
  while IFS= read -r f; do
    $first || printf '\n\n'
    first=false
    printf '%s' "$("$reader" "$f")"
  done
}

claude_md_of() {
  if command -v jq >/dev/null; then
    jq -r '.claudeMd // ""'
  else
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("claudeMd") or "")'
  fi
}

# ---- check ------------------------------------------------------------------
#
# Judges HEAD, never the working tree: HEAD is what install.sh installs, and an
# uncommitted edit must not hold back every other policy update on the machine.

if $CHECK; then
  git -C "$REPO_DIR" cat-file -e "HEAD:${MD_REL}" 2>/dev/null || exit 0
  committed() { git -C "$REPO_DIR" show "HEAD:$1"; }
  # Regular files only, matching the find below, so a symlink counts on neither side.
  rendered="$(git -C "$REPO_DIR" ls-tree "HEAD:${MD_REL}" \
    | awk -F'\t' '{ split($1, m, " ") } m[2] == "blob" && m[1] != "120000" && $2 ~ /\.md$/ { print $2 }' \
    | LC_ALL=C sort | sed "s|^|${MD_REL}/|" | join_md committed)"
  [[ "$(committed "$POLICY_REL" | claude_md_of)" == "$rendered" ]] && exit 0
  die "claudeMd in ${POLICY_REL} does not match ${MD_REL}/*.md at HEAD. Run render-claude-md.sh and commit."
fi

# ---- render -----------------------------------------------------------------

command -v python3 >/dev/null || die "python3 is required to rewrite the policy"
[[ -d "${REPO_DIR}/${MD_REL}" ]] || die "no ${MD_REL}/ beside the policy"
files="$(cd "$REPO_DIR" && find "$MD_REL" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)"
[[ -n "$files" ]] || die "no .md files in ${MD_REL}/"

on_disk() { cat "${REPO_DIR}/$1"; }
rendered="$(printf '%s\n' "$files" | join_md on_disk)"

bytes="$(printf '%s' "$rendered" | wc -c | tr -d ' ')"
(( bytes <= CLAUDE_MD_MAX_BYTES )) \
  || die "rendered claudeMd is ${bytes} bytes, over the ${CLAUDE_MD_MAX_BYTES}-byte limit"

# Replaces only the claudeMd line, so the policy keeps its hand-written layout.
POLICY="${REPO_DIR}/${POLICY_REL}"
tmp="$(mktemp "${POLICY}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
RENDERED="$rendered" python3 - "$POLICY" "$tmp" <<'PY'
import json, os, re, sys
src, dst = sys.argv[1], sys.argv[2]
rendered = os.environ["RENDERED"]
text = open(src, encoding="utf-8").read()
pattern = r'^([ \t]*)"claudeMd":[ \t]*"(?:[^"\\\n]|\\.)*"([ \t]*,?)[ \t]*$'
new, n = re.subn(
    pattern,
    lambda m: m.group(1) + '"claudeMd": ' + json.dumps(rendered, ensure_ascii=False) + m.group(2).strip(),
    text, count=1, flags=re.M)
if n != 1:
    sys.exit('error: no single-line "claudeMd" key in ' + src + '. Add "claudeMd": "" first.')
if json.loads(new).get("claudeMd") != rendered:
    sys.exit("error: the rewritten policy does not hold the rendered text")
open(dst, "w", encoding="utf-8").write(new)
PY
chmod 0644 "$tmp"
mv "$tmp" "$POLICY"
printf 'claudeMd: %s of %s bytes, from %s\n' "$bytes" "$CLAUDE_MD_MAX_BYTES" "$(printf '%s' "$files" | tr '\n' ' ')"
