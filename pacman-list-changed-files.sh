#!/bin/bash
#
# List installed packages whose backup files (usually configs in /etc)
# were modified after installation; files that were removed are marked
# with "(missing)". Reads the %BACKUP% sections of the local pacman
# database: "<path>TAB<md5-at-install-time>" lines.
#
# Based on https://wiki.archlinux.org/index.php/Pacman_tips

set -u

for dbdir in /var/lib/pacman/local/*/; do
  files_index="${dbdir}files"
  [[ -f $files_index ]] || continue
  package=$(basename "$dbdir")

  # keep only the lines between %BACKUP% and the next %SECTION% (or EOF),
  # then drop the section markers themselves
  sed '/^%BACKUP%$/,/^%/!d;/^%/d' "$files_index" |
    while IFS=$'\t' read -r file hash; do
      [[ -n $file ]] || continue
      if [[ ! -e "/$file" ]]; then
        echo "$package /$file (missing)"
      elif [[ $(md5sum "/$file" | cut -d' ' -f1) != "$hash" ]]; then
        echo "$package /$file"
      fi
    done
done
