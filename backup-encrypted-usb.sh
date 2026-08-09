#!/bin/bash

# ==============================================================================
# Bash Script for Incremental Backups to a LUKS Encrypted USB Drive using Rsync
# (Designed to be run as root, without sudo)
# ==============================================================================

# This script performs incremental backups of a specified source directory
# to a LUKS-encrypted USB hard drive from a whitelist of allowed UUIDs.
# It mounts the source read-only, opens the LUKS device (cryptsetup asks for
# the password), mounts the drive, syncs into a staging directory and only
# rotates the existing backups after rsync finished successfully. Cleanup on
# exit only undoes what the script itself did.

set -u

# --- Configuration ---

# Log file for script output.
LOG_FILE="/var/log/punk_backup.log"

# Lock file to prevent multiple instances of the script running concurrently.
LOCK_FILE="/var/lock/punk_backup.lock"

# Source partition (by UUID) and its read-only mount point.
SOURCE_UUID="b6fabf8b-ccdd-4f52-b032-b5cbc6ce6a76"
SOURCE_PARTITION="/dev/disk/by-uuid/$SOURCE_UUID"
SOURCE_MOUNT_POINT="/mnt/backup"

# The directory to back up. Deliberately no trailing slash in the rsync call,
# so the directory itself is created inside the target (e.g. current/beta.0/).
RSYNC_SOURCE_DIR="$SOURCE_MOUNT_POINT/rsnapshot_backup/beta.0"

# Array of allowed target USB drive UUIDs.
# You can find the UUID of a partition using the 'blkid' command (e.g., blkid /dev/sdb1).
# The script uses the first of these drives that is connected.
declare -a ALLOWED_USB_UUIDS=(
  "e17a2c85-3453-403e-8ece-b5855116d3f6" # WD My Passport 259F 1004 (WD MY Passport Ultra 1.0 TB, white)
  "79f91189-9af5-4d58-bbbf-83a0578171e5" # WD My Passport 0827 1012 (WD My Passport Ultra 1.0 TB, blue)
  "2913b424-8f0b-4cc8-bf52-2c2678e84d45" # WD Elements 25A2 (WD Elements 1.0 TB, black)
  "e528486f-0d3a-49ba-9eeb-7310081ddeb7" # PSSD T9 (Samsung 2 TB external SSD)
  "4c5be60c-767e-46dc-8ca3-8fe4b4543c5d" # WD Elements 1.5 TB, black
  # Add more UUIDs as needed
)

# Base directory on the USB drive where backups will be stored.
USB_BACKUP_BASE_DIR="punk_backups"

# --- Global State ---

TARGET_UUID=""        # UUID of the connected allowed USB drive
TARGET_DEVICE_PATH="" # Device path of the connected allowed USB drive
LUKS_MAPPED_NAME=""   # Name of the opened LUKS device, empty if not opened
TEMP_MOUNT_POINT=""   # Temporary mount point for the USB drive
SOURCE_MOUNTED=0      # 1 if this script mounted SOURCE_MOUNT_POINT
USB_MOUNTED=0         # 1 if this script mounted the USB drive

# Backup directories on the USB drive, set by prepare_target_dirs().
TARGET_BASE_DIR=""
CURRENT_BACKUP=""
PREVIOUS_1=""
PREVIOUS_2=""
INCOMPLETE_BACKUP=""

# --- Logging ---

# Logs messages to stdout and the LOG_FILE with a timestamp.
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Logs error messages to stderr and the LOG_FILE.
log_error() {
  log "ERROR: $1" >&2
}

# --- Cleanup on Exit ---

# Undoes only what the script actually did, in reverse order of setup.
cleanup() {
  log "Performing cleanup tasks."

  if [ "$USB_MOUNTED" -eq 1 ]; then
    if umount "$TEMP_MOUNT_POINT"; then
      log "'$TEMP_MOUNT_POINT' unmounted successfully."
    else
      log_error "Failed to unmount '$TEMP_MOUNT_POINT'. Please unmount manually."
    fi
  fi
  if [ -n "$TEMP_MOUNT_POINT" ]; then
    rmdir "$TEMP_MOUNT_POINT" 2>/dev/null
  fi

  if [ -n "$LUKS_MAPPED_NAME" ] && [ -b "/dev/mapper/$LUKS_MAPPED_NAME" ]; then
    if cryptsetup luksClose "$LUKS_MAPPED_NAME"; then
      log "LUKS device '/dev/mapper/$LUKS_MAPPED_NAME' closed successfully."
    else
      log_error "Failed to close LUKS device '/dev/mapper/$LUKS_MAPPED_NAME'. Please close manually."
    fi
  fi

  if [ "$SOURCE_MOUNTED" -eq 1 ]; then
    if umount "$SOURCE_MOUNT_POINT"; then
      log "Source mount point '$SOURCE_MOUNT_POINT' unmounted successfully."
    else
      log_error "Failed to unmount source mount point '$SOURCE_MOUNT_POINT'. Please unmount manually."
    fi
  fi

  log "Script finished."
}

# --- Steps ---

# Mount the source partition read-only and validate the rsync source directory.
mount_source() {
  if mountpoint -q "$SOURCE_MOUNT_POINT"; then
    log_error "Source mount point '$SOURCE_MOUNT_POINT' is already mounted. Exiting."
    exit 1
  fi
  if [ ! -b "$SOURCE_PARTITION" ]; then
    log_error "Source partition with UUID '$SOURCE_UUID' not found. Exiting."
    exit 1
  fi
  mkdir -p "$SOURCE_MOUNT_POINT" || {
    log_error "Failed to create source mount point '$SOURCE_MOUNT_POINT'. Exiting."
    exit 1
  }
  if mount -o ro "$SOURCE_PARTITION" "$SOURCE_MOUNT_POINT"; then
    SOURCE_MOUNTED=1
    log "'$SOURCE_PARTITION' mounted read-only to '$SOURCE_MOUNT_POINT'."
  else
    log_error "Failed to mount '$SOURCE_PARTITION' to '$SOURCE_MOUNT_POINT'. Exiting."
    exit 1
  fi

  if [ ! -d "$RSYNC_SOURCE_DIR" ]; then
    log_error "The rsync source directory '$RSYNC_SOURCE_DIR' does not exist or is not a directory. Exiting."
    exit 1
  fi
  if [ ! -r "$RSYNC_SOURCE_DIR" ]; then
    log_error "The rsync source directory '$RSYNC_SOURCE_DIR' is not readable. Check permissions. Exiting."
    exit 1
  fi
}

# Find the first connected USB drive from the whitelist.
find_target_drive() {
  local uuid
  for uuid in "${ALLOWED_USB_UUIDS[@]}"; do
    if [ -b "/dev/disk/by-uuid/$uuid" ]; then
      TARGET_UUID="$uuid"
      TARGET_DEVICE_PATH=$(readlink -f "/dev/disk/by-uuid/$uuid")
      log "Found allowed USB drive: '$TARGET_DEVICE_PATH' with UUID '$TARGET_UUID'."
      return 0
    fi
  done
  log_error "No allowed USB drive found or connected. Please connect an allowed USB drive. Exiting."
  exit 1
}

# Open the LUKS device (cryptsetup prompts for the password itself, so it
# never ends up in a shell variable) and mount it on a temporary mount point.
open_and_mount_usb() {
  LUKS_MAPPED_NAME="luks_backup_${TARGET_UUID%%-*}"

  log "Opening LUKS device '$TARGET_DEVICE_PATH' as '$LUKS_MAPPED_NAME' (you will be asked for the password)..."
  if cryptsetup luksOpen "$TARGET_DEVICE_PATH" "$LUKS_MAPPED_NAME"; then
    log "LUKS device '/dev/mapper/$LUKS_MAPPED_NAME' opened successfully."
  else
    log_error "Failed to open LUKS device '$TARGET_DEVICE_PATH'. Check password or device. Exiting."
    LUKS_MAPPED_NAME="" # nothing to close in cleanup
    exit 1
  fi

  TEMP_MOUNT_POINT=$(mktemp -d -t luks_backup_XXXXXX) || {
    log_error "Failed to create temporary mount point. Exiting."
    exit 1
  }

  if mount -o noatime "/dev/mapper/$LUKS_MAPPED_NAME" "$TEMP_MOUNT_POINT"; then
    USB_MOUNTED=1
    log "LUKS device mounted successfully to '$TEMP_MOUNT_POINT'."
  else
    log_error "Failed to mount '/dev/mapper/$LUKS_MAPPED_NAME' to '$TEMP_MOUNT_POINT'. Exiting."
    exit 1
  fi
}

# Define and create the backup directories on the mounted USB drive.
prepare_target_dirs() {
  TARGET_BASE_DIR="$TEMP_MOUNT_POINT/$USB_BACKUP_BASE_DIR"
  CURRENT_BACKUP="$TARGET_BASE_DIR/current"
  PREVIOUS_1="$TARGET_BASE_DIR/previous_1"
  PREVIOUS_2="$TARGET_BASE_DIR/previous_2"
  INCOMPLETE_BACKUP="$TARGET_BASE_DIR/incomplete"

  mkdir -p "$TARGET_BASE_DIR" || {
    log_error "Failed to create backup base directory '$TARGET_BASE_DIR'. Exiting."
    exit 1
  }
}

# Rsync into the staging directory 'incomplete', hardlinking unchanged files
# against 'current'. The existing backups stay untouched until this succeeds.
# A stale 'incomplete' from an aborted run is simply reused and fixed up.
run_backup() {
  #   --archive: enable archive mode; equals -rlptgoD (recursive, links, perms, times, group, owner, devices/specials)
  #   -A: preserve ACLs (Access Control Lists)
  #   -X: preserve extended attributes
  #   --delete: delete extraneous files from destination dirs (files that are not in source)
  #   --info=progress2: show overall progress (can be removed for quieter runs)
  #   --link-dest: hardlink files that are unchanged from the specified
  #                directory, saving space. Needs to be an absolute path.
  local rsync_opts=(--archive -A -X --delete --info=progress2)
  if [ -d "$CURRENT_BACKUP" ]; then
    rsync_opts+=(--link-dest="$CURRENT_BACKUP")
  fi

  log "Executing rsync to staging directory '$INCOMPLETE_BACKUP'..."
  local rc=0
  rsync "${rsync_opts[@]}" "$RSYNC_SOURCE_DIR" "$INCOMPLETE_BACKUP/" || rc=$?

  if [ "$rc" -eq 24 ]; then
    log "Rsync finished with a warning: some source files vanished during transfer (exit code 24)."
  elif [ "$rc" -ne 0 ]; then
    log_error "Rsync failed with exit code $rc. Existing backups are untouched; '$INCOMPLETE_BACKUP' is kept for the next run. Exiting."
    exit 1
  else
    log "Rsync completed successfully."
  fi
}

# Rotate the backups: current -> previous_1 -> previous_2, then promote the
# freshly synced staging directory to 'current'. Only called after a
# successful rsync, so any failure here aborts without losing the new backup.
rotate_backups() {
  log "Rotating backups in '$TARGET_BASE_DIR'..."

  if [ -e "$PREVIOUS_2" ]; then
    rm -rf "$PREVIOUS_2" || {
      log_error "Failed to remove oldest backup '$PREVIOUS_2'. Exiting."
      exit 1
    }
  fi
  if [ -e "$PREVIOUS_1" ]; then
    mv "$PREVIOUS_1" "$PREVIOUS_2" || {
      log_error "Failed to rename '$PREVIOUS_1' to '$PREVIOUS_2'. Exiting."
      exit 1
    }
  fi
  if [ -e "$CURRENT_BACKUP" ]; then
    mv "$CURRENT_BACKUP" "$PREVIOUS_1" || {
      log_error "Failed to rename '$CURRENT_BACKUP' to '$PREVIOUS_1'. Exiting."
      exit 1
    }
  fi
  mv "$INCOMPLETE_BACKUP" "$CURRENT_BACKUP" || {
    log_error "Failed to promote '$INCOMPLETE_BACKUP' to '$CURRENT_BACKUP'. Exiting."
    exit 1
  }

  log "Backup rotation completed."
}

# --- Main Script Logic ---

# Check if script is run as root (plain echo: the log file needs root, too).
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root. Exiting." >&2
  exit 1
fi

# Acquire the script lock atomically. The lock is tied to the file descriptor
# and released automatically when the script exits, even on kill -9.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log_error "Another backup instance is running (lock: $LOCK_FILE). Exiting."
  exit 1
fi

log "Script started as root."
trap cleanup EXIT

mount_source
find_target_drive
open_and_mount_usb
prepare_target_dirs
run_backup
rotate_backups

log "Backup script finished for UUID: $TARGET_UUID."
