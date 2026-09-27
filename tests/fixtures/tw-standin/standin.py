"""STAND-IN for the TrueWealth images, for tests of roles/truewealth only.

Not the application. It reproduces exactly the interface the deployment role
relies on — and nothing else:
  web      HTTP :3000  /api/readyz  {"status":"ready","checks":{...}}  /api/healthz
  compute  HTTP :8001  /readyz
  worker   a long-running process
  migrator `node dist/ops/migrate.mjs [--status]` with the real migrator's
           output lines and exit codes (db/migrate.ts), applying real SQL to
           the real PostgreSQL, one transaction per migration
Version v5bad's web prints SYNTHETIC secret-shaped lines and exits, so the
role's failure diagnostics can be tested for leaks.
"""
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROLE = os.environ.get("TW_STANDIN_ROLE", "")
VERSION = os.environ.get("TW_STANDIN_VERSION", "")
MIGRATIONS = "/app/dist/ops/migrations"


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


def main():
    if sys.argv[1] == "migrate":
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
