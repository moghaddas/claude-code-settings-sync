#!/usr/bin/env bash
#
# sync.sh — pull the policy repository and reinstall when the watched subtree
# has moved. Driven by the LaunchAgent or the systemd timer that install.sh
# sets up; there is no reason to run it by hand except to test it.
#
# It compares the current tree SHA of the watched subtree against the SHA that
# was last INSTALLED, not against the previous HEAD. Comparing HEAD is blind to
# a run that pulled successfully and then failed to install: the next run sees
# no movement and never retries, so the machine sits on a stale policy for ever
# with nothing in the log to say so.
#
# Two things make a run give up quietly rather than break anything:
#
#   Non-interactive git auth. An SSH key with a passphrase, or HTTPS with no
#   cached credential, cannot prompt from a timer. The pull fails, the run
#   keeps the tree it has, and it logs that.
#
#   The sudoers fragment. Without it the reinstall cannot write a root-owned
#   file. The marker is not advanced, so the next run tries again.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")}"
SUBTREE="${SUBTREE:-}"   # empty watches the whole repository
STATE_DIR="${STATE_DIR:-${HOME}/.config/claude-settings-sync}"
INSTALLER="${INSTALLER:-${SCRIPT_DIR}/install.sh}"

# Set SUBTREE to a path to watch only part of the repository, which
# keeps unrelated commits from triggering a reinstall.
TREE_REF="${SUBTREE:+HEAD:${SUBTREE}}"
TREE_REF="${TREE_REF:-HEAD^{tree}}"
MARKER="${STATE_DIR}/last-installed-sha"
LOG="${STATE_DIR}/sync.log"

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# Keep the log from growing without bound on a machine nobody looks at.
if [[ -f "$LOG" ]] && [[ $(wc -c < "$LOG") -gt 1048576 ]]; then
  tail -n 500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  log "skip: ${REPO_DIR} is not a git checkout"
  exit 0
fi

if ! GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" pull --ff-only --quiet 2>>"$LOG"; then
  log "pull failed, check non-interactive auth. Continuing with the current tree."
fi

current="$(git -C "$REPO_DIR" rev-parse "$TREE_REF" 2>/dev/null || true)"
if [[ -z "$current" ]]; then
  log "could not resolve ${TREE_REF} in ${REPO_DIR}"
  exit 0
fi

installed=""
[[ -r "$MARKER" ]] && installed="$(cat "$MARKER" 2>/dev/null || true)"

if [[ "$current" == "$installed" ]]; then
  exit 0
fi

log "${TREE_REF} moved ${installed:-none} -> ${current}, reinstalling"

if bash "$INSTALLER" --no-timer >>"$LOG" 2>&1; then
  printf '%s' "$current" > "$MARKER"
  log "installed ${current}"
else
  # The marker stays where it was, so the next run retries.
  log "install failed, keeping marker at ${installed:-none}"
  exit 1
fi
