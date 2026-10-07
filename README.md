# shokz-auto-fill

When a Shokz player, or any USB-storage player, is plugged in, this downloads a fresh
random set of songs from [Navidrome](https://www.navidrome.org/) onto it, keeps
the two newest lists, and ejects the device.

The fill itself is a shell script. What makes it more than `cp` and a plist is a macOS
rule that stops a background job writing to a removable volume, and the permission the
job needs first. That is documented in full further down.

There is also `docs.html`, a self-contained HTML version of this documentation.
No external assets, no network and no build step; open it directly in a browser.

## Requirements

- macOS
- [Homebrew](https://brew.sh), used to install `bash` and, if missing, `jq`
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

It then requests removable-volume permission, which macOS shows as a dialog. Click
Allow. See below for why this step exists.

## Updating an existing install

Just run `install.command` again. It detects the existing installation, shows what
is configured, and asks what to change:

```
An existing installation was found.
  config : ~/.config/shokz-auto-fill/config
  script : present
  agent  : loaded  (local.shokz-auto-fill)

Current settings:
  device     : MY_PLAYER
  url(s)     : http://navidrome.local:4533 https://music.example.com
  login      : youruser   password: stored
  songs/fill : 50

What would you like to update?  (one number, several separated by spaces, or 'a')
  1) song count          (now 50)
  2) Navidrome URL(s)
  3) device              (now MY_PLAYER)
  4) login               (now youruser)
  5) reinstall script + LaunchAgent, and re-request volume permission
  a) all of the above
  q) quit without changing anything
```

Enter one number, or several such as `1 3`, or `a` for everything, or `q` to leave
things alone.

Because the script and the agent read the config at run time, a settings change takes
effect on the very next fill with no reload. The server is only checked again if you
changed the URL or the login.

Choose **5** when you want to reinstall the script and the agent themselves, for
example to re-request the removable-volume permission after a Homebrew `bash`
upgrade, which the caveat further down covers. On a first run the installer does
everything automatically.

## Uninstall

Double-click **`uninstall.command`**. It unloads and removes the LaunchAgent and
the installed script, and asks separately before deleting the config, which holds
the password). Music already on the device is never touched.

## What gets installed

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/ShokzAutoFill/bin/auto_fill_shokz.sh` | the fill script |
| `~/.config/shokz-auto-fill/config` | device, URLs, credentials (**mode 600**) |
| `~/Library/LaunchAgents/local.shokz-auto-fill.plist` | runs the script when `/Volumes` changes |
| `/tmp/shokz-auto-fill.log` | the job's own log, trimmed to the last 1000 lines |

Run it as soon as the device is mounted:

```sh
launchctl kickstart -k gui/$(id -u)/local.shokz-auto-fill
tail -f /tmp/shokz-auto-fill.log
```

## Behaviour worth knowing

- On success the device is ejected with `diskutil eject`. Unplug it and listen.
- **Only the two newest lists are kept**; older numbered folders are deleted.
  Set `SONG_COUNT` in the config to change the size of each list.
- A run is guarded by a lock file at `/tmp/shokz-auto-fill.state`, so overlapping
  `/Volumes` events cannot fill twice. If a run is killed mid-way the lock is
  released on exit; if one ever sticks, delete that file and replug.
- If nothing can be downloaded, the script **aborts without deleting anything**,
  leaving the existing music in place.

---

## The macOS trap this works around

A background job cannot write to a removable volume on macOS without a permission the
job has to be able to ask for. This section is the reference for that.

**Symptom.** The job fires, finds the device, reaches Navidrome, fetches song IDs, then
every `mkdir` on the device fails:

```
mkdir: /Volumes/MY_PLAYER/auto-list/1: Operation not permitted
```

**Cause.** macOS gates removable volumes behind the TCC service
`kTCCServiceSystemPolicyRemovableVolumes`. When a LaunchAgent runs `/bin/bash`,
bash *is* the "responsible process", and `/bin/bash` is an Apple **platform binary**:

```sh
$ codesign -dvvv /bin/bash | grep Platform
Platform identifier=26
```

macOS will not grant TCC permissions to a platform binary, and cannot even ask:

```
Platform binary prompting is 'Deny' because: is Platform Binary
```

The denial is permanent and silent. An interactive shell does not hit it, because then
the responsible process is the *parent app*, such as Terminal, rather than bash. That is
why the same command works when you run it by hand.

**Fix.** Run the job under a shell that is *not* a platform binary, so macOS will
prompt and then grant:

```
AUTHREQ_PROMPTING: service=kTCCServiceSystemPolicyRemovableVolumes
                   subject=Sub:{/opt/homebrew/Cellar/bash/5.3.20/bin/bash}
...
Publishing <TCCDEvent: type=Create, service=kTCCServiceSystemPolicyRemovableVolumes,
            identifier_type=Path, identifier=/opt/homebrew/Cellar/bash/5.3.20/bin/bash>
```

Hence `brew install bash` and the shebang `#!/opt/homebrew/bin/bash`. Do not point
the agent at `/bin/bash`.

### The catch: the grant is keyed by path

For an unsigned binary macOS keys the grant by **path**, and it resolves symlinks.
The grant therefore binds to a versioned Homebrew path, so `brew upgrade bash`
moves it, the grant is lost, and the job fails as before.

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
- If you are migrating from an older setup that kept the password in plain text inside
  a script, and that script was committed to git, treat the password as exposed.
  Rotate it on the Navidrome server, then re-run the installer to store the new one
  here.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Nothing happens on plug-in | `launchctl list \| grep shokz` says whether the agent is loaded. Check the volume name in the config too. |
| `Operation not permitted` in the log | The removable-volume grant is missing. Re-run `install.command` and allow the dialog. |
| Reaches the server but downloads 0 files | Check `ND_USER` / `ND_PASS`; the log prints the Subsonic status. |
| Fills, then leaves a partial folder | A run was interrupted. Delete the half-written numbered folder on the device. |
| `launchctl list <label>` says "could not find service" | The label is `local.shokz-auto-fill`. |
