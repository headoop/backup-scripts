# backup-scripts

Personal backup scripts for an Arch Linux system. Local snapshots are
made with [rsnapshot](https://rsnapshot.org/) onto an internal backup
drive; an additional offline copy goes to a LUKS-encrypted external USB
drive via rsync.

All scripts must be run as root.

## Installation

```sh
sudo make install
```

Installs all scripts to `/usr/local/bin`, `rsync-excludes.txt` to
`/usr/local/share` (override both with `PREFIX`, e.g.
`make install PREFIX=/opt`) and the systemd units for the daily and
weekly backups to `/etc/systemd/system`. Afterwards it prints the
`systemctl` commands needed to activate the timers:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now backup-daily.timer
sudo systemctl enable --now backup-weekly.timer
```

Remove everything again with `sudo make uninstall`; it prints the
matching `systemctl` commands to disable the timers.

## Scheduling

The systemd timers replace root crontab entries:

- `backup-daily.timer` runs `backup-daily.sh` every day at 05:52.
- `backup-weekly.timer` runs `backup-weekly.sh` on Sunday at 05:37.

Check the next scheduled runs with `systemctl list-timers 'backup-*'`.

If a backup service fails, `OnFailure=` triggers
`failure-mail@.service`, which mails the unit status to root (delivered
through the local Postfix setup) — the same behaviour the old crontab
entries provided via cron's failure mail.

## Scripts

### backup-daily.sh

Daily local backup, run automatically via `backup-daily.timer`.

What it does, in order:

1. Takes a lock (`/var/lock/backup-daily.lock`) so only one instance
   runs at a time.
2. Mounts the backup drive (found by filesystem UUID) on `/mnt/backup`,
   but only if neither the device nor the mountpoint is already in use.
3. Saves several pacman package lists to `/var/local/backup-daily` (explicitly
   installed native and foreign packages, packages not in `base`/`base-devel`,
   package groups) and a list of packages with modified config files
   (via `pacman-list-changed-files.sh`), so the system can
   be reinstalled from the backup.
4. Runs `rsnapshot beta` with lowered CPU and I/O priority. The `beta`
   interval does the actual rsync transfer; details go to the logfile
   configured in `/etc/rsnapshot.conf`.
5. Unmounts the drive again (also on errors, via an exit trap) and
   writes a success/failure line to the journal (`logger -t
backup-daily`).

The script is quiet on success; if it fails, the service's
`OnFailure=` hook sends a mail to root (see Scheduling).

```sh
backup-daily.sh        # normal run (as used by the systemd service)
backup-daily.sh -v     # verbose: report progress on stdout
backup-daily.sh -t     # test run: rsnapshot only shows what it would do
```

### backup-weekly.sh

Weekly counterpart of `backup-daily.sh`, run automatically via
`backup-weekly.timer`; same structure and options.
It runs `rsnapshot gamma`, which rotates the oldest `beta` snapshot
into the `gamma` set — no new data is transferred. It does not save
package lists; that is the daily script's job. Uses its own lock file
(`/var/lock/backup-weekly.lock`) and journal tag (`backup-weekly`).

```sh
backup-weekly.sh       # normal run (as used by the systemd service)
backup-weekly.sh -v    # verbose
backup-weekly.sh -t    # test run
```

### backup-encrypted-usb.sh

Interactive offline backup to a LUKS-encrypted external USB drive.
Run it manually with the drive connected; `cryptsetup` prompts for the
LUKS password. Output is logged to `/var/log/punk_backup.log`.

What it does, in order:

1. Takes a lock (`/var/lock/punk_backup.lock`).
2. Mounts the internal backup drive **read-only** on `/mnt/backup`; the
   rsync source is the newest rsnapshot snapshot
   (`/mnt/backup/rsnapshot_backup/beta.0`).
3. Searches for the first connected USB drive whose UUID is on the
   whitelist in the script (`ALLOWED_USB_UUIDS`), opens it with
   `cryptsetup luksOpen` and mounts it on a temporary mountpoint.
4. Rsyncs into a staging directory `punk_backups/incomplete` on the USB
   drive, hardlinking files that are unchanged since the last backup
   (`--link-dest`) to save space. The existing backups stay untouched
   until the sync succeeds; a stale `incomplete` from an aborted run is
   reused and fixed up.
5. Only after a successful sync rotates the backups:
   `current` → `previous_1` → `previous_2` (the oldest is deleted),
   then promotes `incomplete` to `current`. The drive therefore holds
   the three most recent backups.
6. Cleanup on exit undoes only what the script itself did: unmounts the
   USB drive, closes the LUKS device, unmounts the source.

```sh
backup-encrypted-usb.sh    # no options; asks for the LUKS password
```

To add a new target drive, append its filesystem UUID (see
`blkid /dev/sdX1`) to the `ALLOWED_USB_UUIDS` array in the script.

### pacman-list-changed-files.sh

Helper used by `backup-daily.sh`, also useful on its own. Lists
installed packages whose backup files (usually configs in `/etc`) were
modified after installation, by comparing the current md5 checksums
against the `%BACKUP%` sections of the local pacman database. Deleted
files are marked with `(missing)`.

```sh
sudo pacman-list-changed-files.sh
```

Output format: `<package> <file>` — one line per modified file.

### systemd-failure-mail.sh

Helper for the `OnFailure=` hook of the backup services. Called by the
template unit `failure-mail@.service` with the failed unit's name and
mails the output of `systemctl status` for that unit to root via
`sendmail`.

```sh
systemd-failure-mail.sh <unit>    # normally invoked by systemd only
```

### rsync-excludes.txt

Exclude patterns (rsync exclude-file syntax) for caches, VCS-ignorable
build artifacts and other data that don't belong in the backup — meant
to be referenced from `/etc/rsnapshot.conf`'s `exclude_file` parameter
as `/usr/local/share/rsync-excludes.txt`. Not read by any script in
this repo directly.

## History

This repo merges these former separate repos into one:

- backup-daily.git
- backup-to-devmem.git
- backup-usb-drive-crypt.git
- backup-weekly.git

Copied `rsync-exclude.txt` by hand from backup-rsync-exclude.git

`backup-encrypted-usb.sh` was added new.
