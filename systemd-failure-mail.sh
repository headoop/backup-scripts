#!/usr/bin/env bash
#
# Christian Schult <cschult@devmem.de>
#
# Send a failure notification mail to root for a systemd unit. Meant to
# be called from a template unit via OnFailure= (see
# failure-mail@.service); mail delivery relies on the local Postfix
# setup with its alias for root.

set -u

PATH=/usr/bin:/usr/sbin

if [[ $# -ne 1 ]]; then
  echo "usage: ${0##*/} <unit>" >&2
  exit 2
fi

unit="$1"

sendmail -t <<EOF
To: root
Subject: [systemd] Unit $unit failed on $(hostname)
Auto-Submitted: auto-generated

$(systemctl status --full --lines=50 "$unit" 2>&1)
EOF
