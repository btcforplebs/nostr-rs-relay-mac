#!/usr/bin/env python3
"""Report on and prune a nostr-rs-relay SQLite database.

Read-only by default. `report` never writes; `prune` refuses to touch the
database unless it is given --apply, and even then it only deletes the tiers
that were explicitly asked for.

Safe tier (the default for `prune`):

  hidden      events with hidden=1 — superseded replaceable events and
              events hidden by the relay. Nothing can ever serve these.
  expired     events past their NIP-40 expires_at. The relay already refuses
              to serve them.
  blocked     events authored by a pubkey in the spam filter's
              blocked_pubkeys list, read from config.toml.

Everything else is opt-in, because it destroys events a client could still
legitimately ask for. Gift wraps (kind 1059) are refused outright: they are
other people's direct messages and this relay is the only copy.

Usage:
  prune-relay-db.py report DB [--config config.toml]
  prune-relay-db.py prune  DB [--config config.toml] [--tier ...] --apply
"""

import argparse
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

# Kinds this script will not delete under any flag. Gift-wrapped DMs are
# other users' messages and are not recoverable from anywhere else.
PROTECTED_KINDS = {1059}

SAFE_TIERS = ("hidden", "expired", "blocked")
OPT_IN_TIERS = ("tombstones",)
BATCH = 5000


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:,.1f} {unit}"
        n /= 1024
    return f"{n:,.1f} PB"


def blocked_pubkeys(config_path):
    """Pull blocked_pubkeys out of config.toml without a TOML dependency."""
    if not config_path or not os.path.exists(config_path):
        return []
    text = open(config_path, encoding="utf-8").read()
    match = re.search(r"^\s*blocked_pubkeys\s*=\s*\[(.*?)\]", text, re.S | re.M)
    if not match:
        return []
    return [v for v in re.findall(r'"([0-9a-fA-F]{64})"', match.group(1))]


def relay_is_running(db_path):
    """True if any process still holds the database open.

    Pruning under a live relay is the one way this script can corrupt
    someone's day, so it is checked before anything else.
    """
    try:
        out = subprocess.run(
            ["lsof", "--", db_path], capture_output=True, text=True, timeout=20
        ).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None  # unknown; caller decides
    return len(out.strip().splitlines()) > 1


def tier_clause(tier, blocked):
    """SQL predicate and parameters selecting the events in a tier."""
    if tier == "hidden":
        return "hidden = 1", []
    if tier == "expired":
        return "expires_at IS NOT NULL AND expires_at < ?", [int(time.time())]
    if tier == "blocked":
        if not blocked:
            return "0", []
        marks = ",".join("?" * len(blocked))
        return f"author IN ({marks})", [bytes.fromhex(p) for p in blocked]
    if tier == "tombstones":
        return "kind = 5", []
    raise ValueError(tier)


def protect(clause):
    """Never let a tier reach a protected kind, whatever it selects."""
    marks = ",".join(str(k) for k in sorted(PROTECTED_KINDS))
    return f"({clause}) AND kind NOT IN ({marks})"


def counts(conn, tiers, blocked):
    rows = []
    for tier in tiers:
        clause, params = tier_clause(tier, blocked)
        n = conn.execute(
            f"SELECT COUNT(*) FROM event WHERE {protect(clause)}", params
        ).fetchone()[0]
        rows.append((tier, n))
    return rows


def report(conn, db_path, blocked):
    page_size = conn.execute("PRAGMA page_size").fetchone()[0]
    page_count = conn.execute("PRAGMA page_count").fetchone()[0]
    freelist = conn.execute("PRAGMA freelist_count").fetchone()[0]
    auto_vacuum = conn.execute("PRAGMA auto_vacuum").fetchone()[0]
    events = conn.execute("SELECT COUNT(*) FROM event").fetchone()[0]
    tags = conn.execute("SELECT COUNT(*) FROM tag").fetchone()[0]

    print(f"database        {db_path}")
    print(f"on disk         {human(os.path.getsize(db_path))}")
    print(f"pages           {page_count:,} x {page_size} ({human(page_count * page_size)})")
    print(f"free pages      {freelist:,} ({human(freelist * page_size)} reclaimable without a rewrite)")
    print(f"auto_vacuum     {['NONE', 'FULL', 'INCREMENTAL'][auto_vacuum]}")
    print(f"events          {events:,}")
    print(f"tag rows        {tags:,}")
    print(f"blocked authors {len(blocked)} (from config.toml)")
    print()

    print("candidates by tier")
    total = 0
    for tier, n in counts(conn, SAFE_TIERS + OPT_IN_TIERS, blocked):
        mark = " " if tier in SAFE_TIERS else "*"
        share = f"{100 * n / events:.1f}%" if events else "—"
        print(f"  {mark} {tier:11} {n:>12,}  {share:>6}")
        if tier in SAFE_TIERS:
            total += n
    print(f"    {'safe total':11} {total:>12,}")
    print("  * opt-in, not deleted by default")
    print()

    print("top kinds")
    for kind, n in conn.execute(
        "SELECT kind, COUNT(*) c FROM event GROUP BY kind ORDER BY c DESC LIMIT 10"
    ):
        note = "  (protected)" if kind in PROTECTED_KINDS else ""
        print(f"    kind {kind:<7} {n:>12,}{note}")


def delete_tier(conn, tier, blocked, apply):
    """Delete one tier in batches. Returns (events, tag_rows) removed."""
    clause, params = tier_clause(tier, blocked)
    where = protect(clause)
    if not apply:
        n = conn.execute(f"SELECT COUNT(*) FROM event WHERE {where}", params).fetchone()[0]
        return n, 0

    events = tags = 0
    while True:
        ids = [
            r[0]
            for r in conn.execute(
                f"SELECT id FROM event WHERE {where} LIMIT {BATCH}", params
            )
        ]
        if not ids:
            break
        marks = ",".join("?" * len(ids))
        # Delete tags explicitly rather than relying on the foreign key:
        # SQLite leaves foreign_keys OFF by default, so ON DELETE CASCADE
        # would silently not fire and orphan every tag row.
        cur = conn.execute(f"DELETE FROM tag WHERE event_id IN ({marks})", ids)
        tags += cur.rowcount
        cur = conn.execute(f"DELETE FROM event WHERE id IN ({marks})", ids)
        events += cur.rowcount
        conn.commit()
        print(f"    {tier}: {events:,} events, {tags:,} tag rows", end="\r", flush=True)
    print(f"    {tier}: {events:,} events, {tags:,} tag rows        ")
    return events, tags


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["report", "prune"])
    ap.add_argument("database")
    ap.add_argument("--config", help="config.toml, for the blocked_pubkeys list")
    ap.add_argument(
        "--tier",
        action="append",
        choices=SAFE_TIERS + OPT_IN_TIERS,
        help="repeatable; defaults to the safe tiers",
    )
    ap.add_argument("--apply", action="store_true", help="actually delete (prune only)")
    ap.add_argument("--vacuum", action="store_true", help="rewrite the file to reclaim space (needs free disk equal to the database size)")
    ap.add_argument("--force-running", action="store_true", help="prune even though the database is open elsewhere")
    args = ap.parse_args()

    if not os.path.exists(args.database):
        sys.exit(f"no such database: {args.database}")

    blocked = blocked_pubkeys(args.config)

    if args.command == "report":
        conn = sqlite3.connect(f"file:{args.database}?mode=ro", uri=True)
        report(conn, args.database, blocked)
        return

    running = relay_is_running(args.database)
    if running and not args.force_running:
        sys.exit(
            "the database is open by another process — stop the relay first "
            "(or pass --force-running if you are certain)"
        )
    if running is None:
        print("warning: could not check whether the relay is running (no lsof)")

    tiers = args.tier or list(SAFE_TIERS)
    conn = sqlite3.connect(args.database)
    before = os.path.getsize(args.database)

    if not args.apply:
        print("DRY RUN — nothing will be deleted. Re-run with --apply.\n")
    for tier, n in counts(conn, tiers, blocked):
        print(f"  {tier:11} {n:>12,}")
    print()

    if not args.apply:
        return

    total_events = total_tags = 0
    for tier in tiers:
        e, t = delete_tier(conn, tier, blocked, True)
        total_events += e
        total_tags += t

    if args.vacuum:
        free = shutil.disk_usage(os.path.dirname(os.path.abspath(args.database))).free
        if free < before:
            print(f"skipping vacuum: needs {human(before)} free, have {human(free)}")
        else:
            print("vacuuming (this rewrites the whole file)…")
            conn.execute("VACUUM")

    conn.close()
    after = os.path.getsize(args.database)
    print(f"\nremoved {total_events:,} events and {total_tags:,} tag rows")
    print(f"file {human(before)} -> {human(after)} ({human(before - after)} reclaimed)")
    if not args.vacuum:
        print("space is marked free inside the file; re-run with --vacuum to shrink it on disk")


if __name__ == "__main__":
    main()
