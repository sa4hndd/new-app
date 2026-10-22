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

run_root() {
  if [[ "$(id -u)" == 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
    sudo -n -- "$@"
  else
    echo '[sandbox-ssh] Installation requires root or passwordless sudo. Modelence must enable that permission.' >&2
    return 1
  fi
}

install_openssh() {
  if [[ "${SANDBOX_SSH_INSTALL:-1}" != 1 ]]; then
    echo '[sandbox-ssh] Automatic installation disabled by SANDBOX_SSH_INSTALL.' >&2
    return 1
  fi
  echo '[sandbox-ssh] OpenSSH missing. Attempting installation; package-manager output follows.'
  if command -v apt-get >/dev/null; then
    run_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=30 -o Acquire::Retries=1 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update || return 1
    run_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=30 -o Acquire::Retries=1 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends openssh-server openssh-client || return 1
  elif command -v apk >/dev/null; then
    run_root apk add --no-cache openssh || return 1
  else
    echo '[sandbox-ssh] No supported installer found (apt-get or apk). Ask Modelence to include OpenSSH.' >&2
    return 1
  fi
  echo '[sandbox-ssh] OpenSSH installation completed.'
}

start_ssh() {
  local sshd_bin port listen login
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then sshd_bin=/usr/sbin/sshd; fi
  if [[ -z "$sshd_bin" ]] || ! command -v ssh-keygen >/dev/null; then
    install_openssh || return 1
    sshd_bin="$(command -v sshd || true)"
    if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then sshd_bin=/usr/sbin/sshd; fi
    if [[ -z "$sshd_bin" ]] || ! command -v ssh-keygen >/dev/null; then
      echo '[sandbox-ssh] Installation did not provide sshd and ssh-keygen.' >&2
      return 1
    fi
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
  if [[ ! -d /run/sshd ]]; then
    echo '[sandbox-ssh] Preparing OpenSSH runtime directory /run/sshd.'
    run_root mkdir -p /run/sshd || return 1
    run_root chmod 0755 /run/sshd || return 1
  fi
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
  # Confirm it survives initial binding/configuration before announcing readiness.
  sleep 1
  if ! kill -0 "$ssh_pid" 2>/dev/null; then
    wait "$ssh_pid" 2>/dev/null || true
    ssh_pid=''
    echo '[sandbox-ssh] SSH server exited during startup. See OpenSSH error above.' >&2
    return 1
  fi
  echo "[sandbox-ssh] SSH process is running. Username: $login. Internal port: $port."
  echo "[sandbox-ssh] After arranging a Modelence TCP endpoint/tunnel: ssh -p EXTERNAL_PORT $login@EXTERNAL_HOST"
  echo '[sandbox-ssh] The HTTPS preview URL is not an SSH endpoint. No external reachability has been verified.'
}

if [[ -n "${SANDBOX_SSH_AUTHORIZED_KEYS:-}" ]]; then
  start_ssh || echo '[sandbox-ssh] SSH setup failed; continuing app startup. See errors above.' >&2
else
  echo '[sandbox-ssh] SSH disabled. Set SANDBOX_SSH_AUTHORIZED_KEYS to your SSH public key to enable.'
  echo '[sandbox-ssh] Generate a key on your device: ssh-keygen -t ed25519'
  echo '[sandbox-ssh] Put the .pub file contents in Modelence sandbox environment variables, then restart.'
fi

echo '[sandbox-ssh] Starting Modelence dev server.'
modelence dev "$@" &
app_pid=$!
wait "$app_pid"
app_status=$?
app_pid=''
exit "$app_status"
