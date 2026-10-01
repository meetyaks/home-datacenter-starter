#!/usr/bin/env python3
"""Turn GitHub's published host keys into a known_hosts file, or refuse.

    github-known-hosts.py <api.github.com-meta.json> <output-known_hosts>

⚠️ WHY NOT `ssh-keyscan github.com`. That records whatever answers on port 22.
It is the standard way to populate known_hosts and it provides no
authentication whatsoever — an interceptor is recorded just as happily as the
real thing, and from then on it is pinned and trusted. For a controller whose
whole job is deciding what a site runs, that is the wrong first step.

https://api.github.com/meta is served over TLS with a validated certificate
chain and carries BOTH `ssh_keys` and `ssh_key_fingerprints`. This recomputes
each key's SHA256 fingerprint from the key material and compares it against
the fingerprint GitHub publishes alongside it. A mismatch is a hard failure
and nothing is written — a partially-correct known_hosts is worse than none,
because it looks done.

It is a separate file from the bootstrap script so it can be tested on its
own, including against a deliberately tampered document.
"""
import base64
import hashlib
import json
import sys

# `ssh_key_fingerprints` keys are SHA256_ED25519, SHA256_RSA, SHA256_ECDSA;
# `ssh_keys` entries are in authorized_keys form. This maps one to the other.
ALGORITHMS = {
    "ssh-ed25519": "ed25519",
    "ssh-rsa": "rsa",
    "ecdsa-sha2-nistp256": "ecdsa",
}


def fingerprint(blob: str) -> str:
    """The SHA256 fingerprint OpenSSH prints, computed from the key itself."""
    digest = hashlib.sha256(base64.b64decode(blob)).digest()
    return base64.b64encode(digest).decode().rstrip("=")


def main(meta_path: str, out_path: str) -> int:
    meta = json.load(open(meta_path))

    keys = meta.get("ssh_keys") or []
    published = {
        name.split("_", 1)[1].lower(): value
        for name, value in (meta.get("ssh_key_fingerprints") or {}).items()
    }

    # ⚠️ BOTH LISTS MUST BE THERE. An empty or absent `ssh_keys` would
    # otherwise write an empty known_hosts and report success, and the next
    # ssh would fail with "Host key verification failed" pointing at the
    # wrong cause.
    if not keys:
        print("refusing: the document carries no ssh_keys", file=sys.stderr)
        return 1
    if not published:
        print("refusing: the document carries no ssh_key_fingerprints to "
              "check the keys against", file=sys.stderr)
        return 1

    lines = []
    for entry in keys:
        parts = entry.split()
        if len(parts) < 2:
            print("refusing: malformed host key entry %r" % entry, file=sys.stderr)
            return 1
        kind, blob = parts[0], parts[1]

        algorithm = ALGORITHMS.get(kind)
        if algorithm is None:
            # Not an error: GitHub may publish a type this script has not been
            # taught. Skipping it is safe — the ones that ARE pinned are still
            # verified — but it is said out loud rather than passed over.
            print("  skipping unrecognised key type %s" % kind)
            continue

        computed = fingerprint(blob)
        expected = published.get(algorithm)
        if expected != computed:
            print(
                "refusing: %s fingerprint does not match what GitHub publishes.\n"
                "          computed  %s\n"
                "          published %s" % (algorithm, computed, expected),
                file=sys.stderr,
            )
            return 1
        lines.append("github.com %s" % entry)

    if not lines:
        print("refusing: no recognised host key types were pinned", file=sys.stderr)
        return 1

    with open(out_path, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("  %d host key(s) matched GitHub's published fingerprints" % len(lines))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
