#!/usr/bin/env bash
set -euo pipefail

HOST="${WINVER_HOST:-winver}"
KEY_PATH="${HOME}/.ssh/winver_ed25519"
CONFIG_PATH="${HOME}/.ssh/config"
BEGIN_MARKER="# >>> winver"
END_MARKER="# <<< winver"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ ! -f "${KEY_PATH}" ]]; then
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -C "winver mac access" -N ""
fi

touch "${CONFIG_PATH}"
chmod 600 "${CONFIG_PATH}"

TMP_CONFIG="$(mktemp)"
awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
  $0 == begin { skip = 1; next }
  $0 == end { skip = 0; next }
  skip != 1 { print }
' "${CONFIG_PATH}" > "${TMP_CONFIG}"

cat >> "${TMP_CONFIG}" <<EOF
${BEGIN_MARKER}
Host ${HOST}
  HostName ${HOST}
  UserKnownHostsFile ~/.ssh/known_hosts
  IdentityFile ${KEY_PATH}
  IdentitiesOnly yes
  AddressFamily inet
  ServerAliveInterval 30
  ServerAliveCountMax 4
${END_MARKER}
EOF

mv "${TMP_CONFIG}" "${CONFIG_PATH}"
chmod 600 "${CONFIG_PATH}"

echo
echo "Mac side is ready."
echo
echo "Paste this public key into the Windows setup command:"
echo
cat "${KEY_PATH}.pub"
echo
echo "Then run on the Surface as Administrator:"
echo
echo '.\windows\setup.ps1 -MacPublicKey "PASTE_THE_PUBLIC_KEY_HERE"'
