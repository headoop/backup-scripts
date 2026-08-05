#!/usr/bin/env bash

# Daily backup: saves pacman package lists to $pac_backup and runs
# rsnapshot onto the backup drive. Designed to run as root from cron:
# quiet on success, so cron only sends mail when something goes wrong.
# rsnapshot transfer details go to the logfile set in /etc/rsnapshot.conf.

set -u

PATH=/usr/bin:/usr/sbin
cd /tmp || exit 1 # don't stay in a mount point, eventually

# --- Configuration ---

# pac_backup="/root/backup"                                    # where to store our pacman package lists
pac_backup="/var/local/backup-daily"                         # where to store our pacman package lists
paclistchanged="/usr/local/bin/pacman-list-changed-files.sh" # list changed files in /etc
target_uuid="b6fabf8b-ccdd-4f52-b032-b5cbc6ce6a76"           # backup target device
target="/dev/disk/by-uuid/$target_uuid"
tdir="/mnt/backup" # mountpoint for backup target device
lock_file="/var/lock/backup-daily.lock"

# external programs we need (test, cd, echo, ... are bash builtins)
programs=(mount umount mountpoint findmnt ionice nice rsnapshot pacman
  comm sort expac sync ls flock logger)

# --- Global State ---

verbose=true     # -v: report progress on stdout
dryrun=false     # -t: rsnapshot test mode (only show shell commands)
target_mounted=0 # 1 once this script has mounted $target on $tdir
mount_opts=()    # gets -v for mount/umount when verbose

# --- Helpers ---

usage() {
  echo "usage: ${0##*/} [-v] [-t]" >&2
  echo "  -v  verbose: report progress on stdout" >&2
  echo "  -t  test run: rsnapshot only shows what it would do (implies -v)" >&2
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# print only when running with -v
vlog() {
  [[ $verbose == true ]] && echo "$@"
  return 0
}

# --- Cleanup on Exit ---

# Undoes only what the script itself did and leaves a one-line trace in
# the journal. Runs on every exit; keeps the original exit code, except
# that a failed umount turns a successful run into a failed one.
cleanup() {
  local rc=$?
  if ((target_mounted)); then
    sync
    if umount "${mount_opts[@]}" "$tdir"; then
      vlog "$tdir unmounted"
    else
      echo "ERROR: failed to unmount $tdir - please unmount manually" >&2
      ((rc == 0)) && rc=1
    fi
  fi
  if [[ $dryrun == false ]]; then
    if ((rc == 0)); then
      logger -t backup-daily "backup completed successfully"
    else
      logger -t backup-daily "backup FAILED with exit code $rc"
    fi
  fi
  exit "$rc"
}

# --- Steps ---

check_requirements() {
  local p
  for p in "${programs[@]}"; do
    command -v "$p" >/dev/null || die "required program '$p' not found in PATH ($PATH)"
  done
  [[ -d $pac_backup ]] || die "$pac_backup is not a directory"
  [[ -x $paclistchanged ]] || die "$paclistchanged is not executable"
}

# Mount the backup target, but only if neither the device nor the
# mountpoint is in use already.
mount_target() {
  [[ -b $target ]] || die "backup device $target not found (drive not connected?)"
  [[ -d $tdir ]] || die "mountpoint $tdir is not a directory"
  findmnt -n "UUID=$target_uuid" >/dev/null && die "backup device $target is already mounted. Aborted"
  mountpoint -q "$tdir" && die "$tdir is already mounted. Aborted"
  mount "${mount_opts[@]}" -t ext4 "$target" "$tdir" || die "failed to mount $target on $tdir"
  target_mounted=1
}

# run the given command and save its output as $pac_backup/$1
save_list() {
  local file="$pac_backup/$1"
  shift
  "$@" >"$file" || die "writing $file failed"
  [[ $verbose == true ]] && ls -l "$file"
  return 0
}

# explicitly installed packages found in the sync database
list_native() { pacman -Qqen; }
# explicitly installed packages not in the sync database (e.g. from the AUR)
list_foreign() { pacman -Qqem; }
# explicitly installed packages without those pulled in by the base meta package
list_not_base() { comm -23 <(pacman -Qqe | sort) <(expac -l '\n' '%E' base | sort); }
# same, without those pulled in by the base-devel meta package
list_not_base_devel() { comm -23 <(pacman -Qqe | sort) <(expac -l '\n' '%E' base-devel | sort); }
# packages belonging to a group
list_in_groups() { pacman -Qg; }

save_package_lists() {
  save_list packages-native.list list_native
  save_list packages-foreign.list list_foreign
  save_list packages-not-base.list list_not_base
  save_list packages-not-base-devel.list list_not_base_devel
  save_list packages-in-groups.list list_in_groups
  # files changed after package install (errors go to stderr, not into the list)
  save_list packages-with-changed-files.list "$paclistchanged"
}

# rsnapshot exit codes: 0 = ok, 1 = fatal error, 2 = finished with warnings.
# Warnings only go to stderr (cron mails them) but don't fail the run.
run_rsnapshot() {
  local opts=() rc=0
  [[ $verbose == true ]] && opts+=(-v)
  if [[ $dryrun == true ]]; then
    opts+=(-t)
    echo "rsnapshot test mode: only showing what would be done"
  fi
  vlog "rsnapshot start"
  ionice -c3 nice -n 19 rsnapshot "${opts[@]}" beta || rc=$?
  if ((rc == 2)); then
    echo "WARNING: rsnapshot finished with warnings (exit code $rc)" >&2
  elif ((rc != 0)); then
    die "rsnapshot failed with exit code $rc"
  fi
  vlog "rsnapshot finished"
}

# --- Main Script Logic ---

while getopts vt opt; do
  case $opt in
  v) verbose=true ;;
  t)
    # a test run that hides its commands would be useless
    dryrun=true
    verbose=true
    ;;
  *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || usage

[[ $EUID -eq 0 ]] || die "this script must be run as root"

check_requirements

[[ $verbose == true ]] && mount_opts+=(-v)

# one instance at a time; the lock is tied to the file descriptor and
# released automatically when the script exits, even on kill -9
exec 9>"$lock_file" || die "cannot open lock file $lock_file"
flock -n 9 || die "another instance is already running (lock: $lock_file)"

trap cleanup EXIT

mount_target
save_package_lists
run_rsnapshot

vlog "backup finished"
