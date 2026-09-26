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

A pin is also **verified**, not just requested. After installing, the role runs
`/usr/bin/caddy version` and asserts the result matches `caddy_version`, so a
host where dpkg and the binary disagree — a diverted path, a half-configured
package, something installed over the top — fails naming both versions instead
of serving a version nobody asked for.

## What `--check` does, and what it refuses to do

`--check` on a host **without** Caddy reports what a real run would install and
executes nothing that needs the result. It does not run `caddy version`, does
not touch systemd, does not validate a configuration, and leaves the host
exactly as it found it. `--check` on a host that **already has** Caddy reads the
real version and checks the pin, because there the binary is not a prediction.

The distinction is a fact, not a mode test:

| fact | what it means | where it comes from |
|---|---|---|
| `caddy_present_before_run` | Caddy was here before this play started | `stat` of `/usr/bin/caddy`, before the apt task |
| `caddy_will_be_installed` | this run installs it, or would | `not caddy_present_before_run` |
| `caddy_can_be_executed_now` | the binary **exists right now** | `stat` of `/usr/bin/caddy`, after the apt task |

> ⚠️ **Never infer presence from the package task.** Under `--check`, `apt`
> reporting `changed: true` means *"would install"*. This role once read it as
> *"did install"* and called `caddy version` on the strength of it:
>
> ```
> TASK [caddy : Install Caddy]
>   The following NEW packages will be installed: caddy
>   changed: [dc1-x86]
> TASK [caddy : Record the installed version]
>   fatal: [dc1-x86]: FAILED! => {"cmd": "caddy version",
>     "msg": "[Errno 2] No such file or directory: b'caddy'", "rc": 2}
> ```
>
> Two more of the same shape were found by running the role rather than reading
> it: `systemd_service` fails on a missing unit **even in check mode**
> (`Could not find the requested service caddy: host`), and on a genuinely
> fresh host `apt` cannot resolve the package at all, because the repository
> file was reported rather than written (`No package matching 'caddy' is
> available`). All three are gated on observations now.

`check_mode: false` is right on a task that **observes** the host — `stat`,
`apt-cache policy`, `caddy version` — and is what makes a dry run informative.
On a task that **consumes** a prediction it is the defect itself. That is the
whole line, and `tests/run-caddy-check-mode.sh` holds it.

## Applying an ingress change — `tasks_from: reload-and-verify`

Ansible runs handlers at the **end of a play**. A role that writes a route,
notifies `Reload Caddy` and then verifies the site is reachable is verifying a
reload that has not happened.

> ⚠️ **That is what dc1-x86 did.** Caddy v2.11.4 active, `conf.d/keel.caddy`
> present, `caddy validate` reporting *Valid configuration* and HTTPS on
> `:443` — and the running process's journal saying
> `No files matching import glob pattern /etc/caddy/conf.d/*.caddy`, with
> nothing listening on `:80` or `:443`. Caddy had loaded before the drop-in
> existed. Verification tested the old in-memory configuration, failed — and
> because the play failed, the pending handler never ran at all. Every file on
> disk was correct, so every file-based check would have passed.

So an application role does not leave its reload pending:

```yaml
- name: Install the route
  ansible.builtin.template: { … }
  notify: Reload Caddy

- name: Apply the pending reload and prove Caddy is serving it
  ansible.builtin.import_role:
    name: caddy
    tasks_from: reload-and-verify

- name: My hostname must be in the configuration Caddy has LOADED
  ansible.builtin.assert:
    that:
      - my_hostname in (caddy_active_config_json | default(''))
```

### A rerun changes no file, and still has to fix the host

Ansible's model of "do I need to act" is *did a file change in this run*. That
is the wrong question after a failed deploy. dc1-x86 is in the state a failure
leaves behind:

| | |
|---|---|
| `conf.d/keel.caddy` | present, and **matches** the template |
| composed on-disk config | validates |
| `caddy.service` | active |
| loaded config | does **not** contain `keel.dc1.lan` |
| `:80` / `:443` | nothing listening |
| pending handler | none — the previous play ended |

So the next run's template task reports `ok`, notifies nothing, and a
change-driven reload never happens, while the host serves nothing. **No
file-based check can see this**, because the files are right.

`detect-drift.yml` asks the other question: does the configuration Caddy **has
loaded** equal what the files **adapt to**? `caddy adapt` produces exactly what
a reload would install and the admin API returns exactly what is installed —
measured byte-for-byte identical on a converged host — so an inequality *is*
drift, whatever caused it. The comparison names no site and no application,
because "the running process disagrees with `/etc/caddy`" is a property of the
host.

The drift task is a read-only `caddy adapt` whose **`changed_when` is the drift
condition**, so detecting staleness is what notifies `Reload Caddy`. An
application role still writes only its drop-in and still issues no reload.

Under `--check` a stale host stays stale, so the run reports

```
CHECK MODE: would reload Caddy because active configuration is stale
```

skips the active listener and route assertions with an explicit deferral note —
failing those would mean failing a dry run for correctly declining to act — and
**still fails on invalid on-disk configuration**, which validation catches in
both modes.

`reload-and-verify` runs, in this order:

| | step | why it is separate |
|---|---|---|
| c | validate the **composed** configuration | read-only; fails before the service is touched, with the whole config in the error |
| c2 | `detect-drift.yml` — compare adapted files with the loaded config | notifies the reload when nothing changed but the process is stale; runs **after** validation, so a reload is only ever notified for a configuration known to be valid |
| d | `meta: flush_handlers` | the fix — the reload happens **here**, not at end of play |
| e | assert the service is active | a reload that killed the service is not a reload |
| f | assert `:80` and `:443` exist and are held **only** by caddy | a site can adapt and validate and still bind nothing |
| — | read the loaded config from the admin API into `caddy_active_config_json` | "on disk" and "loaded" are different claims, and only the second serves traffic |

The caller then runs its HTTPS verification (g), against a route already proved
live. The admin API read uses the loopback-only endpoint this role configures
(`admin localhost:2019`); it is queried from the host itself and nothing is
exposed. (enforced: `tests/run-caddy-handler-order.sh`)

**Reload, never restart, for a drop-in.** A restart drops every in-flight
connection for every site on the host. `Restart Caddy` exists, but only a
package or unit change notifies it.

**An invalid configuration leaves the running one intact.** Validation happens
before the flush and again inside the handler, so a malformed drop-in fails the
play on the same process, still serving the previous route — verified down to
the PID.

### For roles that consume this one

An application role must not assert on `/etc/caddy/conf.d` unconditionally: in
a dry run against a fresh host this role reports that directory and creates
nothing. Gate on the published fact instead, which says whether the artifacts
are real rather than predicted:

```yaml
when: caddy_artifacts_real | default(true) | bool
```

This role also publishes `caddy_binary_path`, `caddy_log_dir_path`,
`caddy_conf_d_path`, `caddy_service_user` and `caddy_service_group`, so no
consumer has to keep its own copy of them. Two hand-maintained constants for
one path drift, and the drift is silent.

**A site that logs to a file must create that file as `caddy_service_user`
before its route is validated.** `caddy validate` runs as root and, for a site
with a `log` directive, opens the log file to check the writer — creating it
`0600 root:root` when absent. Caddy then runs as the service account and cannot
open it, so the reload fails while validation keeps reporting
`Valid configuration`:

```
loading new config: setting up custom log 'log0': opening log writer:
open /var/log/caddy/keel.dc1.lan.log: permission denied
```

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

It exists after the **first** run of this role, which is why the `scp` below
works the first time you try it. Caddy creates its local CA lazily — on the
first site that needs a certificate — so on a host with no sites yet there was
no root to publish, and the file appeared only on some later run. The main
Caddyfile therefore declares the authority explicitly:

```caddyfile
pki {
	ca local {
		name "Caddy Local Authority"
	}
}
```

Same CA, same name Caddy would have generated by itself; declaring it fixes
*when*. (enforced: `tests/run-caddy-check-mode.sh` "the internal root CA is
published on the FIRST deploy")

This role also adds the root to **dc1-x86's own** trust store
(`update-ca-certificates`), so health checks made on that host verify the chain
properly instead of being told to skip verification.

Because the play does that, **Caddy is told not to**. The main Caddyfile sets
the global option `skip_install_trust`, which puts `install_trust: false` in
the adapted config. Without it Caddy tries to install the root itself on every
start, fails because it runs unprivileged, and logs:

```
failed to install root certificate: failed to execute sudo
```

The error is harmless — the root is already installed, by Ansible, as root —
but the only ways to silence it are this option or **granting the caddy
service sudo**, which is a real privilege handed over to quiet a log line
about work already done. The CA is still generated, still published, still
trusted; only Caddy's own attempt is switched off. (enforced:
`tests/run-caddy-handler-order.sh` "no sudo trust error", "the caddy service
account has no sudo access", and an HTTPS request that verifies without
`--insecure`)

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
