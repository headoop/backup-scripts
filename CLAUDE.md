# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Personal backup scripts (bash) for an Arch Linux system, plus systemd units that schedule them. Local snapshots go to an internal drive via rsnapshot; an offline copy goes to a LUKS-encrypted USB drive via rsync. There is no build step and no test suite — the Makefile only installs.

## Commands

```sh
sudo make install      # scripts -> /usr/local/bin, rsync-excludes.txt -> /usr/local/share, units -> /etc/systemd/system
sudo make uninstall    # removes all three; prints systemctl cleanup hints
make -n install        # dry-run to check Makefile changes
```

`PREFIX` overrides `/usr/local` for the scripts and the share directory; the unit directory is fixed.

Checking changes (no test suite exists):

- `bash -n <script>` and `shellcheck <script>` for the scripts.
- `systemd-analyze verify <unit>` for unit files.
- `backup-daily.sh -t` / `backup-weekly.sh -t` are real dry-run modes (rsnapshot test mode, needs root); `-v` is verbose.
- After changing installed units: `sudo make install && sudo systemctl daemon-reload`. The repo is the source of truth; the live copies under `/etc/systemd/system` and `/usr/local/bin` are overwritten on install.

## Architecture

`backup-daily.sh` and `backup-weekly.sh` are deliberately parallel implementations, not shared code. Both follow the same internal layout (Configuration → Global State → Helpers → Cleanup on Exit → Steps → Main Script Logic) and the same conventions:

- Root-only, single instance via `flock` on fd 9 (lock released automatically on any exit).
- The backup drive is found by filesystem UUID and mounted on `/mnt/backup` only if neither device nor mountpoint is busy; a `cleanup` EXIT trap unmounts it and writes a success/failure line to the journal (`logger -t backup-daily|backup-weekly`).
- Quiet on success: normal runs print nothing; output signals a problem. Keep new code silent unless `verbose` is set (`vlog`).
- rsnapshot exit code 2 (warnings) is reported to stderr but does not fail the run; only rc 1 is fatal.
- Daily runs `rsnapshot beta` (the actual rsync transfer) and additionally saves pacman package lists to `/var/local/backup-daily`; weekly runs `rsnapshot gamma`, which only rotates the oldest beta snapshot — a change to one script's shared structure usually belongs in the other too.

Scheduling/notification chain: `backup-*.timer` → `backup-*.service` → on failure `OnFailure=failure-mail@%n.service` → `systemd-failure-mail.sh` mails `systemctl status` of the failed unit to root via sendmail (delivered through the local Postfix root alias). Timer `Description=` lines state the run time and must be kept in sync with `OnCalendar`.

`backup-encrypted-usb.sh` is interactive (LUKS passphrase prompt): it rsyncs the newest snapshot into an `incomplete` staging dir on a whitelisted USB drive (`ALLOWED_USB_UUIDS` array in the script) and rotates `current` → `previous_1` → … → `previous_N` only after a successful sync. `N` comes from `DEFAULT_KEEP_PREVIOUS` or a per-UUID entry in the `KEEP_PREVIOUS` array, is validated before the passphrase prompt (a malformed entry is fatal, a missing one falls back to the default), and `rotate_backups` deletes any `previous_N` above it — so lowering a value discards backups. `pacman-list-changed-files.sh` is a standalone helper used by the daily script.

`rsync-excludes.txt` is data, not code: exclude patterns installed to `$(PREFIX)/share`, meant to be referenced from `/etc/rsnapshot.conf`'s `exclude_file` parameter. No script in this repo reads it directly.

## Conventions

- Commit messages use a `<type>:` prefix (`feat:`, `fix:`, `docs:`, `add:`); work happens on the `develop` branch, `main` is the default.
- New scripts follow the existing pattern: author header comment, `set -u`, explicit `PATH=/usr/bin:/usr/sbin`, config variables at the top, a `programs=()` array checked by `check_requirements`, `die`/`vlog` helpers.
- README.md documents every script and the timer schedule — update it when behaviour, options, or schedules change.
