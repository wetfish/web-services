# 2026-04-14 Recovery & Hardening Report

**Date**: 2026-04-14
**Author**: Cyba
**Scope**: vultr-prod (149.28.239.165), dedi-prod (144.48.106.242), wetfish/web-services, wetfish/FishVision

---

## Overview

Following the 2026-04-14 disk full outage that took wiki.wetfish.net and wetfishonline.com offline, a full recovery and hardening pass was completed. This document summarises every change made, verified, and committed during that session.

For full incident details see `incident-reports/2026-04-14-disk-full-outage.md`.
For the original action plan see `incident-reports/2026-04-14-action-plan.md`.

---

## 1. Immediate Recovery (completed during outage)

| Action | Detail |
|---|---|
| Freed ~33G disk | Truncated Docker container logs (6.4G), Traefik access log (21G), deleted stale backup dirs (5.7G), cleared apt cache (277M) |
| Fixed crontab path | `web-services-cybaxx` → `web-services` |
| Fixed backup script | Corrected `SERVICE_DIR`, rclone remote (`vultr-s3:`), added `--s3-no-check-bucket` |
| Recreated wiki-php | Restored PHP-FPM from correct compose path; confirmed 200s |
| Confirmed S3 backups | wiki and forums DB dumps appeared in S3 within minutes |

---

## 2. Backup System Fixes

### 2.1 Wiki Upload Sync Direction (Action 1.1)
The backup script was syncing S3 → local (reverse). Fixed to sync local → S3:
```bash
# Before (wrong — restore not backup):
rclone copy vultr-s3:wetfish-uploads /mnt/wetfish/wiki/uploads

# After (correct):
rclone copy --s3-no-check-bucket /opt/web-services/prod/services/wiki/upload/ vultr-s3:wetfish-uploads --checksum
```

### 2.2 click and danger DB Coverage (Action 1.2)
`get_database_name()` was hardcoded and missing click/danger. Replaced with `MARIADB_DATABASE` env var lookup:
- `click` → reads `click` from `mariadb.env`
- `danger` → reads `fishy` from `mariadb.env`
- Dump filenames include service prefix (`click-click-DATE.sql`, `danger-fishy-DATE.sql`) to prevent collision

### 2.3 Prometheus Backup Metric (Action 3.2 support)
`improved-backups.sh` now writes a Prometheus textfile metric on successful completion:
```
/var/lib/node_exporter/textfile_collector/backup.prom
backup_last_success_timestamp <unix_timestamp>
```
node_exporter updated with `--collector.textfile.directory` flag.

### 2.4 Spot Check (Action 3.1)
Test file `backup-spot-check-2026-04-14T17-17-39.txt` placed in wiki upload dir and confirmed present in S3 (`vultr-s3:wetfish-uploads`). Content verified matches expected string.

---

## 3. Log Rotation

### 3.1 Docker Container Logs (Action 2.1)
Added logging config to all service `docker-compose.yml` files:
- `online`: `max-size: 100m`, `max-file: 3`
- All others (wiki, click, danger, glitch, home, traefik): `max-size: 50m`, `max-file: 3`
- Containers recreated one-at-a-time with `docker compose up -d --no-deps`

### 3.2 Traefik Access Log (Action 2.2)
Created `/etc/logrotate.d/traefik`:
```
/opt/web-services/prod/traefik/logs/access.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    postrotate
        docker kill --signal=USR1 ingress-proxy
    endscript
}
```

---

## 4. Disk Alerting (Action 2.4)

Added hourly cron to alert when root disk ≥ 80%:
```bash
0 * * * * df / | awk 'NR==2{gsub(/%/,"",$5); if($5+0>=80) print strftime("%F %T") " DISK ALERT: root at " $5 "%"}' >> /var/log/disk-check.log
```

---

## 5. Traefik forwardedHeaders (Action 2.5)

Restored `forwardedHeaders.trustedIPs` (Cloudflare IP ranges) to both `web` and `websecure` entrypoints in `prod/traefik/conf/static.yml`.

**Critical fix**: `forwardedHeaders` must sit directly under the entrypoint, not nested under `http`. The original config had it in the wrong location — tested locally with `traefik:v2.6.1` before deploying. Without this, Traefik sees Cloudflare's IP as the client for all requests, breaking real-IP logging and rate limiting.

---

## 6. Git Reconciliation (Action 1.3)

| Repo | State before | State after |
|---|---|---|
| `origin (GitHub)` | 2 commits (stale) | Full history, 130+ commits |
| `local` | 8 commits, diverged | Rebased onto prod history |
| `vultr-prod` | 122 commits, never pushed | Pushed to `prod-recovery-2026-04-14` branch, then merged to main |

Steps taken:
1. Added prod as local git remote via SSH
2. Fetched prod's 122-commit history
3. Pushed prod history to GitHub as `prod-recovery-2026-04-14` (safety backup)
4. Rebased local's 8 commits onto prod/main
5. Fixed `.gitmodules` — replaced stale `prod/services/forum` with `prod/services/online`
6. Registered `prod/services/online` (wetfish/online) as proper submodule
7. Force-pushed reconciled history to `origin/main`

---

## 7. Committed Untracked Scripts (Action 1.4)

| File | Status |
|---|---|
| `util/improved-backups.sh` | Active production backup script — committed |
| `util/test-backups.sh` | Legacy reference script — committed with stale path warning |
| `util/vultr-s3.conf.example` | Redacted S3 config template — committed |
| `util/crontab.example` | Documents prod root crontab — committed |
| `util/node_exporter.service` | systemd unit with `--collector.textfile.directory` flag — committed |
| `util/vultr-s3.conf` | Added to `.gitignore` to prevent credential leaks |
| `incident-reports/` | Full incident report and action plan — committed |

---

## 8. Wiki Uploads Investigation (Action 2.3)

Confirmed that `/opt/web-services/prod/services/wiki/upload/` and `/mnt/wetfish/wiki/uploads` are the **same inode** on the same virtiofs volume — same device (`0,38`), same inode (`1099714772135`). No migration needed; uploads are already on the attached volume.

The two-stage pipeline history:
- Original: live uploads → S3 → `/mnt/wetfish` (local S3 mirror)
- Broken: upload sync cron commented out; reversed rclone kept restoring S3 → `/mnt/wetfish`
- Fixed: live uploads → S3 (direct), `/mnt/wetfish` is the same physical location as live

---

## 9. Prod Cleanup (Action 4.2)

Removed from vultr-prod:
- `node_exporter-1.9.1.linux-amd64.tar.gz` and extracted dir
- `util/wetfish-backups/` stale directory
- `prod/traefik/conf/static.yml.bak`
- `prod/services/blog/` (no config.js, no container, not in Traefik routing)
- `stage/services/home-staging/`, `online-staging/`, `wiki-staging/` (stale submodule rename artifacts)

Pulled `origin/main` to prod — prod is now in sync with the repo.

---

## 10. FishVision Monitoring (Action 3.2)

### Deployed on dedi-prod (144.48.106.242)
- Updated `/opt/FishVision` to `origin/main`
- Started: prometheus, alertmanager, grafana (port 3030), loki, promtail, tempo, irc-relay
- Excluded: ollama (server can't support LLM workload), irc-bot
- Fixed Loki/Tempo volume permissions (`chown 10001:10001`)
- IRC relay connected to `irc.wetfish.net:6697`, joined `#botspam`

### Alert rules added to FishVision (`prometheus/alert.rules.yml`)
```yaml
- alert: BackupStale
  expr: time() - backup_last_success_timestamp{job="prod-node"} > 28800
  for: 10m
  labels:
    severity: critical

- alert: BackupMetricMissing
  expr: absent(backup_last_success_timestamp{job="prod-node"})
  for: 30m
  labels:
    severity: warning
```
Both route to `#botspam` via IRC relay. Completely independent of the backup script.

### Factory alerts (known false positives)
FishVision fires `FactoryMySQLDown`, `FactoryRedisDown`, `FactoryAppDown` for `45.76.235.77` and `104.156.237.105`. Both sites are up — factory runs on **RKE2 (Kubernetes)**, not Docker Compose. The static scrape targets in `prometheus.yml` point to bare-metal host ports that don't exist in a k8s deployment. Fix requires exposing exporters as k8s services and updating scrape targets accordingly.

---

## 11. Local Dev Environment

Set up for local testing with prod data:

| Service | URL | Image |
|---|---|---|
| Wiki | `http://127.0.0.1:2405` | `ghcr.io/wetfish/wiki:prod-nginx` / `prod-php` |
| Online (forums) | `http://127.0.0.1:2404/forum` | `ghcr.io/wetfish/online:prod-nginx` / `prod-php` |
| Wiki DB | `127.0.0.1:3405` | mariadb:10.10 |
| Online DB | `127.0.0.1:3404` | mariadb:10.10 |

Data: DB dumps restored from prod (2026-04-14). Wiki uploads rsynced from prod (19,869 files, ~11GB).
Compose files: `prod/services/wiki/docker-compose.local.yml`, `prod/services/online/docker-compose.local.yml`

---

## 12. Open Items

| # | Item | Owner |
|---|---|---|
| — | Commit docker-compose logging changes to each service repo (wiki, online, click, danger, glitch, home) | Service maintainers |
| — | Fix FishVision factory scrape targets for k8s deployment | Factory team |
| 4.3 | Document full server setup runbook | TBD |
| — | FishVision `apm-features` → `main` merge follow-up: verify alerts firing correctly in `#botspam` | siufaa |

---

*Report prepared by: Cyba*
*Session date: 2026-04-14*
