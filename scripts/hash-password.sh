#!/usr/bin/env bash
# Turn a login password into the SHA-512 crypt hash that goes into
# tofu/secrets.auto.tfvars. The password is read without echo, is never
# written to disk and never appears in a command line or shell history.
#
#   scripts/hash-password.sh
set -euo pipefail

if [ ! -t 0 ]; then
  echo "run this in an interactive terminal so the password can be typed without echo" >&2
  exit 1
fi

read -r -s -p "Password: " first; echo >&2
read -r -s -p "Again:    " second; echo >&2

if [ -z "$first" ]; then echo "empty password" >&2; exit 1; fi
if [ "$first" != "$second" ]; then echo "the two entries differ" >&2; exit 1; fi

# -stdin keeps the password out of the process list.
printf '%s\n' "$first" | openssl passwd -6 -stdin
