# MySQL Deadlock Monitor

InnoDB only keeps the *single most recent* deadlock in `SHOW ENGINE INNODB
STATUS`, so a deadlock between two checks is easy to miss. This script
stores the last-seen deadlock timestamp in a state file and alerts only when
it changes — no alert spam for the same old deadlock.

## Usage

```bash
# Credentials from ~/.my.cnf ([client] user/password) — never from argv.
check-deadlocks.sh --state-file /var/lib/mysql-deadlock-monitor/state --to dba@example.com

# Cron: every 5 minutes
*/5 * * * * /usr/local/bin/check-deadlocks.sh --to dba@example.com
```

## Options

| Flag | Meaning |
|---|---|
| `--state-file FILE` | Where the last-seen timestamp is kept (default `/var/lib/mysql-deadlock-monitor/state`) |
| `--status-file FILE` | Parse a saved InnoDB STATUS dump instead of calling `mysql` (testing) |
| `--to EMAIL` | Mail an alert on a new deadlock |
| `--json` | Machine-readable output (Nagios-style exit codes still apply) |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Latest deadlock unchanged |
| 1 | No deadlock section found in InnoDB status |
| 2 | **New deadlock detected** (alert sent if `--to` given) |
| 3 | Unknown — mysql client missing or query failed |

A sample dump for testing lives in
[sample-innodb-status.txt](sample-innodb-status.txt):

```bash
check-deadlocks.sh --status-file sample-innodb-status.txt --state-file /tmp/dl-state
# first run:  exit 2 (new deadlock); second run: exit 0 (unchanged)
```

## License

MIT — see [LICENSE](LICENSE).
