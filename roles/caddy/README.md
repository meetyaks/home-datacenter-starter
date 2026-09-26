# roles/caddy

The host's reverse proxy, and the **only LAN ingress**. This role owns Caddy:
the package, the service, `/etc/caddy/Caddyfile` and `/etc/caddy/conf.d`.

## Why it exists

A Keel deployment finished with every service healthy — gateway, console,
bootstrap, database, queue, workflow engine, object store — and was completely
unreachable. Caddy was not installed on the host at all: no binary, no package,
no unit, no `/etc/caddy`, nothing listening on 80 or 443.

The Keel role had always described Caddy as "separately managed shared
infrastructure" and written one drop-in into a directory it expected to exist.
That was a reasonable boundary and a missing owner: nothing in this repository
ever installed the thing it deferred to. This role is that owner.

## Ownership boundary

| | owned by | may change |
|---|---|---|
| `caddy` package, `caddy.service` | **roles/caddy** | this role only |
| `/etc/caddy/Caddyfile` | **roles/caddy** | this role only |
| `/etc/caddy/conf.d/` (the directory) | **roles/caddy** | this role only |
| `/etc/caddy/conf.d/<app>.caddy` | the application's role | that role only |

The main Caddyfile defines **no sites**. It sets global options and one line:

```
import /etc/caddy/conf.d/*.caddy
```

That import is the entire contract. An application adds, changes or removes one
file; it never edits the main Caddyfile, so it can never take another site down.
A glob matching nothing is not an error, so the configuration stays valid on a
host with no applications deployed yet — which is what a first run leaves.

## Package source and version policy

Caddy's **official Debian/Ubuntu repository**
(`https://dl.cloudsmith.io/public/caddy/stable/deb/debian`). The signing key is
fetched to `/etc/apt/keyrings/caddy-stable.asc` and the repository is `Signed-By`
that file, so apt verifies every package against it.

**No `curl | sh`.** An installer that runs unaudited downloaded shell as root is
not a supply chain anyone can review, and it leaves no package record to upgrade
or remove.

Version policy, stated rather than implied:

- `caddy_version: ""` (default) installs whatever *stable* currently offers.
- `state: present`, **never `latest`** — apt installs it once and does not move
  the version under a running service on any later run. Re-running the role is
  therefore reproducible in the sense that matters.
- Upgrading is explicit: `-e caddy_upgrade=true`.
- To pin, set `caddy_version: "2.8.4"`. Apt then requires exactly that and
  refuses rather than substituting.

## TLS for `.lan`

`keel.dc1.lan` can never get a public certificate — no ACME CA will validate a
name that resolves only inside this network. Caddy's **internal CA** issues for
it instead. That is a real certificate chain that clients verify normally once
they trust the root; it is not a self-signed certificate to be waved past, and
nothing in this repository disables verification.

The root certificate:

| | path |
|---|---|
| Caddy's own copy | `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt` |
| published by this role | `/usr/local/share/ca-certificates/caddy-lan-root.crt` |

The published copy is the one to distribute. Caddy's own lives under a `0700`
data directory in a path that is an implementation detail of its PKI layout.

This role also adds the root to **dc1-x86's own** trust store
(`update-ca-certificates`), so health checks made on that host verify the chain
properly instead of being told to skip verification.

### Trusting it on the Mac Mini

Run these on the Mac, not on dc1-x86. Replace `labadmin@dc1-x86` if your login
differs.

```bash
# 1. Fetch the root certificate from the host that issued it.
scp labadmin@dc1-x86:/usr/local/share/ca-certificates/caddy-lan-root.crt \
    ~/Downloads/caddy-lan-root.crt

# 2. Look at what you are about to trust, before you trust it.
openssl x509 -in ~/Downloads/caddy-lan-root.crt -noout -subject -issuer -dates

# 3. Add it to the system keychain as a trusted root. Prompts for admin.
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain \
     ~/Downloads/caddy-lan-root.crt

# 4. Confirm the chain verifies end to end.
curl -sS -o /dev/null -w '%{http_code}\n' https://keel.dc1.lan/
```

Step 4 must print `200` **without** `-k` or `--insecure`. If it only works with
those, the trust step did not take — fix that rather than keeping the flag.

To remove it later:

```bash
sudo security delete-certificate -c "Caddy Local Authority" \
     /Library/Keychains/System.keychain
```

Firefox keeps its own trust store and will still warn; import the same file
under *Settings → Privacy & Security → Certificates → View Certificates →
Authorities → Import*. Safari and Chrome use the system keychain and need
nothing further.

## Name resolution

Caddy answers for `keel.dc1.lan`; it does not make the name resolve. Clients
need an **A record on the LAN's resolver** — the router, or whatever serves the
`dc1.lan` zone — pointing `keel.dc1.lan` at dc1-x86's address.

Check what exists today, from the Mac:

```bash
dscacheutil -q host -a name keel.dc1.lan     # macOS resolver
dig +short keel.dc1.lan @"$(ipconfig getoption en0 domain_name_server)"
```

If that returns nothing, add the record on the router. The canonical change is
one A record:

```
keel.dc1.lan.   IN  A   <dc1-x86 LAN address>
```

**`/etc/hosts` is not the answer.** It works on exactly one machine, and every
other client that needs the console would need the same edit with nothing
keeping them in agreement. Use it only to test before the record exists, and
remove it afterwards.

The Keel role's post-deploy verification fails with an explicit `INGRESS (DNS)`
message when the name does not resolve from the deployment host, so this is
caught rather than discovered from a browser.

## Adding another site

Write one file into `/etc/caddy/conf.d/<app>.caddy` from that application's own
role, validate it with `caddy validate --adapter caddyfile --config %s` in the
`template` task, and notify `Reload Caddy`. Do not touch anything else here.
