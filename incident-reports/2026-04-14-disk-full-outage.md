# Incident Report: Disk Full Outage Causing Site Downtime

**Date**: 2026-04-14
**Severity**: High (Production Outage)
**Status**: Resolved — open action items remain
**Affected Systems**: vultr-prod — wiki.wetfish.net, wetfishonline.com, and all wetfish services

---

## Executive Summary

The root filesystem on vultr-prod reached 100% capacity, causing PHP-FPM workers on `wiki-php` to hang (unable to write), resulting in 504 timeouts across the wiki and degraded service across all sites. The immediate cause was unbounded log growth (Docker container logs + Traefik access log). The contributing cause was a broken backup cron job that silently failed for over 3 months, preventing the 7-day local backup pruning from ever running, which allowed stale backup dirs to accumulate on disk.

Deeper investigation revealed the backup system had multiple compounding failures: the cron path was wrong, the backup script had wrong internal paths, the rclone S3 remote was wrong, and the wiki uploads sync was running in reverse (restoring from S3 to local rather than backing up local to S3). As a result, no DB backups reached S3 since October 9, 2025 (~6 months), and wiki uploads have not been synced to S3 since the original upload cron was commented out (date unknown).

Sites were restored by freeing ~33G of disk and recreating the `wiki-php` container. Backup scripts were fixed and a successful backup was confirmed in S3.

---

## Current Impact

- **wiki.wetfish.net**: Down ~3 hours with 504 Gateway Timeout errors (PHP-FPM workers hung)
- **wetfishonline.com**: Degraded — 504s observed in access logs
- **All services**: At risk — disk at 100% means any write (logs, sessions, db) could fail
- **DB backups**: No backups to S3 since October 9, 2025 (~6 months)
- **Wiki uploads**: Not synced to S3 since an unknown date — S3 has 36,771 files, local has 19,487; gap of ~17k files represents uploads made before the original sync cron was disabled
- **click / danger DBs**: Never included in backups — missing credentials in backup script

---

## Event-to-Cause Analysis

### Layer 1 — Immediate trigger: disk full

Three unrelated disk consumers each grew without bound:

| Consumer | Size | Root cause |
|---|---|---|
| Traefik `access.log` | 21G | No logrotate configured |
| Docker container JSON logs (`online-web`, `online-php`, `wiki-web`, others) | 6.4G | No `max-size` or `max-file` in compose files |
| Local DB backup dirs in `/root/wetfish-backups/databases/` | 5.7G | 75 daily dirs accumulated Oct–Jan; pruning never ran because the backup cron was silently failing |

When disk hit 100%, `wiki-php` PHP-FPM workers could not write anything (tmp files, logs, sessions). Workers hit `pm.max_children=5` and hung. All subsequent requests timed out with 504.

### Layer 2 — Why backups stopped: broken cron path

The crontab entry referenced the wrong script path:
```
# What was in crontab:
0 */6 * * * /opt/web-services-cybaxx/util/improved-backups.sh

# Correct path:
0 */6 * * * /opt/web-services/util/improved-backups.sh
```

The repo was previously located at (or named) `/opt/web-services-cybaxx/` and was renamed to `/opt/web-services/`. The crontab was never updated. The script not found → silent exit → no backup, no pruning. Last successful run: **January 6, 2026**.

Cron output was redirected to `/var/log/backups.log` but only on success — a missing script produces no output at all, so the failure was completely invisible.

### Layer 3 — Why backups were broken before that: script bugs

Even before the cron path was wrong, the backup script itself had multiple bugs that would have prevented S3 uploads from working:

1. **`SERVICE_DIR` wrong path**: hardcoded `/opt/web-services-cybaxx/prod/services` — same stale name, would fail to read `mariadb.env` credentials
2. **rclone remote wrong**: used `wetfish-backups/databases/` (local path) instead of `vultr-s3:wetfish-backups/databases/` (S3 remote) — uploads would fail with "bucket not found" or write locally
3. **Missing `--s3-no-check-bucket`**: rclone attempted to create the bucket on every upload, failing with 409 BucketAlreadyExists

Last confirmed S3 backup: **October 9, 2025**. The script bugs predate the cron path bug, meaning S3 backups were broken for an unknown period before January.

### Layer 4 — Wiki uploads never backed up: reversed sync direction

The backup script's wiki upload section:
```bash
# What the script does (WRONG — this is a restore, not a backup):
rclone copy vultr-s3:wetfish-uploads /mnt/wetfish/wiki/uploads

# What it should do:
rclone copy /opt/web-services/prod/services/wiki/upload/ vultr-s3:wetfish-uploads
```

The sync direction is reversed. Additionally, the source path is wrong — live wiki uploads go to `/opt/web-services/prod/services/wiki/upload/`, not `/mnt/wetfish/wiki/uploads/`.

The original crontab had a now-commented-out line that synced uploads correctly:
```bash
#0 */6 * * * rclone ... copy /mnt/wetfish/wetfish/wiki/uploads/* vultr-s3:wetfish-uploads
```
This was disabled and replaced with the reversed logic in the backup script. Since then, new wiki uploads have not reached S3. S3 retains files from the old sync; local has a different (smaller) set.

### Layer 5 — Why nothing alerted: no monitoring

No disk usage alerts, no backup health checks, no independent verification of S3 contents. The only signal was user-visible downtime. The backup cron failing for 3+ months went unnoticed because:
- Cron failure produces no output when the script path doesn't exist
- There was no independent system checking whether backups appeared in S3
- Log growth was invisible until it caused an outage

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 2025-10-09 | Last confirmed DB backup reaches S3 |
| ~2025-10 | Wiki upload sync cron commented out; reversed logic added to backup script |
| ~2026-01-06 18:01 | Last successful local backup run (cron still working at this point) |
| ~2026-01-07+ | Cron begins silently failing — script path no longer resolves |
| 2026-04-14 ~00:40 | `wiki-php` PHP-FPM hits `pm.max_children=5`, workers hang — disk full |
| 2026-04-14 ~03:20 | Outage noticed, investigation begins |
| 2026-04-14 03:45 | Root cause identified: disk 100% full |
| 2026-04-14 03:48 | Cron path fixed; backup script `SERVICE_DIR`, rclone remote, and `--s3-no-check-bucket` fixed |
| 2026-04-14 03:48 | First successful DB backup in ~3 months — wiki DB (62MB) confirmed in S3 |
| 2026-04-14 03:57 | Disk cleaned (~33G freed, 100% → 45%); `wiki-php` recreated and serving 200s |

---

## What Was Verified During Investigation

- **All databases are persisted correctly** — `db/data` bind mounts resolve to `/opt/web-services/prod/services/*/db/data/` and contain real MariaDB files dating to June 2025. The `web-services-cybaxx` paths visible in `docker inspect` are an artifact of when containers were originally started; the data is intact.
- **Online fish/cache storage is intact** — verified by exec into container; files present at correct paths
- **Wiki uploads are intact locally** — 19,487 files, 20G at `/opt/web-services/prod/services/wiki/upload/`
- **All sites serving** — confirmed 200s after disk cleanup and wiki-php recreation

---

## Unresolved Gaps

| Gap | Detail |
|---|---|
| Wiki uploads not in S3 | ~17k file gap; sync direction reversed in backup script; live path incorrect |
| `click` and `danger` DBs not backed up | `get_database_name()` returns empty; `mariadb.env` credentials may be missing |
| Backup script untracked by git | Fixes made today exist only on the server — not committed to the repo |
| `util/vultr-s3.conf` untracked | S3 credentials file not in git (intentional?) but means config is undocumented |
| `node_exporter` tarball in repo root | Install artifact, not cleaned up, untracked by git |
| `prod/services/blog` checked out but not deployed | No `config.js`, not in traefik routing, no container running |
| `stage/` environment not running | Scaffolded but no `.env`, no containers — status unclear (intentional dormancy or broken?) |
| `migrate.sh` deleted but unstaged | Tracked deletion sitting in git working tree, never committed |
| Repo git state generally drifted | Last commit Jan 6; multiple modified submodules, untracked files |

---

## Resolution

1. **Truncated** Docker container JSON logs (~6.4G freed)
2. **Truncated** Traefik access log (~21G freed)
3. **Deleted** stale local DB backup dirs (~5.7G freed)
4. **Cleared** apt cache (~277M freed)
5. **Fixed** crontab path: `web-services-cybaxx` → `web-services`
6. **Fixed** backup script: corrected `SERVICE_DIR`, rclone remote (`vultr-s3:wetfish-backups`), added `--s3-no-check-bucket`
7. **Recreated** `wiki-php` container from correct compose path — now serving 200s
8. **Confirmed** wiki and forums DB backups in S3 as of 2026-04-14

---

## Action Items

| Priority | Task | Owner | ETA |
|---|---|---|---|
| **Done** | Free disk space (logs, backups, apt cache) | Cyba | 2026-04-14 |
| **Done** | Fix cron job path | Cyba | 2026-04-14 |
| **Done** | Fix backup script paths and S3 remote | Cyba | 2026-04-14 |
| **Done** | Restore wiki-php and confirm sites up | Cyba | 2026-04-14 |
| **This week** | Fix wiki upload sync direction in backup script — reverse to local→S3, correct source path | TBD | EOW |
| **This week** | Investigate and fix `click` and `danger` DB backup coverage | TBD | EOW |
| **This week** | Audit actual daily log sizes to determine safe rotation limits | TBD | EOW |
| **This week** | Add Docker log rotation to all compose files (size TBD from audit) | TBD | EOW |
| **This week** | Add logrotate config for Traefik access log | TBD | EOW |
| **This week** | Move wiki uploads (20G) from root disk to `/mnt/wetfish` | TBD | EOW |
| **This week** | Commit backup script fixes and util scripts to git repo | TBD | EOW |
| **This week** | Verify backup coverage end-to-end: upload test files, record filenames, confirm in S3 next day | TBD | EOW |
| **This week** | Build independent backup verification system — separate cron, alerts if S3 objects missing or stale | siufaa | TBD |
| **This week** | Clarify status of blog and staging environments — intentionally dormant or needs cleanup? | TBD | EOW |
| **Ongoing** | Monitor disk usage — alert before hitting 80% | TBD | TBD |

---

## Notes

- **S3 upload integrity**: rclone verifies sha256 checksums on upload and retries on network interruption. The only unhandled failure mode is a network outage lasting the full 6-hour cron window. Hash files (`.sha256`) are stored alongside each dump in S3.
- **Log rotation limits**: 50MB/file was proposed as a starting point but must be validated against real daily log volume. Audit first, configure after.
- **Backup verification independence**: Per team discussion, the verification system must be completely independent of the backup system — a failure in one must not mask the other. This is the same class of failure that caused 6 months of missed backups to go unnoticed.
- **`docker inspect` source paths**: Containers started before the repo rename show `/opt/web-services-cybaxx/` in `docker inspect` output. This is an artifact — data is correctly located at `/opt/web-services/`. Verified by exec and filesystem inspection. `/opt/web-services-cybaxx/` on disk today contains only empty placeholder dirs created by Docker during wiki-php recreation.

---

*Report prepared by: Cyba*
*Last updated: 2026-04-14*
