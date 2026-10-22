#!/usr/bin/env bash
# Modelence calls npm run dev each time its development sandbox starts.
set -uo pipefail

ssh_pid=''
app_pid=''
ssh_dir=''
cleanup() {
  trap - EXIT INT TERM
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$ssh_pid" ]]; then
    kill "$ssh_pid" 2>/dev/null || true
    wait "$ssh_pid" 2>/dev/null || true
  fi
  if [[ -n "$ssh_dir" ]]; then rm -rf -- "$ssh_dir"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_ssh() {
  local sshd_bin port listen login
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then sshd_bin=/usr/sbin/sshd; fi
  if [[ -z "$sshd_bin" ]] || ! command -v ssh-keygen >/dev/null; then
    echo '[sandbox-ssh] OpenSSH server is missing; ask Modelence to enable/install it.' >&2
    return 1
  fi
  port="${SANDBOX_SSH_PORT:-2222}"
  listen="${SANDBOX_SSH_LISTEN:-127.0.0.1}"
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
    echo '[sandbox-ssh] SANDBOX_SSH_PORT must be between 1024 and 65535.' >&2
    return 1
  fi
  if [[ "$listen" != 127.0.0.1 && "$listen" != 0.0.0.0 ]]; then
    echo '[sandbox-ssh] SANDBOX_SSH_LISTEN must be 127.0.0.1 or 0.0.0.0.' >&2
    return 1
  fi
  login="$(id -un)" || return 1
  ssh_dir="$(mktemp -d /tmp/modelence-ssh.XXXXXXXX)" || return 1
  chmod 700 "$ssh_dir" || return 1
  printf '%s\n' "$SANDBOX_SSH_AUTHORIZED_KEYS" > "$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys" || return 1
  ssh-keygen -l -f "$ssh_dir/authorized_keys" >/dev/null 2>&1 || {
    echo '[sandbox-ssh] No valid public key found in SANDBOX_SSH_AUTHORIZED_KEYS.' >&2
    return 1
  }
  ssh-keygen -q -t ed25519 -N '' -f "$ssh_dir/host_key" || return 1
  cat > "$ssh_dir/sshd_config" <<EOF
Port $port
ListenAddress $listen
HostKey $ssh_dir/host_key
PidFile $ssh_dir/sshd.pid
AuthorizedKeysFile $ssh_dir/authorized_keys
AllowUsers $login
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
UsePAM no
StrictModes yes
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
Subsystem sftp internal-sftp
EOF
  "$sshd_bin" -t -f "$ssh_dir/sshd_config" || return 1
  echo "[sandbox-ssh] Starting SSH for user $login on $listen:$port. External routing is required."
  echo '[sandbox-ssh] Temporary host key fingerprint (changes on restart):'
  ssh-keygen -lf "$ssh_dir/host_key.pub"
  "$sshd_bin" -D -e -f "$ssh_dir/sshd_config" &
  ssh_pid=$!
}

if [[ -n "${SANDBOX_SSH_AUTHORIZED_KEYS:-}" ]]; then
  start_ssh || echo '[sandbox-ssh] SSH setup failed; continuing app startup. See errors above.' >&2
else
  echo '[sandbox-ssh] SSH disabled. Set SANDBOX_SSH_AUTHORIZED_KEYS to your SSH public key to enable.'
fi

modelence dev "$@" &
app_pid=$!
wait "$app_pid"
app_status=$?
app_pid=''
exit "$app_status"
