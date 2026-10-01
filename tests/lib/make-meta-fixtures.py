#!/usr/bin/env python3
"""Build api.github.com/meta fixtures for tests/run-known-hosts-pin.sh.

    make-meta-fixtures.py <output-directory>

⚠️ GENERATED, NOT A SNAPSHOT OF GITHUB'S REAL DOCUMENT. A committed copy of
real host keys goes stale the day GitHub rotates one, and the suite then
fails for a reason that is not a defect. These are throwaway keys made here,
with fingerprints computed the same way OpenSSH computes them — so the
"good" document is self-consistent by construction, and each bad one is
wrong in exactly one way.

Nothing here is a credential: the private halves are discarded immediately
and the public halves authenticate nothing.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile


def generate_public_key(kind: str, tmpdir: str) -> str:
    """One throwaway keypair, returned in authorized_keys form."""
    path = os.path.join(tmpdir, kind.replace("-", "_"))
    algorithm = {"ssh-ed25519": "ed25519", "ssh-rsa": "rsa"}[kind]
    subprocess.run(
        ["ssh-keygen", "-t", algorithm, "-N", "", "-C", "fixture", "-f", path, "-q"]
        + (["-b", "2048"] if algorithm == "rsa" else []),
        check=True,
    )
    with open(path + ".pub") as handle:
        parts = handle.read().split()
    return "%s %s" % (parts[0], parts[1])


def fingerprint(entry: str) -> str:
    return (
        base64.b64encode(hashlib.sha256(base64.b64decode(entry.split()[1])).digest())
        .decode()
        .rstrip("=")
    )


def flip(blob: str) -> str:
    """Change one byte of a key, keeping it valid base64 of the same length."""
    raw = bytearray(base64.b64decode(blob))
    raw[-1] ^= 0xFF
    return base64.b64encode(bytes(raw)).decode()


def main(outdir: str) -> int:
    os.makedirs(outdir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmpdir:
        ed = generate_public_key("ssh-ed25519", tmpdir)
        rsa = generate_public_key("ssh-rsa", tmpdir)

    def document(keys, fingerprints):
        return {"ssh_keys": keys, "ssh_key_fingerprints": fingerprints}

    good = document(
        [ed, rsa],
        {"SHA256_ED25519": fingerprint(ed), "SHA256_RSA": fingerprint(rsa)},
    )

    # The key material is changed; the published fingerprint still describes
    # the ORIGINAL key. This is what an intercepted or substituted document
    # looks like, and it is the case the whole check exists for.
    kind, blob = ed.split()
    tampered_key = document(
        ["%s %s" % (kind, flip(blob)), rsa],
        {"SHA256_ED25519": fingerprint(ed), "SHA256_RSA": fingerprint(rsa)},
    )

    # The mirror image: the key is genuine, the fingerprint beside it is not.
    tampered_fingerprint = document(
        [ed, rsa],
        {"SHA256_ED25519": fingerprint(rsa), "SHA256_RSA": fingerprint(rsa)},
    )

    fixtures = {
        "good.json": good,
        "tampered-key.json": tampered_key,
        "tampered-fingerprint.json": tampered_fingerprint,
        # An empty list must not quietly produce an empty known_hosts: the
        # next ssh would fail with "Host key verification failed", pointing
        # at the wrong cause.
        "no-keys.json": document([], {"SHA256_ED25519": fingerprint(ed)}),
        # Keys with nothing to check them against is the same as no check.
        "no-fingerprints.json": document([ed, rsa], {}),
        "malformed.json": document(
            ["ssh-ed25519"], {"SHA256_ED25519": fingerprint(ed)}
        ),
    }

    for name, body in fixtures.items():
        with open(os.path.join(outdir, name), "w") as handle:
            json.dump(body, handle, indent=2)

    print("  built %d meta fixtures in %s" % (len(fixtures), outdir))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
