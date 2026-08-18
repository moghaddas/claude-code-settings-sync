# claude-code-settings-sync

Deploy a Claude Code managed-settings policy across a team, and keep every
machine current, using a git repository and a timer.

Every documented way to do this assumes you have an MDM. Anthropic's own
examples are written for Jamf and Intune, and the guides that follow them add
Group Policy and Ansible. Startups have none of those, so the policy gets
copied onto laptops by hand, drifts within a month, and nobody can say which
machine is running what.

This does it with what a team already has:

```
policy repo  ->  git pull every 4h  ->  reinstall when the tree moved
```

macOS and Linux. Bash and git, nothing else.

## Read this first

**This is not an enforcement boundary against the person using the machine.**

Managed settings sit above user and project settings and cannot be overridden
from inside Claude Code. That guarantee comes from the file being root-owned.
Unattended updates have to replace a root-owned file with nobody there to type
a password, so there has to be a `NOPASSWD` sudoers rule, and a machine's own
user can always reach whatever that rule can reach.

Here the rule names one root-owned script, with no arguments, that reads the
policy out of the git object store. So the residual power it hands a local
user is exactly this: they can commit a different policy to the repository
their machine tracks, and their machine will install it. No root shell, no
arbitrary file read, no arbitrary write.

That last point is worth spelling out, because the obvious version of this
design gets it wrong. A rule of the form `NOPASSWD: install <source> <dest>`,
where `<source>` is a path in a checkout the user can write, is an arbitrary
root-privileged **read** of any file on the box: replace `<source>` with a
symlink to `/etc/shadow` and `install` follows it and copies the contents into
a root-owned, world-readable file. Reading from git closes that, because
`git show` cannot be pointed outside the repository and a committed symlink
resolves to its target string, which is not valid JSON and is refused.

If your threat model is the engineer at the keyboard rather than drift and
forgetfulness, use an MDM, where the source is not user-writable at all. For
nearly every team the real problem is the second one. Nobody is fighting the
policy; they just have an old copy of it.

## Install

```
git clone <your policy repo>
cd <your policy repo>
./install.sh --dry-run     # read what it will do
./install.sh
```

`--dry-run` changes nothing and prints what each step would do, including the
generated apply script and the exact sudoers fragment. Run it first.

**The policy has to be committed.** It is read out of git, not off disk, which
is what keeps the sudoers rule from being a way to read arbitrary files. An
uncommitted policy is refused with a message saying so.

| Flag | |
|---|---|
| `--dry-run` | Print what would happen, change nothing |
| `--no-timer` | Install the policy only, no scheduled sync |
| `--uninstall` | Remove the policy, the apply script, the sudoers fragment and the timer |
| `--repo PATH` | The policy checkout. Required when the script is not inside it |
| `--policy REL` | Path of the policy within the repository, default `managed-settings.json` |

Configuration through the environment:

| | | |
|---|---|---|
| `TIMER_LABEL` | `com.example.claude-settings-sync` | **Change this.** It names the LaunchAgent, the systemd units and the sudoers fragment |
| `SUBTREE` | unset | A path to watch instead of the whole repository, so unrelated commits do not trigger a reinstall |
| `REPO_DIR` | the enclosing checkout | The repository to pull. Discovery is refused unless that repository actually holds the policy |
| `STATE_DIR` | `~/.config/claude-settings-sync` | Marker, config and log |

Whatever you pass is recorded in `$STATE_DIR/config` and read back by the
timer, so the scheduled run uses the same label and watches the same tree as
the install did. Without that the timer would fall back to the defaults,
reinstall every four hours for ever, and write a second sudoers fragment under
the example label that `--uninstall` would never remove.

## How the sync decides

`sync.sh` runs on the timer, pulls `--ff-only`, and compares the current tree
SHA against **the SHA that was last successfully installed**, not against the
previous `HEAD`.

That difference is the whole design. Comparing `HEAD` before and after the pull
is blind to a run that pulled cleanly and then failed to install: the next run
sees no movement, does nothing, and the machine sits on a stale policy for ever
with nothing in the log to say so. Comparing against what was installed
self-heals, because a failed install leaves the marker where it was and the
next run tries again.

Two ways a run gives up quietly rather than doing damage:

**Git cannot authenticate.** An SSH key with a passphrase, or HTTPS with no
cached credential, has no terminal to prompt on. The pull fails, the run keeps
the tree it already has, and it logs that. Use a deploy key with no passphrase,
or a credential helper.

**The sudoers fragment is missing.** The reinstall cannot write a root-owned
file, the marker is not advanced, and the next run retries.

Both land in `~/.config/claude-settings-sync/sync.log`, which is trimmed to the
last 500 lines once it passes a megabyte.

## Schedule

Four hours, on both platforms.

On macOS a LaunchAgent with `StartInterval`. If the laptop is asleep when the
interval elapses, launchd runs the job on the next wake. `RunAtLoad` is off, so
logging in does not trigger an install on top of the schedule.

On Linux a systemd user timer with `Persistent=true`, which is the same idea: a
machine that was off when the timer was due runs it shortly after boot rather
than waiting another full interval.

**A systemd user timer only runs while the user has a session.** On a server
that means it never fires unattended. The installer warns when lingering is
off; turn it on with `sudo loginctl enable-linger <user>`.

## Where the policy lands

| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux | `/etc/claude-code/managed-settings.json` |

Both root-owned, mode 644.

## Writing the policy

`managed-settings.json` in this repository is a starting point, not a
recommendation. Replace it.

Two things worth knowing before you fill it in:

**Invalid JSON is worse than no policy.** Claude Code ignores a file it cannot
parse, so every machine silently loses the policy with nothing visible in the
UI to explain it. Both the installer and the apply script validate before they
replace anything, and refuse. Validation needs `jq` or `python3`; with neither
present the install stops rather than proceeding unchecked.

**A hook defined in the policy should point at a root-owned script.** If it
points inside a user's home directory, the guarantee is only as strong as the
permissions on that file, and you have written a policy that asks to be
bypassed.

## Verify

```
ls -l /etc/claude-code/managed-settings.json     # or the macOS path
```

Then start a **new** Claude Code session and run `/status`, which lists the
managed policy. A session already running does not reload it, which is the
usual reason a correct install looks like it did nothing.

The timer:

```
launchctl print "gui/$(id -u)/<label>" | head -5      # macOS
systemctl --user list-timers <label>.timer           # Linux
```

## Uninstall

```
./install.sh --uninstall
```

Removes the policy, the sudoers fragment, the timer and the marker. Claude Code
falls back to user settings on its next start.

## License

MIT. See [LICENSE](LICENSE).
