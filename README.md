# 🚀 Garage S3 Auto Installer

This project contains a Bash installer that deploys a complete single-node
[Garage](https://garagehq.deuxfleurs.fr/) S3-compatible storage stack on a VPS.

The main installer scripts are:

```bash
install-garage-full.sh
install-garage-full-es.sh
```

Use `install-garage-full.sh` for English or `install-garage-full-es.sh` for the
Spanish installer.

It installs Garage, Garage WebUI, Caddy, and Watchtower using Docker Compose,
configures S3 API access, enables bucket web hosting, prepares DNS-aware reverse
proxy rules, creates an initial bucket and S3 access key, and sets up automatic
daily backups.

## ✅ What The Script Does

The installer performs the full deployment flow:

1. Checks that it is running as `root`.
2. Detects the public IPv4 address of the VPS.
3. Installs required system packages.
4. Installs Docker if it is not already available.
5. Validates available RAM and disk space.
6. Prompts for deployment settings:
   - WebUI domain
   - S3 API domain
   - S3 region
   - WebUI username and password
   - S3 access key name
   - Initial bucket name
   - Garage storage capacity
7. Validates DNS records and supports Cloudflare proxied records.
8. Backs up any existing `/opt/garage-stack` installation.
9. Stops previous Garage-related containers if present.
10. Generates Garage, Caddy, and Docker Compose configuration files.
11. Opens the required firewall ports with UFW.
12. Creates the Docker network used by the stack.
13. Pulls and starts the Docker containers.
14. Initializes the Garage node layout.
15. Creates the first S3 bucket and access key.
16. Enables website hosting for the bucket.
17. Optionally removes empty buckets after confirmation.
18. Installs a daily backup cron job.
19. Writes a final installation summary with endpoints and credentials.

## 🧱 Stack Components

The generated Docker Compose stack includes:

| Service | Image | Purpose |
| --- | --- | --- |
| `garage` | `dxflrs/garage:v2.0.0` | S3-compatible object storage server |
| `garage-webui` | `khairul169/garage-webui:latest` | Browser-based Garage administration UI |
| `caddy-proxy` | `caddy:2-alpine` | Reverse proxy for WebUI, S3 API, and S3 web hosting |
| `watchtower` | `containrrr/watchtower:latest` | Automatic container updates for labeled services |

## 📋 Requirements

Use a fresh or dedicated Linux VPS. The script is intended for Debian/Ubuntu-like
systems with `apt`.

Minimum practical requirements:

- Root access or `sudo`
- At least 20 GB of available disk space
- Docker Compose support
- Public IPv4 connectivity
- DNS records pointing to the VPS or proxied through Cloudflare
- Ports `80` and `443` available, or fallback ports available

The script will try to install missing dependencies automatically.

## 🌐 DNS Setup

Before running the installer, prepare DNS records for the WebUI and S3 endpoint.

Example:

```text
storage.example.com  -> VPS public IP
s3.example.com       -> VPS public IP
*.s3.example.com     -> VPS public IP
*.web.s3.example.com -> VPS public IP
```

When using Cloudflare, proxied records are accepted by the DNS check. The script
uses Caddy internal TLS and expects Cloudflare to handle public TLS. Configure
Cloudflare SSL/TLS mode as `Full`.

The generated routing is:

| URL | Destination |
| --- | --- |
| `https://<webui-domain>` | Garage WebUI |
| `https://<s3-domain>` | S3 API path-style access |
| `https://<bucket>.<s3-domain>` | S3 API virtual-host access |
| `https://<bucket>.web.<s3-domain>` | Public S3 website hosting |

## ⚡ Usage

### 📦 Option 1: Clone The Repository

You can download the full project with `git clone`:

```bash
git clone https://github.com/dotcom350/garage-s3-auto-installer.git
cd garage-s3-auto-installer
chmod +x install-garage-full.sh
sudo ./install-garage-full.sh
```

For the Spanish installer:

```bash
git clone https://github.com/dotcom350/garage-s3-auto-installer.git
cd garage-s3-auto-installer
chmod +x install-garage-full-es.sh
sudo ./install-garage-full-es.sh
```

### ⚡ Option 2: Direct Remote Download

```bash
curl -O https://raw.githubusercontent.com/dotcom350/garage-s3-auto-installer/refs/heads/main/install-garage-full.sh && chmod +x install-garage-full.sh && sudo ./install-garage-full.sh
```

For the Spanish installer:

```bash
curl -O https://raw.githubusercontent.com/dotcom350/garage-s3-auto-installer/refs/heads/main/install-garage-full-es.sh && chmod +x install-garage-full-es.sh && sudo ./install-garage-full-es.sh
```

You can also download the script manually, make it executable, and run it as
root:

```bash
chmod +x install-garage-full.sh
sudo ./install-garage-full.sh
```

Spanish version:

```bash
chmod +x install-garage-full-es.sh
sudo ./install-garage-full-es.sh
```

The script is interactive. It shows a deployment summary before making the final
changes and asks for confirmation.

## 📁 Generated Files

The installer creates and manages files under:

```text
/opt/garage-stack/
```

Important paths:

| Path | Description |
| --- | --- |
| `/opt/garage-stack/garage/docker-compose.yml` | Docker Compose stack |
| `/opt/garage-stack/garage/files/garage.toml` | Garage configuration |
| `/opt/garage-stack/garage/files/Caddyfile` | Caddy reverse proxy configuration |
| `/opt/garage-stack/garage/s3-credentials.txt` | Generated S3 access key credentials |
| `/opt/garage-stack/garage/INSTALL_SUMMARY.txt` | Final deployment summary |
| `/opt/garage-stack/backups/` | Daily backup archives |

Generated credentials and configuration files are written with restrictive file
permissions where possible.

## 💾 Backups

The script installs a daily cron job:

```text
/etc/cron.d/garage-backup
```

The backup script is written to:

```text
/usr/local/bin/garage-backup.sh
```

Backups run every day at `03:15` and are stored in:

```text
/opt/garage-stack/backups/
```

Backup archives older than 7 days are deleted automatically. Backup logs are
written to:

```text
/var/log/garage-backup.log
```

## 🔐 Security Notes

- Keep `/opt/garage-stack/garage/s3-credentials.txt` private.
- Keep `/opt/garage-stack/garage/INSTALL_SUMMARY.txt` private because it may
  contain WebUI and S3 credentials.
- The WebUI password is stored in the generated installation summary.
- Caddy uses internal certificates because the script is designed to work behind
  Cloudflare proxy with public TLS handled by Cloudflare.
- The script may stop and remove existing containers named `garage`,
  `garage-webui`, `caddy-proxy`, `watchtower`, or `nginx-proxy-manager`.

## 📝 Notes About `copy.sh`

The repository also includes `copy.sh`, which appears to be an alternate or older
variant of the same Garage installer. The recommended script is
`install-garage-full.sh` or `install-garage-full-es.sh` because they explicitly
separate:

- S3 API path-style access
- S3 API virtual-host access
- Public bucket website hosting under `*.web.<s3-domain>`

## 🛠️ Troubleshooting

Check running containers:

```bash
docker compose -f /opt/garage-stack/garage/docker-compose.yml ps
```

View Garage logs:

```bash
docker logs --tail 100 garage
```

View Caddy logs:

```bash
docker logs --tail 100 caddy-proxy
```

View the Garage layout:

```bash
docker exec garage /garage layout show
```

View buckets:

```bash
docker exec garage /garage bucket list
```

## 🧹 Uninstalling

The script does not provide an uninstall command. To remove the stack manually,
stop the Docker Compose project and then remove the files only after confirming
that you no longer need the data:

```bash
cd /opt/garage-stack/garage
docker compose down
```

Garage data is stored in Docker volumes, so removing the Compose stack alone does
not necessarily remove stored object data.
