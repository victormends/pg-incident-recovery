# Linux Parity Notes

`pg-incident-recovery` is intentionally scoped to multi-cluster PostgreSQL services managed by Windows Service Control Manager (SCM). Every underlying PostgreSQL WAL check and replication-slot SQL query, however, is identical on Linux hosts.

## Equivalent Operational Flow on Linux (`systemd`)

| Responsibility | Windows (`pg-incident-recovery`) | Linux (`systemd` + `psql`) |
|---|---|---|
| Service status discovery | `Get-Service -Name postgresql*` | `systemctl list-units 'postgresql@*.service' --state=failed` |
| Control-data WAL verification | `pg_controldata.exe <PGDATA>` | `sudo -u postgres /usr/lib/postgresql/<ver>/bin/pg_controldata <PGDATA>` |
| Replication slot WAL retention query | `pg-wal-slot-monitor.ps1` via Task Scheduler | Run the same SQL via `psql` under a `systemd` timer or cron job |
| Automatic slot WAL cap (PG 13+) | `max_slot_wal_keep_size` in `postgresql.conf` | `max_slot_wal_keep_size` in `/etc/postgresql/<ver>/<cluster>/postgresql.conf` |

## Cross-Platform Replication Slot Check (`psql`)

Run this query directly on Linux (or AWS RDS/Aurora PostgreSQL with `pg_monitor` role) to inspect retained WAL per inactive slot:

```sql
SELECT
    rs.slot_name,
    rs.slot_type,
    rs.active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), rs.confirmed_flush_lsn)) AS retained_wal,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), rs.restart_lsn)) AS pending_wal
FROM pg_replication_slots rs
WHERE rs.active = false
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), rs.restart_lsn) DESC;
```

## Example `systemd` Timer Scheduling (Linux Alternative to Task Scheduler)

```ini
# /etc/systemd/system/pg-wal-slot-monitor.timer
[Unit]
Description=Run PostgreSQL WAL slot check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

For systemd service failure alerting (`OnFailure=`), boot-race ordering (`After=network-online.target`), and WAL disk-full runbooks, see [`incident-response-runbook`](https://github.com/victormends/incident-response-runbook).
