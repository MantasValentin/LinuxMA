#!/usr/bin/env python3
"""
02_generate_backup_test_data.py

Run this against db.lab.internal:5000 (the write listener) between your
manual pgbackrest backups, so each backup type (full / diff / incr) has a
distinct, identifiable slice of data behind it.

Typical drill:
    1. python3 01_write_and_read_verify.py        # seed + sanity check
    2. (you) run:  pgbackrest --stanza=pg-cluster --type=full backup
    3. python3 02_generate_backup_test_data.py --label after_full
    4. (you) run:  pgbackrest --stanza=pg-cluster --type=diff backup
    5. python3 02_generate_backup_test_data.py --label after_diff
    6. (you) run:  pgbackrest --stanza=pg-cluster --type=incr backup

Each run prints, and appends to a local JSON log file, everything you'll
want later for a PITR drill:
    - the label you gave this batch
    - wall-clock start/end time of the insert
    - the id range inserted
    - the WAL LSN and WAL filename at commit time
    - an md5 checksum of the batch's payloads (for post-restore verification)

Requirements:
    pip3 install --user psycopg2-binary

Usage:
    python3 02_generate_backup_test_data.py --label after_diff --rows 5000
"""

import argparse
import getpass
import json
import os
import random
import string
import sys
import uuid
from datetime import datetime, timezone

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
LOG_FILE = "backup_test_data_log.jsonl"


def get_password(args):
    if args.password_file:
        with open(args.password_file, "r") as fh:
            return fh.read().strip()
    if "PGPASSWORD" in os.environ:
        return os.environ["PGPASSWORD"]
    return getpass.getpass(f"Postgres password for user '{args.user}': ")


def connect(args, password):
    return psycopg2.connect(
        host=args.host,
        port=args.write_port,
        dbname=args.dbname,
        user=args.user,
        password=password,
        sslmode="verify-ca",
        sslrootcert=args.sslrootcert,
        connect_timeout=5,
        application_name="backup_test_data_generator",
    )


def ensure_table(conn):
    conn.autocommit = True
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
    conn.autocommit = False


def random_payload(n=48):
    return "".join(random.choices(string.ascii_letters + string.digits, k=n))


def insert_in_batches(conn, run_id, label, total_rows, batch_size):
    inserted_ids = []
    with conn.cursor() as cur:
        remaining = total_rows
        while remaining > 0:
            chunk = min(batch_size, remaining)
            rows = [(str(run_id), label, random_payload()) for _ in range(chunk)]
            psycopg2.extras.execute_values(
                cur,
                f"INSERT INTO {TABLE_NAME} (run_id, label, payload) VALUES %s "
                f"RETURNING id",
                rows,
            )
            inserted_ids.extend(r[0] for r in cur.fetchall())
            remaining -= chunk
    return inserted_ids


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default=DEFAULT_HOST)
    p.add_argument("--write-port", type=int, default=5000)
    p.add_argument("--dbname", default="clustertest")
    p.add_argument("--user", default="postgres")
    p.add_argument("--password-file", default=None)
    p.add_argument("--sslrootcert", default=DEFAULT_SSLROOTCERT)
    p.add_argument("--rows", type=int, default=5000)
    p.add_argument("--batch-size", type=int, default=500)
    p.add_argument("--label", default=None,
                    help="Tag for this batch, e.g. 'after_full', 'after_diff'. "
                         "Defaults to a timestamp if not given.")
    p.add_argument("--log-file", default=LOG_FILE)
    args = p.parse_args()

    label = args.label or f"batch_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    password = get_password(args)

    conn = connect(args, password)
    try:
        ensure_table(conn)

        run_id = uuid.uuid4()
        start_ts = datetime.now(timezone.utc)
        print(f"[{label}] inserting {args.rows} rows in batches of {args.batch_size}...")
        inserted_ids = insert_in_batches(conn, run_id, label, args.rows, args.batch_size)
        conn.commit()
        end_ts = datetime.now(timezone.utc)

        with conn.cursor() as cur:
            conn.autocommit = True
            cur.execute("SELECT pg_current_wal_lsn(), pg_walfile_name(pg_current_wal_lsn()), now()")
            wal_lsn, wal_file, server_now = cur.fetchone()

            cur.execute(f"SELECT count(*) FROM {TABLE_NAME}")
            total_rows = cur.fetchone()[0]

            cur.execute(
                f"""
                SELECT md5(string_agg(payload, '' ORDER BY id))
                FROM {TABLE_NAME}
                WHERE run_id = %s
                """,
                (str(run_id),),
            )
            payload_md5 = cur.fetchone()[0]
    finally:
        conn.close()

    record = {
        "label": label,
        "run_id": str(run_id),
        "started_at": start_ts.isoformat(),
        "finished_at": end_ts.isoformat(),
        "server_time_at_commit": server_now.isoformat(),
        "rows_inserted": len(inserted_ids),
        "id_min": min(inserted_ids),
        "id_max": max(inserted_ids),
        "table_total_rows_after": total_rows,
        "wal_lsn_at_commit": wal_lsn,
        "wal_file_at_commit": wal_file,
        "payload_md5_this_batch": payload_md5,
    }

    print("\n--- batch summary (save this for your PITR / restore drill) ---")
    print(json.dumps(record, indent=2))

    with open(args.log_file, "a") as fh:
        fh.write(json.dumps(record) + "\n")
    print(f"\nAppended this record to {args.log_file}")
    print("\nNext steps suggestion:")
    print(f"  - Run your pgbackrest backup now (diff/incr) so it captures this batch.")
    print(f"  - To later restore to just AFTER this batch, target time "
          f"'{record['server_time_at_commit']}' or WAL LSN '{wal_lsn}'.")
    print(f"  - After any restore, re-run the same md5 check filtered on "
          f"run_id = '{run_id}' and compare against payload_md5_this_batch "
          f"above to confirm the batch survived intact.")


if __name__ == "__main__":
    main()