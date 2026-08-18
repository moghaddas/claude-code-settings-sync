#!/usr/bin/env bash
#
# install.sh — install a Claude Code managed-settings policy from a git
# checkout, and keep it current without an MDM.
#
# Every published way to deploy managed-settings.json assumes you have Jamf,
# Intune, Group Policy or Ansible. Most teams have none of those. This uses the
# thing they do have: a git repository, a timer, and one sudoers rule.
#
#   install.sh              install the policy and the sync timer
#   install.sh --uninstall  remove both
#   install.sh --no-timer   install the policy only
#   install.sh --dry-run    print what would happen, change nothing
#
# READ THE SECURITY SECTION IN THE README BEFORE YOU DEPLOY THIS. The sudoers
# rule that makes unattended updates possible also means the policy is not an
# enforcement boundary against the machine's own user.

set -uo pipefail

POLICY_SRC="${POLICY_SRC:-}"
SUBTREE="${SUBTREE:-}"   # empty watches the whole repository
TIMER_LABEL="${TIMER_LABEL:-com.example.claude-settings-sync}"
STATE_DIR="${STATE_DIR:-${HOME}/.config/claude-settings-sync}"

DRY_RUN=false
WITH_TIMER=true
UNINSTALL=false

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
run()  { if $DRY_RUN; then printf '     would run: %s\n' "$*"; else "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --no-timer)  WITH_TIMER=false ;;
    --uninstall) UNINSTALL=true ;;
    --policy)    POLICY_SRC="${2:-}"; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *)           die "unknown flag: $1" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")}"
[[ -n "$POLICY_SRC" ]] || POLICY_SRC="${SCRIPT_DIR}/managed-settings.json"

# ---- platform ---------------------------------------------------------------

case "$(uname -s)" in
  Darwin)
    PLATFORM=macos
    DEST="/Library/Application Support/ClaudeCode/managed-settings.json"
    OWNER="root:wheel"
    INSTALL_BIN="/usr/bin/install"
    AGENT_PATH="${HOME}/Library/LaunchAgents/${TIMER_LABEL}.plist"
    ;;
  Linux)
    PLATFORM=linux
    DEST="/etc/claude-code/managed-settings.json"
    OWNER="root:root"
    INSTALL_BIN="$(command -v install || echo /usr/bin/install)"
    UNIT_DIR="${HOME}/.config/systemd/user"
    ;;
  *) die "unsupported platform: $(uname -s)" ;;
esac

SUDOERS_FRAGMENT="/etc/sudoers.d/$(printf '%s' "$TIMER_LABEL" | tr '.' '-')"
# Set SUBTREE to a path to watch only part of the repository, which
# keeps unrelated commits from triggering a reinstall.
TREE_REF="${SUBTREE:+HEAD:${SUBTREE}}"
TREE_REF="${TREE_REF:-HEAD^{tree}}"
MARKER="${STATE_DIR}/last-installed-sha"

# ---- uninstall --------------------------------------------------------------

if $UNINSTALL; then
  note "removing the policy at ${DEST}"
  run sudo rm -f "$DEST"
  note "removing the sudoers fragment"
  run sudo rm -f "$SUDOERS_FRAGMENT"
  if [[ $PLATFORM == macos ]]; then
    run launchctl bootout "gui/$(id -u)/${TIMER_LABEL}" 2>/dev/null || true
    run rm -f "$AGENT_PATH"
  else
    run systemctl --user disable --now "${TIMER_LABEL}.timer" 2>/dev/null || true
    run rm -f "${UNIT_DIR}/${TIMER_LABEL}.service" "${UNIT_DIR}/${TIMER_LABEL}.timer"
    run systemctl --user daemon-reload 2>/dev/null || true
  fi
  run rm -f "$MARKER"
  note "done. Claude Code falls back to user settings on its next start."
  exit 0
fi

# ---- preflight --------------------------------------------------------------

command -v git >/dev/null || die "git is required"
[[ -r "$POLICY_SRC" ]] || die "no policy file at ${POLICY_SRC} (pass --policy PATH)"

# A malformed policy is worse than none: Claude Code ignores the file and
# every machine silently loses the policy with nothing to see in the UI.
if command -v jq >/dev/null; then
  jq empty "$POLICY_SRC" 2>/dev/null || die "${POLICY_SRC} is not valid JSON"
elif command -v python3 >/dev/null; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$POLICY_SRC" \
    || die "${POLICY_SRC} is not valid JSON"
else
  warn "neither jq nor python3 found: installing ${POLICY_SRC} unvalidated"
fi

[[ -d "${REPO_DIR}/.git" ]] || warn "${REPO_DIR} is not a git checkout, so the timer will have nothing to pull"

note "policy:   ${POLICY_SRC}"
note "dest:     ${DEST}"
note "repo:     ${REPO_DIR}"
$DRY_RUN && note "dry run: nothing below is executed"

# ---- 1. the policy ----------------------------------------------------------

note "installing the policy (${OWNER}, 0644)"
run sudo mkdir -p "$(dirname "$DEST")"
run sudo "$INSTALL_BIN" -m 0644 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$POLICY_SRC" "$DEST"

# ---- 2. the sudoers fragment ------------------------------------------------
#
# Without this the timer cannot replace a root-owned file, so an unattended
# update would prompt for a password nobody is there to type, and the policy
# would quietly stop tracking the repository.
#
# The rule is pinned to one command, one source path and one destination. It
# does not grant a root shell. It does mean the owner of this account can
# choose the contents of their own policy file. See the README.

note "installing the sudoers fragment at ${SUDOERS_FRAGMENT}"
FRAGMENT_TMP="$(mktemp)"
cat > "$FRAGMENT_TMP" <<EOF
# Managed by ${TIMER_LABEL}. Lets the per-user sync timer reinstall the
# Claude Code policy without a password prompt. Pinned to one exact command.
${USER} ALL=(root) NOPASSWD: ${INSTALL_BIN} -m 0644 -o ${OWNER%%:*} -g ${OWNER##*:} ${POLICY_SRC} ${DEST}
${USER} ALL=(root) NOPASSWD: /bin/mkdir -p $(dirname "$DEST")
EOF

if $DRY_RUN; then
  printf '     would install this fragment:\n'
  sed 's/^/       /' "$FRAGMENT_TMP"
  rm -f "$FRAGMENT_TMP"
else
  # visudo -c on the fragment first: a syntax error in /etc/sudoers.d locks
  # every sudo on the machine, including the one needed to undo it.
  if sudo visudo -c -f "$FRAGMENT_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g "${OWNER##*:}" "$FRAGMENT_TMP" "$SUDOERS_FRAGMENT"
  else
    warn "the generated sudoers fragment did not validate, skipping it"
    warn "unattended updates will prompt for a password and therefore fail"
  fi
  rm -f "$FRAGMENT_TMP"
fi

# ---- 3. the timer -----------------------------------------------------------

if $WITH_TIMER; then
  if [[ $PLATFORM == macos ]]; then
    note "installing the LaunchAgent at ${AGENT_PATH}"
    run mkdir -p "$(dirname "$AGENT_PATH")"
    if ! $DRY_RUN; then
      sed -e "s|__LABEL__|${TIMER_LABEL}|g" \
          -e "s|__USER_HOME__|${HOME}|g" \
          -e "s|__REPO_DIR__|${REPO_DIR}|g" \
          -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
          "${SCRIPT_DIR}/templates/launchd.plist" > "$AGENT_PATH"
      launchctl bootout "gui/$(id -u)/${TIMER_LABEL}" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$AGENT_PATH"
    fi
  else
    note "installing the systemd user units in ${UNIT_DIR}"
    run mkdir -p "$UNIT_DIR"
    if ! $DRY_RUN; then
      for unit in service timer; do
        sed -e "s|__LABEL__|${TIMER_LABEL}|g" \
            -e "s|__REPO_DIR__|${REPO_DIR}|g" \
            -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
            "${SCRIPT_DIR}/templates/systemd.${unit}" > "${UNIT_DIR}/${TIMER_LABEL}.${unit}"
      done
      systemctl --user daemon-reload
      systemctl --user enable --now "${TIMER_LABEL}.timer"
    fi
    # A user timer only runs while the user has a session. On a server that
    # means it never fires unattended until lingering is on.
    if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      warn "lingering is off for ${USER}, so the timer stops when you log out"
      warn "enable it with: sudo loginctl enable-linger ${USER}"
    fi
  fi
fi

# ---- 4. the marker ----------------------------------------------------------
#
# Records the tree SHA of the watched subtree, not HEAD. Comparing HEAD is
# blind to a run that failed after a successful pull: the next run would see
# no movement and never retry. A tree SHA compared against what was last
# INSTALLED self-heals instead.

run mkdir -p "$STATE_DIR"
if ! $DRY_RUN && [[ -d "${REPO_DIR}/.git" ]]; then
  git -C "$REPO_DIR" rev-parse "$TREE_REF" > "$MARKER" 2>/dev/null \
    || warn "could not resolve ${TREE_REF}, so the timer reinstalls on its first run"
fi

# ---- 5. verify --------------------------------------------------------------

note "done."
cat <<EOF

Verify:

  1. The policy is in place and root-owned:
       ls -l "${DEST}"

  2. Claude Code has picked it up. Start a new session and run /status; the
     managed policy is listed there. A running session does not reload it.

  3. The timer is loaded:
EOF
if [[ $PLATFORM == macos ]]; then
  printf '       launchctl print "gui/$(id -u)/%s" | head -5\n\n' "$TIMER_LABEL"
else
  printf '       systemctl --user list-timers %s.timer\n\n' "$TIMER_LABEL"
fi
