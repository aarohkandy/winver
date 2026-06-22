#!/usr/bin/env bash
set -euo pipefail

KEY_DIR="${HOME}/.winver"
KEY_PATH="${KEY_DIR}/admin.key"

mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

if [[ ! -f "${KEY_PATH}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 > "${KEY_PATH}"
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 > "${KEY_PATH}"
  fi
  chmod 600 "${KEY_PATH}"
fi

echo
echo "Mac admin signing key is ready at ${KEY_PATH}."
echo
echo "Run this once on the Surface from an elevated PowerShell window:"
echo
printf '.\\windows\\admin\\init-admin.ps1 -AdminKey "%s"\n' "$(cat "${KEY_PATH}")"
echo
echo "Do not commit this key or paste it anywhere public."

