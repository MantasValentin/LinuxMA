#!/usr/bin/env python3
"""
01_write_and_read_verify.py

Run this from one of the db-1 / db-2 nodes (or any host that can reach
db.lab.internal and trusts the lab IPA CA).

What it does:
  1. Connects to db.lab.internal:5000 (HAProxy 'pg_write' listener -> current
     Patroni leader only) and writes a batch of rows to a test table.
  2. Connects to db.lab.internal:5001 (HAProxy 'pg_read' listener -> round
     robin across db-1 and db-2) 100 times (one fresh TCP connection per
     iteration, since HAProxy load-balances per-connection, not per-query),
     and on each connection checks:
        - which backend actually served the read (inet_server_addr())
        - whether that backend is in recovery (pg_is_in_recovery())
        - whether the row count / latest row matches what was just written
  3. Prints a summary: how many reads landed on each backend IP, how many
     reads matched the primary's data, and any mismatches (replication lag).

This does NOT run pgbackrest backups -- you run those manually as instructed.
It just gives you a known, labeled dataset and a way to sanity-check that
both cluster members are reachable and serving replicated reads through the
proxy before you start backup / failover drills.

Requirements:
    pip3 install --user psycopg2-binary

Usage:
    python3 01_write_and_read_verify.py \
        --dbname clustertest \
        --user postgres \
        --rows 20 \
        --read-iterations 100
    (password is read from $PGPASSWORD, a --password-file, or an interactive
     prompt, in that order)
"""

import argparse
import getpass
import os
import random
import string
import sys
import time
import uuid
from collections import Counter

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    sys.exit(
        "psycopg2 is not installed. Run: pip3 install --user psycopg2-binary"
    )


DEFAULT_HOST = "db.lab.internal"
DEFAULT_SSLROOTCERT = "/etc/ipa/ca.crt"
TABLE_NAME = "resilience_probe"


def get_password(args):
    if args.password_file:
        with open(args.password_file, "r") as fh:
            return fh.read().strip()
    if "PGPASSWORD" in os.environ:
        return os.environ["PGPASSWORD"]
    return getpass.getpass(f"Postgres password for user '{args.user}': ")


def connect(host, port, dbname, user, password, sslrootcert, connect_timeout=5):
    return psycopg2.connect(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password,
        sslmode="verify-ca",
        sslrootcert=sslrootcert,
        connect_timeout=connect_timeout,
        application_name="resilience_write_read_test",
    )


def ensure_database(args, password):
    """Connect to the default 'postgres' db on the write port and create
    the test database if it doesn't exist yet. CREATE DATABASE can't run
    inside a transaction block, so autocommit is required."""
    conn = connect(
        args.host, args.write_port, "postgres", args.user, password, args.sslrootcert
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (args.dbname,))
            if cur.fetchone() is None:
                print(f"[setup] database '{args.dbname}' does not exist, creating it")
                cur.execute(f'CREATE DATABASE "{args.dbname}"')
            else:
                print(f"[setup] database '{args.dbname}' already exists")
    finally:
        conn.close()


def ensure_table(args, password):
    conn = connect(
        args.host, args.write_port, args.dbname, args.user, password, args.sslrootcert
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(
                f"""
                CREATE TABLE IF NOT EXISTS {TABLE_NAME} (
                    id BIGSERIAL PRIMARY KEY,
                    run_id UUID NOT NULL,
                    label TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    written_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
    finally:
        conn.close()


def random_payload(n=32):
    return "".join(random.choices(string.ascii_letters + string.digits, k=n))


def write_batch(args, password, run_id):
    conn = connect(
        args.host, args.write_port, args.dbname, args.user, password, args.sslrootcert
    )
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            rows = [
                (str(run_id), args.label, random_payload())
                for _ in range(args.rows)
            ]
            psycopg2.extras.execute_values(
                cur,
                f"INSERT INTO {TABLE_NAME} (run_id, label, payload) VALUES %s "
                f"RETURNING id",
                rows,
            )
            inserted_ids = [r[0] for r in cur.fetchall()]

            cur.execute(f"SELECT count(*) FROM {TABLE_NAME}")
            total_rows = cur.fetchone()[0]

            cur.execute("SELECT pg_current_wal_lsn(), inet_server_addr(), now()")
            wal_lsn, server_addr, ts = cur.fetchone()

        conn.commit()
    finally:
        conn.close()

    print("\n[write] Committed via port %s (write listener)" % args.write_port)
    print(f"[write] Wrote to backend: {server_addr}")
    print(f"[write] Inserted {len(inserted_ids)} rows "
          f"(ids {min(inserted_ids)}..{max(inserted_ids)})")
    print(f"[write] run_id = {run_id}")
    print(f"[write] Table total row count now: {total_rows}")
    print(f"[write] WAL position at commit: {wal_lsn}")
    print(f"[write] Server timestamp: {ts}")

    return {
        "run_id": str(run_id),
        "inserted_ids": inserted_ids,
        "expected_total": total_rows,
        "expected_max_id": max(inserted_ids),
    }


def read_check(args, password, expected):
    hits = Counter()
    in_recovery_by_host = {}
    mismatches = []
    errors = 0

    print(f"\n[read] Issuing {args.read_iterations} reads against port "
          f"{args.read_port} (one fresh connection each, so HAProxy can "
          f"round-robin us across db-1/db-2)...")

    for i in range(1, args.read_iterations + 1):
        try:
            conn = connect(
                args.host, args.read_port, args.dbname, args.user, password,
                args.sslrootcert, connect_timeout=5,
            )
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT inet_server_addr(), pg_is_in_recovery(),
                           count(*), max(id)
                    FROM {TABLE_NAME}
                    """
                )
                server_addr, in_recovery, count_rows, max_id = cur.fetchone()
            conn.close()
        except Exception as exc:  # noqa: BLE001 - we want to keep looping and report
            errors += 1
            print(f"  [{i:3d}] ERROR connecting/querying: {exc}")
            continue

        server_addr = str(server_addr)
        hits[server_addr] += 1
        in_recovery_by_host[server_addr] = in_recovery

        ok = (count_rows == expected["expected_total"]) and (
            max_id == expected["expected_max_id"]
        )
        status = "OK" if ok else "STALE/MISMATCH"
        if not ok:
            mismatches.append((i, server_addr, count_rows, max_id))

        print(f"  [{i:3d}] server={server_addr:<16} "
              f"in_recovery={str(in_recovery):<5} "
              f"rows={count_rows:<6} max_id={max_id:<6} -> {status}")

        if args.read_delay:
            time.sleep(args.read_delay)

    print("\n[read] Summary")
    print("-" * 60)
    for host, count in hits.most_common():
        recovery = in_recovery_by_host.get(host)
        role = "replica" if recovery else ("primary" if recovery is False else "unknown")
        print(f"  {host:<16} served {count:>3} reads   (role: {role})")
    print(f"  connection/query errors: {errors}")
    print(f"  stale/mismatched reads : {len(mismatches)} / {args.read_iterations}")

    if len(hits) < 2:
        print("\n  NOTE: only one backend served reads. Either the other node is "
              "down/out of rotation, or --read-iterations is too low to catch "
              "round-robin distribution. Check 'patronictl list' and the "
              "HAProxy stats page (port 7000) on the proxies.")

    if mismatches:
        print("\n  NOTE: mismatches usually just mean you read a replica before "
              "replication caught up (normal, async lag is small). If mismatches "
              "persist on the SAME host across repeated runs, investigate "
              "replication lag on that node.")

    return {
        "hits": dict(hits),
        "errors": errors,
        "mismatches": mismatches,
    }


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--write-port", type=int, default=5000)
    p.add_argument("--read-port", type=int, default=5001)
    p.add_argument("--dbname", default="clustertest")
    p.add_argument("--user", default="postgres")
    p.add_argument("--password-file", default=None,
                    help="File containing the postgres password. If omitted, "
                         "falls back to $PGPASSWORD, then an interactive prompt.")
    p.add_argument("--sslrootcert", default=DEFAULT_SSLROOTCERT)
    p.add_argument("--rows", type=int, default=20,
                    help="Rows to write in this run's batch (default: 20)")
    p.add_argument("--label", default="write_read_verify",
                    help="Free-text label stored with each row, useful later "
                         "for identifying which script/run produced which data")
    p.add_argument("--read-iterations", type=int, default=100)
    p.add_argument("--read-delay", type=float, default=0.0,
                    help="Seconds to sleep between reads (default: 0)")
    return p.parse_args()


def main():
    args = parse_args()
    password = get_password(args)

    ensure_database(args, password)
    ensure_table(args, password)

    run_id = uuid.uuid4()
    expected = write_batch(args, password, run_id)
    read_check(args, password, expected)


if __name__ == "__main__":
    main()