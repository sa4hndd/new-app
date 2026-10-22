# SSH in the Modelence development sandbox

`npm run dev` now runs `scripts/dev-with-ssh.sh`, which optionally starts OpenSSH
alongside `modelence dev`. Production `npm start` is unchanged.

## Required Modelence capabilities

Modelence must provide an OpenSSH server (`sshd`), `ssh-keygen`, and permission to
run it. Its OS account must allow public-key login. Some container images also
require the platform to create `/run/sshd`. This script does not install system
packages, unlock accounts, or change platform networking.

Modelence must also provide a TCP endpoint or an approved tunnel into the sandbox.
The HTTPS app URL alone is not an SSH endpoint. Modelence's deployment docs do not
document a separate SSH/TCP port: https://docs.modelence.com/deploy/setup
Confirm routing with Modelence before expecting remote access.

## Enable

1. Generate an SSH key on your own device, for example with
   `ssh-keygen -t ed25519`. Keep the private key on that device.
2. In your Modelence **sandbox** environment variables, set
   `SANDBOX_SSH_AUTHORIZED_KEYS` to the contents of the **public** `.pub` file.
   Multiple public keys can be supplied on separate lines. Never use a GitHub
   token or an SSH private key here.
3. The default listener is `127.0.0.1:2222`, for a tunnel terminating inside the
   sandbox. If Modelence supplies direct TCP forwarding, set
   `SANDBOX_SSH_LISTEN=0.0.0.0` and map port 2222 through that supported feature.
   `SANDBOX_SSH_PORT` can override the internal port (1024–65535).
4. Restart the sandbox and inspect `[sandbox-ssh]` logs. They identify missing
   dependencies, the SSH username, and the host key fingerprint. A listener
   starting does not establish that it is reachable from the Internet.
5. Use the hostname and external port provided by Modelence or your approved
   tunnel: `ssh -p EXTERNAL_PORT USER@HOST`. Verify the fingerprint against the
   sandbox logs before trusting the connection.

SSH uses public-key authentication only. Temporary host keys change each time
the development process starts, so verify each replacement rather than disabling
host verification. Keys and SSH configuration live outside the repository under
`/tmp` and are removed on shutdown. SSH errors do not prevent the web app starting.
No public tunnel is created automatically. No remote access is enabled until a
public key is configured, and reachability still depends on the platform.
