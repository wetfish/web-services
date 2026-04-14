# Action Plan: Post-Incident Recovery
**Incident**: 2026-04-14 Disk Full Outage
**Last updated**: 2026-04-14

---

## Priority 1 — Data Safety (Do First)
*These address active data loss risk. Nothing else matters until these are done.*

### 1.1 Fix wiki upload sync direction
**Owner**: TBD | **ETA**: ASAP

The backup script currently restores FROM S3 TO local (backwards). Live wiki uploads at `/opt/web-services/prod/services/wiki/upload/` have not been synced to S3 since the original cron was commented out. ~17k file gap exists between S3 (36,771) and local (19,487).

Fix `improved-backups.sh` — change:
```bash
# Current (WRONG — restore, not backup):
rclone copy vultr-s3:wetfish-uploads /mnt/wetfish/wiki/uploads -P --checksum

# Should be:
rclone copy --s3-no-check-bucket /opt/web-services/prod/services/wiki/upload/ vultr-s3:wetfish-uploads --checksum
```
After fixing, run manually and confirm new local-only files appear in S3.

---

### 1.2 Fix click and danger DB backups
**Owner**: TBD | **ETA**: ASAP

**Root cause now known**: `get_database_name()` in `improved-backups.sh` has the click/danger mapping commented out. The database name is `fishy` for both. Found in `util/test-backups.sh` (older script on prod):
```bash
# This line is commented out in improved-backups.sh — uncomment it:
click|danger) echo "fishy" ;;
```

Steps:
- Uncomment `click|danger) echo "fishy" ;;` in `improved-backups.sh`
- Verify `/opt/web-services/prod/services/click/mariadb.env` and `danger/mariadb.env` have `MARIADB_ROOT_PASSWORD` set
- Run backup manually and confirm click and danger dumps appear in S3

---

### 1.3 Reconcile git histories — prod vs local vs origin
**Owner**: Cyba | **ETA**: ASAP

**Prod and local are on diverged histories.** Neither has been pushed to origin.

| Repo | Latest commit | Commits ahead of origin |
|---|---|---|
| `vultr-prod:/opt/web-services` | `88e3a17` (add packer and unpacker scripts) | **58 commits**, never pushed |
| `local:/Users/cyba/git/web-services` | `d26d11b` (Add staging submodules wiki and home) | **5 commits**, never pushed |
| `origin (GitHub)` | `9a3246a` (merge env into main) | — |

Prod has been used as a development environment with 58 commits that include meaningful config and script changes that do not exist anywhere else. These must be preserved.

Steps:
- Push prod's branch to a recovery branch on GitHub first: `git push origin HEAD:refs/heads/prod-recovery-2026-04-14`
- Review local vs prod divergence and decide which history to keep or merge
- Do NOT `git pull` on prod until histories are reconciled — would overwrite prod's unpushed work

---

### 1.4 Commit all untracked prod scripts to git
**Owner**: TBD | **ETA**: ASAP (after 1.3)

Three scripts exist only on the server, untracked:

| Script | Status | Action |
|---|---|---|
| `util/improved-backups.sh` | Active (cron), fixed today | Commit |
| `util/pack-backups.sh` | Not in cron; backs up all 4 DBs + SCPs to `149.28.239.165` | Review and commit or retire |
| `util/test-backups.sh` | Stale — still has `web-services-cybaxx` path, not in cron | Retire or update and commit |
| `util/unpack-backups.sh` | Restore script | Review and commit |
| `util/vultr-s3.conf` | S3 credentials | Commit redacted example; keep real file in `.gitignore` |

---

### 1.5 Investigate 149.28.239.165 — secondary server
**Owner**: TBD | **ETA**: ASAP

`pack-backups.sh` SCPs backup tarballs to `149.28.239.165:/mnt/`. This IP is also in the traefik IP whitelist. This may be a secondary/backup server with copies of DB dumps predating October 2025. If so, it may contain backup data from the gap period.

- Confirm what this server is
- Check `/mnt/` for backup archives
- Determine if it's still in use and document it

---

## Priority 2 — Prevent Recurrence (Do This Week)
*These prevent the same class of failure from happening again.*

### 2.1 Add Docker log rotation to all compose files
**Owner**: TBD | **ETA**: EOW

No log rotation is configured on any service. Container logs will grow without bound again.

Before configuring, audit current log sizes to pick a safe `max-size`:
```bash
# On vultr-prod — check current log sizes after truncation:
du -sh /var/lib/docker/containers/*/*-json.log | sort -rh
```
Then add to every `docker-compose.yml` service definition:
```yaml
logging:
  driver: "json-file"
  options:
    max-size: "TBD"
    max-file: "3"
```
Per Rachel's feedback: do not guess at `max-size` — measure first over the next week.

---

### 2.2 Add logrotate for Traefik access log
**Owner**: TBD | **ETA**: EOW

The Traefik access log at `/opt/web-services/prod/traefik/logs/access.log` grew to 21G with no rotation. Create a logrotate config:
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

### 2.3 Move wiki uploads off root disk
**Owner**: TBD | **ETA**: EOW

Wiki uploads are 20G on the 61G root disk (`/dev/vda2`). The server has a 100G attached volume at `/mnt/wetfish` with 81G free. Uploads should live there.

Steps:
- Move `/opt/web-services/prod/services/wiki/upload/` to `/mnt/wetfish/wiki/upload/`
- Update `docker-compose.yml` volume mount to point to new path
- Recreate `wiki-php` and `wiki-web` containers
- Verify uploads still load on the site

---

### 2.4 Disk usage alerting
**Owner**: TBD | **ETA**: EOW

There was no alert when disk hit 80%, 90%, or 100%. The only signal was user-visible downtime. node_exporter is already running on the server — hook into existing monitoring or add a simple cron alert.

---

### 2.5 Restore forwardedHeaders config in Traefik static.yml
**Owner**: TBD | **ETA**: EOW

Prod's `static.yml` is missing the `forwardedHeaders.trustedIPs` block that exists in origin/main. This config tells Traefik to trust Cloudflare's `X-Forwarded-For` header so real client IPs are logged and used for rate limiting. Without it, Traefik sees Cloudflare's IP as the client for all requests.

Diff shows the entire block was removed on prod at some point:
```yaml
# Missing from prod — should be present on both web and websecure entrypoints:
forwardedHeaders:
  trustedIPs:
    - 103.21.244.0/22
    - 103.22.200.0/22
    # ... (full Cloudflare range)
  insecure: false
```
Restore from origin/main after git histories are reconciled (1.3).

---

## Priority 3 — Verification (This Week)
*Prove the backup system actually works end-to-end, independently.*

### 3.1 End-to-end backup spot check
**Owner**: TBD | **ETA**: Tomorrow (2026-04-15)

Rachel's requirement: verify backups work by uploading test files and confirming they appear in S3 the next day. Do this after 1.1 and 1.2 are fixed.

Steps:
- Upload a uniquely named test file to the wiki
- Record the generated filename and timestamp
- Upload a test post/content to wetfishonline
- Check S3 the following morning for the file, the wiki DB dump, and the forums DB dump
- Document results

---

### 3.2 Independent backup verification system
**Owner**: siufaa | **ETA**: TBD

Per team discussion: the verification system must be **completely independent** of the backup system. A bug in the backup code must not prevent detection of that bug. This is the same failure mode that caused 6 months of missed backups to go unnoticed.

Requirements:
- Runs on its own cron schedule (not triggered by backup script)
- Checks S3 directly for presence of expected objects
- Verifies timestamps — alerts if newest backup is older than expected window (e.g. >8 hours for a 6-hour cron)
- Alerts via IRC/email/webhook
- Does NOT use any code shared with `improved-backups.sh`

---

## Priority 4 — Housekeeping (This Week)
*Clean up legacy artifacts and clarify ambiguous state.*

### 4.1 Clarify blog and staging environment status
**Owner**: Cyba | **ETA**: EOW

Both are checked out on prod but not running:
- `prod/services/blog` — no `config.js`, not in traefik routing, no container running
- `stage/` — full scaffold present, no `.env`, no containers running

Also: `origin/main` references `prod/services/forum` (forums submodule) which does not exist on prod — prod runs `online` instead. The `.gitmodules` files have diverged significantly between prod and origin.

Decision needed for each: intentionally dormant, needs deployment, or remove entirely?

---

### 4.2 Clean up node_exporter tarball
**Owner**: TBD | **ETA**: EOW

`node_exporter-1.9.1.linux-amd64.tar.gz` and extracted dir in `/opt/web-services/` root are untracked install leftovers. node_exporter runs from `/usr/local/bin/` via systemd. Safe to delete from the repo directory.

---

### 4.3 Document manual server setup steps
**Owner**: TBD | **ETA**: TBD

Several things exist only on the server with no record in the repo. If the server needed to be rebuilt, these would be lost:
- `util/vultr-s3.conf` (S3 credentials — commit a redacted example)
- crontab entries (document in README or commit a `crontab.example`)
- systemd `node_exporter.service`
- `/mnt/wetfish` volume mount setup
- `149.28.239.165` secondary server relationship (once clarified in 1.5)

---

## Summary Checklist

| # | Task | Owner | Status |
|---|---|---|---|
| 1.1 | Fix wiki upload sync direction in backup script | TBD | Open |
| 1.2 | Uncomment click/danger DB name (`fishy`) in backup script | TBD | Open |
| 1.3 | Push prod's 58 unpushed commits to recovery branch; reconcile git histories | Cyba | Open |
| 1.4 | Commit all untracked prod scripts to git | TBD | Open |
| 1.5 | Investigate 149.28.239.165 secondary server | TBD | Open |
| 2.1 | Docker log rotation (audit + configure) | TBD | Open |
| 2.2 | Traefik access log rotation | TBD | Open |
| 2.3 | Move wiki uploads to `/mnt/wetfish` | TBD | Open |
| 2.4 | Disk usage alerting | TBD | Open |
| 2.5 | Restore forwardedHeaders config in Traefik static.yml | TBD | Open |
| 3.1 | End-to-end backup spot check | TBD | Open |
| 3.2 | Independent backup verification system | siufaa | Open |
| 4.1 | Clarify blog, staging, and forum/online submodule status | Cyba | Open |
| 4.2 | Clean up node_exporter tarball from repo root | TBD | Open |
| 4.3 | Document manual server setup steps / runbook | TBD | Open |

---

*See full incident details in `2026-04-14-disk-full-outage.md`*
