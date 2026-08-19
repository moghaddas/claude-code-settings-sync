#!/usr/bin/env bash
#
# install.sh: install a Claude Code managed-settings policy from a git
# checkout, and keep it current without an MDM.
#
# Every published way to deploy managed-settings.json assumes Jamf, Intune,
# Group Policy or Ansible. Most teams have none of those. This uses what they
# do have: a git repository, a timer, and one sudoers rule.
#
#   install.sh              install the policy and the sync timer
#   install.sh --uninstall  remove both
#   install.sh --no-timer   install the policy only
#   install.sh --dry-run    print what would happen, change nothing
#
# READ THE SECURITY SECTION IN THE README BEFORE YOU DEPLOY THIS.

set -uo pipefail

SUBTREE="${SUBTREE:-}"
TIMER_LABEL="${TIMER_LABEL:-com.example.claude-settings-sync}"
STATE_DIR="${STATE_DIR:-${HOME}/.config/claude-settings-sync}"
POLICY_REL="${POLICY_REL:-managed-settings.json}"
SYNC_INTERVAL_SECS="${SYNC_INTERVAL_SECS:-14400}"

DRY_RUN=false
WITH_TIMER=true
UNINSTALL=false
REPO_DIR="${REPO_DIR:-}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
run()  { if $DRY_RUN; then printf '     would run: %s\n' "$*"; else "$@" || die "failed: $*"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true ;;
    --no-timer)  WITH_TIMER=false ;;
    --uninstall) UNINSTALL=true ;;
    --repo)      REPO_DIR="${2:-}"; shift ;;
    --policy)    POLICY_REL="${2:-}"; shift ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *)           die "unknown flag: $1" ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A bad interval has to fail here, not inside a rendered plist or unit file
# that launchd or systemd then rejects with no reference back to this script.
[[ "$SYNC_INTERVAL_SECS" =~ ^[1-9][0-9]*$ ]] \
  || die "SYNC_INTERVAL_SECS must be a positive integer (seconds), got: ${SYNC_INTERVAL_SECS}"

# ---- platform ---------------------------------------------------------------

case "$(uname -s)" in
  Darwin)
    PLATFORM=macos
    DEST="/Library/Application Support/ClaudeCode/managed-settings.json"
    OWNER_GROUP=wheel
    AGENT_PATH="${HOME}/Library/LaunchAgents/${TIMER_LABEL}.plist"
    ;;
  Linux)
    PLATFORM=linux
    DEST="/etc/claude-code/managed-settings.json"
    OWNER_GROUP=root
    UNIT_DIR="${HOME}/.config/systemd/user"
    ;;
  *) die "unsupported platform: $(uname -s)" ;;
esac

SAFE_LABEL="$(printf '%s' "$TIMER_LABEL" | tr '.' '-')"
SUDOERS_FRAGMENT="/etc/sudoers.d/${SAFE_LABEL}"
APPLY_DIR="/usr/local/lib/${SAFE_LABEL}"
APPLY_SCRIPT="${APPLY_DIR}/apply-policy.sh"
MARKER="${STATE_DIR}/last-installed-sha"
CONFIG="${STATE_DIR}/config"

# ---- uninstall --------------------------------------------------------------

if $UNINSTALL; then
  note "removing the policy at ${DEST}"
  run sudo rm -f "$DEST"
  note "removing the apply script and the sudoers fragment"
  run sudo rm -rf "$APPLY_DIR"
  run sudo rm -f "$SUDOERS_FRAGMENT"
  if [[ $PLATFORM == macos ]]; then
    launchctl bootout "gui/$(id -u)/${TIMER_LABEL}" 2>/dev/null || true
    run rm -f "$AGENT_PATH"
  else
    systemctl --user disable --now "${TIMER_LABEL}.timer" 2>/dev/null || true
    run rm -f "${UNIT_DIR}/${TIMER_LABEL}.service" "${UNIT_DIR}/${TIMER_LABEL}.timer"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  run rm -f "$MARKER" "$CONFIG"
  note "done. Claude Code falls back to user settings on its next start."
  exit 0
fi

# ---- preflight --------------------------------------------------------------

command -v git >/dev/null || die "git is required"

# Discovery is guarded, never blind. Taking the enclosing checkout on trust
# attaches the timer to whatever repository happens to hold these files: drop
# them in a dotfiles tree, or a $HOME that is itself a checkout, and the
# machine runs `git pull` against it every four hours for the rest of its
# life. The policy has to be present before the guess is accepted.
if [[ -z "$REPO_DIR" ]]; then
  guess="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$guess" ]] || die "not in a git checkout. Pass --repo PATH."
  [[ -r "${guess}/${POLICY_REL}" ]] \
    || die "no ${POLICY_REL} in ${guess}. Pass --repo PATH and --policy REL_PATH."
  REPO_DIR="$guess"
fi
REPO_DIR="$(cd "$REPO_DIR" && pwd)" || die "cannot read --repo path"
[[ -d "${REPO_DIR}/.git" ]] || die "${REPO_DIR} is not a git checkout"

# The policy is read out of git, never off disk. See the apply script below.
git -C "$REPO_DIR" cat-file -e "HEAD:${POLICY_REL}" 2>/dev/null \
  || die "${POLICY_REL} is not committed in ${REPO_DIR}. Commit it first."

# A malformed policy is worse than none: Claude Code ignores a file it cannot
# parse, so every machine silently loses the policy with nothing in the UI to
# say why.
if command -v jq >/dev/null; then
  VALIDATOR=(jq -e . )
elif command -v python3 >/dev/null; then
  VALIDATOR=(python3 -c 'import json,sys; json.load(sys.stdin)')
else
  die "no jq and no python3; the policy cannot be validated, so nothing is installed"
fi
git -C "$REPO_DIR" show "HEAD:${POLICY_REL}" | "${VALIDATOR[@]}" >/dev/null 2>&1 \
  || die "HEAD:${POLICY_REL} is not valid JSON"

TREE_REF="${SUBTREE:+HEAD:${SUBTREE}}"
TREE_REF="${TREE_REF:-HEAD^{tree}}"
git -C "$REPO_DIR" rev-parse "$TREE_REF" >/dev/null 2>&1 \
  || die "cannot resolve ${TREE_REF} in ${REPO_DIR}"

note "repo:   ${REPO_DIR}"
note "policy: ${POLICY_REL} (from git, at ${TREE_REF})"
note "dest:   ${DEST}"
note "label:  ${TIMER_LABEL}"
note "sync every ${SYNC_INTERVAL_SECS}s"
[[ "$TIMER_LABEL" == com.example.* ]] && warn "TIMER_LABEL is still the example value; set your own"
$DRY_RUN && note "dry run: nothing below is executed"

# ---- 1. the apply script ----------------------------------------------------
#
# The sudoers rule names this script and nothing else. It takes no arguments,
# so there is no path with a space to word-split and no source path for a
# caller to choose.
#
# It reads the policy out of the git object store rather than off disk, which
# is what closes the hole in the obvious version of this design. A rule that
# runs `install <source> <dest>` as root, where <source> is a path you can
# write, lets you point <source> at a symlink to /etc/shadow: install
# follows it and copies the CONTENT into a root-owned, world-readable file.
# `git show` cannot be pointed outside the repository, and a symlink committed
# to git resolves to its target string, which is not valid JSON and is
# refused below.

read -r -d '' APPLY_BODY <<APPLYEOF || true
#!/usr/bin/env bash
# Installed by ${TIMER_LABEL}. Root-owned; do not edit by hand.
#
# Reads the committed policy out of the git object store and installs it.
# Takes no arguments on purpose: the sudoers rule that runs this is only as
# narrow as this script's own surface.
set -euo pipefail

REPO=$(printf '%q' "$REPO_DIR")
REL=$(printf '%q' "$POLICY_REL")
DEST=$(printf '%q' "$DEST")
GROUP=$(printf '%q' "$OWNER_GROUP")

TMP=\$(mktemp)
trap 'rm -f "\$TMP"' EXIT

git -C "\$REPO" show "HEAD:\$REL" > "\$TMP"

# Validate before anything is replaced. From the user's side, a file Claude
# Code cannot parse looks exactly like having no policy at all.
if command -v jq >/dev/null; then
  jq -e . "\$TMP" >/dev/null
else
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "\$TMP"
fi

mkdir -p "\$(dirname "\$DEST")"
install -m 0644 -o root -g "\$GROUP" "\$TMP" "\$DEST"
APPLYEOF

note "installing the apply script at ${APPLY_SCRIPT}"
if $DRY_RUN; then
  printf '     would install this script:\n'
  printf '%s\n' "$APPLY_BODY" | sed 's/^/       /'
else
  APPLY_TMP="$(mktemp)"
  printf '%s\n' "$APPLY_BODY" > "$APPLY_TMP"
  bash -n "$APPLY_TMP" || { rm -f "$APPLY_TMP"; die "generated apply script is not valid bash"; }
  sudo mkdir -p "$APPLY_DIR" || die "cannot create ${APPLY_DIR}"
  sudo install -m 0755 -o root -g "$OWNER_GROUP" "$APPLY_TMP" "$APPLY_SCRIPT" \
    || { rm -f "$APPLY_TMP"; die "cannot install ${APPLY_SCRIPT}"; }
  rm -f "$APPLY_TMP"
fi

# ---- 2. the sudoers fragment ------------------------------------------------

note "installing the sudoers fragment at ${SUDOERS_FRAGMENT}"
FRAGMENT_TMP="$(mktemp)"
cat > "$FRAGMENT_TMP" <<EOF
# Managed by ${TIMER_LABEL}. Lets the per-user sync timer reinstall the Claude
# Code policy without a password prompt. One command, no arguments.
${USER} ALL=(root) NOPASSWD: ${APPLY_SCRIPT}
EOF

if $DRY_RUN; then
  printf '     would install this fragment:\n'
  sed 's/^/       /' "$FRAGMENT_TMP"
  rm -f "$FRAGMENT_TMP"
else
  # visudo -c first. A syntax error under /etc/sudoers.d breaks every sudo on
  # the machine, including the one you would need to undo it.
  if sudo visudo -c -f "$FRAGMENT_TMP" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g "$OWNER_GROUP" "$FRAGMENT_TMP" "$SUDOERS_FRAGMENT" \
      || { rm -f "$FRAGMENT_TMP"; die "cannot install ${SUDOERS_FRAGMENT}"; }
  else
    rm -f "$FRAGMENT_TMP"
    die "the generated sudoers fragment did not validate, refusing to install it"
  fi
  rm -f "$FRAGMENT_TMP"
fi

# ---- 3. apply it now --------------------------------------------------------

note "installing the policy at ${DEST}"
run sudo "$APPLY_SCRIPT"

# ---- 4. remember how this was installed -------------------------------------
#
# The timer re-invokes this script. An installer that fell back to its own
# defaults would watch the wrong tree forever and write a second sudoers
# fragment under the example label that --uninstall never removes.

note "recording the configuration at ${CONFIG}"
if ! $DRY_RUN; then
  mkdir -p "$STATE_DIR" || die "cannot create ${STATE_DIR}"
  cat > "$CONFIG" <<EOF
REPO_DIR=${REPO_DIR}
POLICY_REL=${POLICY_REL}
SUBTREE=${SUBTREE}
TIMER_LABEL=${TIMER_LABEL}
EOF
else
  printf '     would record: REPO_DIR, POLICY_REL, SUBTREE, TIMER_LABEL\n'
fi

# ---- 5. the timer -----------------------------------------------------------

render() { sed -e "s|__LABEL__|${TIMER_LABEL}|g" -e "s|__USER_HOME__|${HOME}|g" \
               -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" -e "s|__STATE_DIR__|${STATE_DIR}|g" \
               -e "s|__REPO_DIR__|${REPO_DIR}|g" -e "s|__INTERVAL_SECS__|${SYNC_INTERVAL_SECS}|g" "$1"; }

if $WITH_TIMER; then
  if [[ $PLATFORM == macos ]]; then
    note "installing the LaunchAgent at ${AGENT_PATH}"
    if $DRY_RUN; then
      printf '     would write %s and load it with launchctl bootstrap\n' "$AGENT_PATH"
    else
      mkdir -p "$(dirname "$AGENT_PATH")" || die "cannot create the LaunchAgents directory"
      render "${SCRIPT_DIR}/templates/launchd.plist" > "$AGENT_PATH" \
        || die "cannot write ${AGENT_PATH}"
      launchctl bootout "gui/$(id -u)/${TIMER_LABEL}" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$AGENT_PATH" || die "launchctl bootstrap failed"
    fi
  else
    note "installing the systemd user units in ${UNIT_DIR}"
    if $DRY_RUN; then
      printf '     would write %s.{service,timer} and enable the timer\n' "${UNIT_DIR}/${TIMER_LABEL}"
    else
      mkdir -p "$UNIT_DIR" || die "cannot create ${UNIT_DIR}"
      for unit in service timer; do
        render "${SCRIPT_DIR}/templates/systemd.${unit}" > "${UNIT_DIR}/${TIMER_LABEL}.${unit}" \
          || die "cannot write the ${unit} unit"
      done
      systemctl --user daemon-reload || die "systemctl daemon-reload failed"
      systemctl --user enable --now "${TIMER_LABEL}.timer" || die "could not enable the timer"
    fi
    # A user timer only runs while the user has a session, so on a server it
    # never fires unattended until lingering is on.
    if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      warn "lingering is off for ${USER}, so the timer stops when you log out"
      warn "enable it with: sudo loginctl enable-linger ${USER}"
    fi
  fi
fi

# ---- 6. the marker ----------------------------------------------------------
#
# The tree SHA of the watched subtree, written only after everything above
# succeeded. sync.sh compares against this, so a failed attempt leaves it
# alone and the next run retries.

if ! $DRY_RUN; then
  mkdir -p "$STATE_DIR" || die "cannot create ${STATE_DIR}"
  git -C "$REPO_DIR" rev-parse "$TREE_REF" > "$MARKER" || die "cannot write the marker"
fi

note "done."
cat <<EOF

Verify:

  1. The policy is in place and root-owned:
       ls -l "${DEST}"

  2. Claude Code has it. Start a NEW session and run /status; the managed
     policy is listed there. A session already running does not reload it.

  3. The timer is loaded:
EOF
if [[ $PLATFORM == macos ]]; then
  printf '       launchctl print "gui/$(id -u)/%s" | head -5\n\n' "$TIMER_LABEL"
else
  printf '       systemctl --user list-timers %s.timer\n\n' "$TIMER_LABEL"
fi
