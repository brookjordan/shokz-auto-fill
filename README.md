# shokz-auto-fill

When a Shokz (or any USB-storage) player is plugged in, this downloads a fresh
random set of songs from [Navidrome](https://www.navidrome.org/) onto it, keeps
the two newest lists, and ejects the device.

It exists because of the problem it solves and the problem it works around: the
fill itself is a shell script, and a **macOS privacy rule silently prevents a
background job from writing to a removable volume** unless you know why. That
rule and its fix are documented below, because it is the whole reason this
installer is more than `cp` and a plist.

> **Read this in a browser:** `docs.html` is a self-contained HTML version of this
> documentation — no external assets, no network, no build step. Open it directly.

## Requirements

- macOS
- [Homebrew](https://brew.sh) (used to install `bash` and, if missing, `jq`)
- A reachable Navidrome server and an account on it
- The player formatted as FAT32/exFAT and mounting under `/Volumes`

## Install

Double-click **`install.command`** (or run `./install.command`).

It asks for:

| Prompt | Notes |
| --- | --- |
| **Device** | The volume name, i.e. the folder under `/Volumes`. Currently mounted volumes are listed with numbers, so you can pick one. |
| **Navidrome URL(s)** | One or more, space- or comma-separated, tried in order until one answers. Put a LAN address first for speed, then a remote one. |
| **Username / password** | Password input is not echoed. If an older install is found with a hard-coded password, it offers to reuse it. |
| **Songs per fill** | Default 50. |

It then **verifies the URL and login against the server before installing**, and
reports each URL as reachable + authenticated, reachable but rejected, or
unreachable. Nothing is written unless you continue.

Finally it requests removable-volume permission — **macOS shows a dialog; click
Allow.** See below for why this step exists.

## Updating an existing install

Just run `install.command` again. It detects the existing installation, shows what
is configured now, and asks what to change:

```
An existing installation was found.
  config : ~/.config/shokz-auto-fill/config
  script : present
  agent  : loaded  (com.brookjordan.shokz-auto-fill)

Current settings:
  device     : SWIM PRO
  url(s)     : http://navidrome.local:4533 https://music.example.com
  login      : brookjordan   password: stored
  songs/fill : 50

What would you like to update?  (one number, several separated by spaces, or 'a')
  1) song count          (now 50)
  2) Navidrome URL(s)
  3) device              (now SWIM PRO)
  4) login               (now brookjordan)
  5) reinstall script + LaunchAgent, and re-request volume permission
  a) all of the above
  q) quit without changing anything
```

Enter one number, several (e.g. `1 3`), `a` for everything, or `q` to leave
things alone.

Because the script and the agent read the config at run time, changing a
**setting** takes effect on the very next fill — no reload, and no server check
unless you changed the URL or the login.

Choose **5** when you want to reinstall the script and the agent themselves, for
example to re-request the removable-volume permission after a Homebrew `bash`
upgrade (see the caveat further down). On a first run the installer does
everything automatically.

## Uninstall

Double-click **`uninstall.command`**. It unloads and removes the LaunchAgent and
the installed script, and asks separately before deleting the config (which holds
the password). Music already on the device is never touched.

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/ShokzAutoFill/bin/auto_fill_shokz.sh` | the fill script |
| `~/.config/shokz-auto-fill/config` | device, URLs, credentials (**mode 600**) |
| `~/Library/LaunchAgents/com.brookjordan.shokz-auto-fill.plist` | runs the script when `/Volumes` changes |
| `/tmp/shokz-auto-fill.log` | the job's own log (trimmed to the last 1000 lines) |

Run it as soon as the device is mounted:

```sh
launchctl kickstart -k gui/$(id -u)/com.brookjordan.shokz-auto-fill
tail -f /tmp/shokz-auto-fill.log
```

## Behaviour worth knowing

- **On success the device is ejected** (`diskutil eject`). That is intentional —
  unplug and listen.
- **Only the two newest lists are kept**; older numbered folders are deleted.
  Set `SONG_COUNT` in the config to change the size of each list.
- A run is guarded by a lock file (`/tmp/shokz-auto-fill.state`) so overlapping
  `/Volumes` events cannot fill twice. If a run is killed mid-way the lock is
  released on exit; if one ever sticks, delete that file and replug.
- If nothing can be downloaded, the script **aborts without deleting anything**,
  leaving the existing music in place.

---

## The macOS trap this works around

This is the part worth reading if you ever "simplify" the setup and it stops
working with no error.

**Symptom.** The job fires, finds the device, reaches Navidrome, fetches song
IDs — then every `mkdir` on the device fails:

```
mkdir: /Volumes/SWIM PRO/auto-list/1: Operation not permitted
```

**Cause.** macOS gates removable volumes behind the TCC service
`kTCCServiceSystemPolicyRemovableVolumes`. When a LaunchAgent runs `/bin/bash`,
bash *is* the "responsible process" — and `/bin/bash` is an Apple **platform
binary**:

```sh
$ codesign -dvvv /bin/bash | grep Platform
Platform identifier=26
```

macOS will not grant TCC permissions to a platform binary, and cannot even ask:

```
Platform binary prompting is 'Deny' because: is Platform Binary
```

So the denial is permanent and silent. An interactive shell does not hit this,
because then the responsible process is the *parent app* (e.g. Terminal), not
bash — which is why it "works when I run it by hand".

**Fix.** Run the job under a shell that is *not* a platform binary, so macOS will
prompt and then grant:

```
AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyRemovableVolumes
                   subject=Sub:{/opt/homebrew/Cellar/bash/5.3.20/bin/bash}
...
Publishing <TCCDEvent: type=Create, service=kTCCServiceSystemPolicyRemovableVolumes,
            identifier_type=Path, identifier=/opt/homebrew/Cellar/bash/5.3.20/bin/bash>
```

Hence `brew install bash` and the shebang `#!/opt/homebrew/bin/bash`. **Do not
change it back to `/bin/bash`.**

### The catch: the grant is keyed by path

For an unsigned binary macOS keys the grant by **path**, and it resolves
symlinks. So the grant binds to a versioned Cellar path like
`/opt/homebrew/Cellar/bash/5.3.20/bin/bash`. A `brew upgrade bash` moves that
path and **the grant is silently lost** — the job then fails exactly as before.

Two ways to handle it:

1. **Re-run `install.command` after upgrading bash.** It repeats the permission
   probe, so the prompt comes back and the grant is re-created. (Default.)
2. **Pin bash** so its path never moves: `brew pin bash`. Durable, but you stop
   receiving bash updates.

If the job ever stops filling for no visible reason, check the log for
`Operation not permitted` and re-run the installer.

## Security

- The Navidrome password lives in `~/.config/shokz-auto-fill/config`, mode 600.
  It is **not** in this repo, and `config/config` is git-ignored as a backstop.
- The script builds a Subsonic token as `md5(password + salt)` per request rather
  than sending the password, and never prints it.
- The password it replaces was previously stored **in plain text inside
  `~/.bin/scripts/auto_fill_shokz.sh`**. That copy still exists if you have not
  removed it — and because that file was committed to a git repository, **the
  password should be considered exposed and rotated** on the Navidrome server.
  Once rotated, update this config (re-run the installer) and delete the old line
  from that script.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Nothing happens on plug-in | `launchctl list \| grep shokz` — is the agent loaded? Is the volume name exactly right in the config? |
| `Operation not permitted` in the log | The removable-volume grant is missing. Re-run `install.command` and allow the dialog. |
| Reaches the server but downloads 0 files | Check `ND_USER` / `ND_PASS`; the log prints the Subsonic status. |
| Fills, then leaves a partial folder | A run was interrupted. Delete the half-written numbered folder on the device. |
| `launchctl list <label>` says "could not find service" | The label is `com.brookjordan.shokz-auto-fill`. Older installs used `com.n8n.swimpro` for a plist named `io.shokz.auto-fill.plist`; this installer migrates that. |
