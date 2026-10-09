"""STAND-IN for the TrueWealth images, for tests of roles/truewealth only.

Not the application. It reproduces exactly the interface the deployment role
relies on — and nothing else:
  web      HTTP :3000  /api/readyz  {"status":"ready","checks":{...}}  /api/healthz
  compute  HTTP :8001  /readyz
  worker   a long-running process
  migrator `node dist/ops/migrate.mjs [--status]` with the real migrator's
           output lines and exit codes (db/migrate.ts), applying real SQL to
           the real PostgreSQL, one transaction per migration. Two kinds
           (TW_STANDIN_MIGRATOR):
             plain    batches 1-5: no checksums, no floor, no verdict
             verdict  batch 7+: checksums (sha256 of the file text), the
                      rollback floor in public._tw_schema_meta, refusals with
                      the real codes, `--adopt-legacy-checksums`, and the
                      `verdict:` last line of --status (db/client.ts
                      migrationStatus/schemaVerdict/ensureMigrated). Unlike
                      the application it does not verify the legacy history
                      before adopting; the role never adopts, so that half
                      is out of scope here.
Version v5bad's web prints SYNTHETIC secret-shaped lines and exits, so the
role's failure diagnostics can be tested for leaks.
"""
import hashlib
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROLE = os.environ.get("TW_STANDIN_ROLE", "")
VERSION = os.environ.get("TW_STANDIN_VERSION", "")
MIGRATOR = os.environ.get("TW_STANDIN_MIGRATOR", "plain")
FLOOR = os.environ.get("TW_STANDIN_FLOOR", "")
MIGRATIONS = "/app/db/migrations"


def serve(port, routes):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = routes.get(self.path.split("?")[0])
            if body is None:
                self.send_response(404)
                self.end_headers()
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    HTTPServer(("0.0.0.0", port), H).serve_forever()


def psql(args, stdin=None):
    env = dict(os.environ, PGPASSWORD=os.environ.get("TW_DB_PASSWORD", ""))
    cmd = ["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-h", os.environ["TW_DB_HOST"], "-p", os.environ.get("TW_DB_PORT", "5432"),
           "-U", os.environ.get("TW_DB_USER", "truewealth"), "-d", os.environ.get("TW_DB_NAME", "truewealth")] + args
    return subprocess.run(cmd, input=stdin, env=env, capture_output=True, text=True)


def migrate(status_only):
    r = psql(["-c", "CREATE TABLE IF NOT EXISTS public._tw_migrations (name text PRIMARY KEY, applied_at text NOT NULL)"])
    if r.returncode != 0:
        print(f"migrate: FAILED — {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'cannot connect'}", file=sys.stderr)
        return 1
    applied = set(psql(["-At", "-c", "SELECT name FROM public._tw_migrations"]).stdout.split())
    files = sorted(f for f in os.listdir(MIGRATIONS) if f.endswith(".sql"))
    pending = [f for f in files if f not in applied]
    if status_only:
        print(f"migrations: {len(files) - len(pending)}/{len(files)} applied, {len(pending)} pending")
        for n in pending:
            print(f"  pending {n}")
        return 0 if not pending else 1
    done = []
    for n in pending:
        sql = open(os.path.join(MIGRATIONS, n)).read()
        r = psql(["-1", "-f", "-"], stdin=sql + f"\nINSERT INTO public._tw_migrations VALUES ('{n}', now()::text);\n")
        if r.returncode != 0:
            err = next((l for l in r.stderr.splitlines() if "ERROR:" in l), r.stderr.strip())
            print(f"migrate: FAILED — {err.split('ERROR:', 1)[-1].strip()}", file=sys.stderr)
            return 1
        done.append(n)
    print(f"migrations applied: {len(done)} new, {len(files) - len(pending)} already applied")
    for n in done:
        print(f"  applied {n}")
    return 0


class DbError(Exception):
    pass


def q(sql):
    """Rows of a query, columns separated by |; DbError on any failure."""
    r = psql(["-At", "-F", "|", "-c", sql])
    if r.returncode != 0:
        lines = r.stderr.strip().splitlines()
        raise DbError(lines[-1].split("ERROR:", 1)[-1].strip() if lines else "cannot connect")
    return [line for line in r.stdout.splitlines() if line != ""]


def checksum(name):
    text = open(os.path.join(MIGRATIONS, name), encoding="utf-8").read().replace("\r\n", "\n")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def verdict_state():
    t, meta, has = (x == "t" for x in q(
        "SELECT to_regclass('public._tw_migrations') IS NOT NULL, to_regclass('public._tw_schema_meta') IS NOT NULL,"
        " EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'"
        " AND table_name = '_tw_migrations' AND column_name = 'checksum')")[0].split("|"))
    rows = {}
    if t and has:
        for line in q("SELECT name, coalesce(checksum, '') FROM public._tw_migrations"):
            name, c = line.split("|", 1)
            rows[name] = c or None
    elif t:
        rows = {name: None for name in q("SELECT name FROM public._tw_migrations")}
    floor = None
    if meta:
        r = q("SELECT value FROM public._tw_schema_meta WHERE key = 'rollback_floor'")
        floor = r[0] if r else None
    files = sorted(f for f in os.listdir(MIGRATIONS) if f.endswith(".sql"))
    sums = {f: checksum(f) for f in files}
    s = {"files": files, "sums": sums, "floor": floor, "head": files[-1] if files else None,
         "pending": [f for f in files if f not in rows],
         "unknown": sorted(n for n in rows if n not in sums),
         "unverified": sorted(n for n, c in rows.items() if n in sums and c is None),
         "mismatched": sorted(n for n, c in rows.items() if n in sums and c is not None and c != sums[n])}
    s["below"] = bool(floor) and (not s["head"] or s["head"] < floor)
    return s


def verdict_of(s):
    if s["below"]:
        return "below_floor", f"this build ({s['head'] or 'none'}) is older than the rollback floor ({s['floor']}); deploy a build at or above it"
    if s["mismatched"]:
        return "mismatch", f"{len(s['mismatched'])} applied migration(s) differ from this build's files"
    if s["unverified"]:
        return "unverified", f"{len(s['unverified'])} applied migration(s) have no recorded checksum; run the migrate step with --adopt-legacy-checksums"
    if s["pending"]:
        return "pending", f"{len(s['pending'])} migration(s) pending; run the migrate step"
    return None, None


def fail(message, code):
    print(f"migrate: FAILED — {message} [{code}]", file=sys.stderr)
    return 1


def migrate_verdict(status_only, adopt):
    try:
        if status_only:
            s = verdict_state()
            n = len(s["files"])
            print(f"migrations: {n - len(s['pending'])}/{n} applied, {len(s['pending'])} pending")
            for name in s["pending"]:
                print(f"  pending {name}")
            print(f"checksums: {len(s['mismatched'])} mismatched, {len(s['unverified'])} unverified"
                  + (f"; {len(s['unknown'])} applied migration(s) newer than this build" if s["unknown"] else ""))
            for name in s["mismatched"]:
                print(f"  mismatched {name}")
            for name in s["unverified"]:
                print(f"  unverified {name}")
            print(f"rollback floor: {s['floor'] or 'none'}; this build: {s['head'] or 'none'}")
            reason, detail = verdict_of(s)
            if reason:
                print(f"not ready: database schema is not ready: {detail}")
            print(f"verdict: {reason or 'ready'}")
            return 1 if reason else 0
        for ddl in ("CREATE TABLE IF NOT EXISTS public._tw_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)",
                    "ALTER TABLE public._tw_migrations ADD COLUMN IF NOT EXISTS checksum TEXT",
                    "ALTER TABLE public._tw_migrations ADD COLUMN IF NOT EXISTS checksum_origin TEXT",
                    "ALTER TABLE public._tw_migrations ADD COLUMN IF NOT EXISTS checksum_recorded_at TEXT",
                    "CREATE TABLE IF NOT EXISTS public._tw_schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)"):
            q(ddl)
        s = verdict_state()
        if s["mismatched"]:
            return fail(f"{len(s['mismatched'])} applied migration(s) differ from the file shipped with this build: "
                        f"{', '.join(s['mismatched'])}. Nothing was changed.", "migration_checksum_mismatch")
        if s["below"]:
            return fail(f"this build's newest migration ({s['head'] or 'none'}) is older than the database's rollback floor "
                        f"({s['floor']}). Nothing was changed.", "schema_below_rollback_floor")
        adopted = []
        if s["unverified"]:
            if not adopt:
                return fail(f"{len(s['unverified'])} applied migration(s) have no recorded checksum: {', '.join(s['unverified'])}. "
                            "Run the migrate step once with --adopt-legacy-checksums. Nothing was changed.",
                            "migration_checksum_unverified")
            for name in s["unverified"]:
                q(f"UPDATE public._tw_migrations SET checksum = '{s['sums'][name]}', checksum_origin = 'adopted',"
                  f" checksum_recorded_at = now()::text WHERE name = '{name}' AND checksum IS NULL")
            adopted = s["unverified"]
        done = []
        for name in s["pending"]:
            sql = open(os.path.join(MIGRATIONS, name), encoding="utf-8").read()
            r = psql(["-1", "-f", "-"], stdin=sql + "\nINSERT INTO public._tw_migrations(name, applied_at, checksum, checksum_origin,"
                     f" checksum_recorded_at) VALUES ('{name}', now()::text, '{s['sums'][name]}', 'applied', now()::text);\n")
            if r.returncode != 0:
                err = next((line for line in r.stderr.splitlines() if "ERROR:" in line), r.stderr.strip())
                return fail(f"migration {name} failed: {err.split('ERROR:', 1)[-1].strip()}", "migration_failed")
            done.append(name)
        floor = s["floor"]
        if FLOOR and FLOOR in set(q("SELECT name FROM public._tw_migrations")) and (not floor or floor < FLOOR):
            q("INSERT INTO public._tw_schema_meta(key, value, updated_at) VALUES ('rollback_floor', "
              f"'{FLOOR}', now()::text) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at"
              " WHERE public._tw_schema_meta.value < EXCLUDED.value")
            floor = FLOOR
    except DbError as e:
        print(f"migrate: FAILED — {e}", file=sys.stderr)
        return 1
    if adopted:
        print(f"checksums adopted for {len(adopted)} migration(s) applied before checksum tracking")
        for name in adopted:
            print(f"  adopted {name}")
    print(f"migrations applied: {len(done)} new, {len(s['files']) - len(s['pending'])} already applied")
    for name in done:
        print(f"  applied {name}")
    if floor:
        print(f"rollback floor: {floor}")
    return 0


def main():
    if sys.argv[1] == "migrate":
        if MIGRATOR == "verdict":
            sys.exit(migrate_verdict("--status" in sys.argv, "--adopt-legacy-checksums" in sys.argv))
        sys.exit(migrate("--status" in sys.argv))
    if ROLE == "web":
        if VERSION == "v5bad":
            # SYNTHETIC secret-shaped output; the role must never echo it.
            print("booting with DATABASE_URL=postgres://tw:SYNTHETIC-DB-PASSWORD-6f1c@postgres/tw", flush=True)
            print("Authorization: Bearer SYNTHETICBEARERTOKEN0123456789abcdef", flush=True)
            print("TW_KEY_SECRET=SYNTHETIC-KEY-SECRET-9a8b7c6d5e4f", flush=True)
            print("user synthetic-victim@example.test balance 1234567.89", flush=True)
            print("fatal: cannot start (synthetic failure)", file=sys.stderr, flush=True)
            sys.exit(1)
        serve(3000, {"/api/readyz": {"status": "ready", "checks": {"db": "ok", "migrations": "ok", "redis": "ok"}},
                     "/api/healthz": {"status": "ok", "version": VERSION}})
    elif ROLE == "compute":
        serve(8001, {"/readyz": {"status": "ready"}})
    elif ROLE == "worker":
        while True:
            time.sleep(3600)
    else:
        print(f"stand-in: nothing to run for role {ROLE}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
