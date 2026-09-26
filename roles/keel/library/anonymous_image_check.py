#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Verify container images are anonymously pullable, FROM THE MANAGED HOST."""

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: anonymous_image_check
short_description: Check images are anonymously resolvable by digest for linux/amd64
description:
  - Speaks the registry HTTP API directly from the managed host, with no
    credentials and without consulting the local image cache, to establish that
    each pinned reference can actually be fetched by anyone right now.
  - Read-only. Makes no durable filesystem change and returns changed=false, so
    it runs identically in check mode.
options:
  images:
    description:
      - Image references, each pinned by digest.
      - Passed as a LIST through Ansible's JSON module protocol. No reference is
        ever interpreted as shell.
    type: list
    elements: str
    required: true
  expected_host:
    description:
      - The inventory hostname this is meant to run on. When set, the module
        fails unless it actually ran there.
    type: str
    required: false
  forbidden_host:
    description:
      - A hostname this must NOT run on, normally the controller's.
      - Catches delegation even when the inventory name and the target's real
        hostname happen to differ, which C(expected_host) alone would report as
        an ordinary mismatch.
    type: str
    required: false
  retries:
    description:
      - Bounded retries for transport errors, 429 and 5xx only.
      - 401, 403 and 404 are the registry's answer, not a hiccup, and are never
        retried.
      - Four attempts with a 2/4/6-second backoff, so a DNS or connection blip
        lasting a few seconds does not fail a deploy. Observed in practice, a
        run reported "nodename nor servname provided" for a host that resolved
        in two milliseconds moments later.
    type: int
    default: 4
  timeout:
    description: Per-request timeout in seconds.
    type: int
    default: 30
author:
  - Keel lab deployment
"""

EXAMPLES = r"""
- name: Confirm every external image is anonymously pullable from this host
  anonymous_image_check:
    images: "{{ keel_external_images.stdout_lines }}"
    expected_host: "{{ inventory_hostname }}"
  register: keel_anon_pull
"""

RETURN = r"""
verified_count:
  description: Number of images that passed every check.
  type: int
  returned: always
input_count:
  description: Number of images supplied.
  type: int
  returned: always
execution_host:
  description: Hostname of the machine that actually issued the registry requests.
  type: str
  returned: always
host_matches:
  description: Whether execution_host corresponds to expected_host.
  type: bool
  returned: always
results:
  description: Per-image structured result.
  type: list
  returned: always
"""

import re
import socket

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.six.moves.urllib.error import HTTPError, URLError
from ansible.module_utils.six.moves.urllib.request import Request, urlopen

# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS IS A MODULE AND NOT A SCRIPT
#
# The check it performs has to happen ON THE DEPLOYMENT HOST. The incident that
# created it was host-path-specific: one machine could resolve an image while
# dc1-x86 got 401. Running it anywhere else tests the wrong DNS, the wrong
# routes, the wrong proxy, the wrong TLS trust store and the wrong source
# address for whatever the registry decides about.
#
# An earlier version passed the image list into a shell command string. The list
# was newline-separated, so the shell received it as a PROGRAM: one reference
# was checked and the other four were executed as commands. A module takes its
# arguments as JSON, so a reference is data and there is no shell anywhere in
# this file — no subprocess, no os.system, nothing that could interpret one.
#
# It is also read-only by construction: it opens sockets and returns facts. It
# writes nothing, so check mode needs no special handling and gets the same
# answer a real run would.
# ─────────────────────────────────────────────────────────────────────────────

ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)

INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)

# A registry reference is opaque, but it is not arbitrary. Anything outside this
# set is REJECTED AS DATA and never fetched: if a space or a metacharacter
# reaches here, something upstream is passing shell text rather than a list, and
# the right response is to say so rather than to try it.
REF_ALLOWED = re.compile(r"^[A-Za-z0-9._:/@+-]+$")

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

# Retried: the registry did not give us an answer we can trust.
# NOT retried: 401/403/404 are answers.
RETRYABLE_STATUS = (429,)


def _split_reference(ref):
    """Split a reference into (registry, repository, digest).

    Tags are stripped BEFORE the registry is identified. Removing only the
    digest leaves `repo:TAG` as the repository path and every lookup 404s; and
    for `nats:2-alpine@...` the first path component would then contain a colon
    and be mistaken for a registry host. Only a colon AFTER the last slash is a
    tag — a colon before one is a port, so `localhost:5000/app:v1@sha256:...`
    has to survive intact.
    """
    digest = ref.rsplit("@", 1)[1]
    before_at = ref.rsplit("@", 1)[0]

    head, sep, last = before_at.rpartition("/")
    if ":" in last:
        last = last.rsplit(":", 1)[0]
    before_at = head + sep + last

    first = before_at.split("/", 1)[0]
    if "." in first or ":" in first:
        registry = first
        repository = before_at.split("/", 1)[1]
    else:
        registry = "registry-1.docker.io"
        repository = before_at if "/" in before_at else "library/" + before_at

    return registry, repository, digest


def _request(module, url, headers=None, method="GET"):
    """One HTTP request. Returns (status, headers, body_bytes, error_text).

    No credentials are ever attached: no auth handler is installed and no
    netrc is consulted, so a 200 here is a statement about the registry rather
    than about this host's stored logins.
    """
    req = Request(url, headers=headers or {})
    req.get_method = lambda: method
    try:
        resp = urlopen(req, timeout=module.params["timeout"])
        body = resp.read() if method != "HEAD" else b""
        return resp.getcode(), dict(resp.headers.items()), body, None
    except HTTPError as exc:
        try:
            body = exc.read()
        except Exception:
            body = b""
        return exc.code, dict(exc.headers.items() if exc.headers else {}), body, None
    except URLError as exc:
        return 0, {}, b"", "transport error: %s" % (exc.reason,)
    except socket.timeout:
        return 0, {}, b"", "timed out after %ss" % (module.params["timeout"],)
    except Exception as exc:  # pragma: no cover - defensive
        return 0, {}, b"", "unexpected error: %s" % (exc,)


def _request_with_retry(module, url, headers=None, method="GET"):
    """Bounded retry for transport errors, 429 and 5xx. Never for 401/403/404."""
    attempts = max(1, int(module.params["retries"]))
    last = (0, {}, b"", "no attempt made")
    for attempt in range(attempts):
        status, hdrs, body, err = _request(module, url, headers, method)
        last = (status, hdrs, body, err)
        transient = status == 0 or status in RETRYABLE_STATUS or 500 <= status <= 599
        if not transient:
            return last
        if attempt < attempts - 1:
            # Short, bounded backoff. A dropped connection says nothing about
            # whether an image is pullable; one of them must not fail a deploy.
            import time

            time.sleep(2 * (attempt + 1))
    return last


def _anonymous_token(module, registry, repository):
    """Fetch an anonymous pull token, using whatever the registry's 401 asks for.

    Retried like any other request. A token fetch that fails transiently is NOT
    an authorization answer, but it looks exactly like one downstream: without a
    token the manifest request comes back 401, which this module deliberately
    never retries. That combination made the check report a spurious failure on
    a perfectly public image — measured: with a token the manifest is 200, with
    no token it is 401, on the same image seconds apart.
    """
    status, hdrs, _body, _err = _request_with_retry(
        module, "https://%s/v2/" % registry, method="GET"
    )
    challenge = ""
    for key, value in hdrs.items():
        if key.lower() == "www-authenticate":
            challenge = value
            break
    if not challenge:
        return None

    realm = re.search(r'realm="([^"]+)"', challenge)
    service = re.search(r'service="([^"]+)"', challenge)
    if not realm:
        return None

    url = "%s?scope=repository:%s:pull" % (realm.group(1), repository)
    if service:
        url += "&service=%s" % (service.group(1),)

    status, _hdrs, body, _err = _request_with_retry(module, url, method="GET")
    if status != 200 or not body:
        return None
    try:
        import json

        payload = json.loads(body.decode("utf-8"))
    except Exception:
        return None
    return payload.get("token") or payload.get("access_token") or None


def _check_one(module, ref):
    """Run every check against one reference. Returns a structured result."""
    out = {
        "image": ref,
        "ok": False,
        "registry": None,
        "manifest_status": None,
        "digest_matches": None,
        "amd64": None,
        "layer_status": None,
        "reason": None,
    }

    if not REF_ALLOWED.match(ref or ""):
        out["reason"] = (
            "invalid reference: contains whitespace or shell metacharacters. "
            "Rejected as data and never fetched — the caller is passing shell "
            "text rather than a list."
        )
        return out

    if "@" not in ref:
        out["reason"] = "not pinned by digest"
        return out

    registry, repository, digest = _split_reference(ref)
    out["registry"] = registry

    if not DIGEST_RE.match(digest):
        out["reason"] = "malformed digest %r" % (digest,)
        return out

    token = _anonymous_token(module, registry, repository)
    headers = {"Accept": ACCEPT}
    if token:
        headers["Authorization"] = "Bearer %s" % (token,)

    manifest_url = "https://%s/v2/%s/manifests/%s" % (registry, repository, digest)

    # 1. Does the digest resolve, anonymously?
    status, hdrs, _body, err = _request_with_retry(module, manifest_url, headers, "HEAD")

    # ⚠️ A 401 WE REACHED WITHOUT A TOKEN IS NOT AN ANSWER. It means the token
    # fetch failed, and the registry is simply telling us we are unauthenticated
    # — which we are. Genuine refusals (we presented a token and were still
    # rejected) are never retried, but this case must be, or a transient blip
    # during token acquisition is reported as "the registry refuses this
    # repository" and blocks a deploy over a public image.
    if status in (401, 403) and not token:
        token = _anonymous_token(module, registry, repository)
        if token:
            headers["Authorization"] = "Bearer %s" % (token,)
            status, hdrs, _body, err = _request_with_retry(
                module, manifest_url, headers, "HEAD"
            )

    out["manifest_status"] = status
    if status != 200:
        detail = {
            401: "the registry refuses this repository to clients without credentials",
            403: "the registry forbids anonymous access to this repository",
            404: "the manifest is gone from this registry",
            429: "rate limited — distinct from a refusal",
            0: "no HTTP response at all; check the network path from this host",
        }.get(status, "")
        out["reason"] = "anonymous manifest HEAD returned HTTP %s from %s%s%s" % (
            status,
            registry,
            " — " + detail if detail else "",
            " (%s)" % err if err else "",
        )
        return out

    # 2. Is it the digest we pinned?
    served = None
    for key, value in hdrs.items():
        if key.lower() == "docker-content-digest":
            served = value.strip()
            break
    if served and served != digest:
        out["digest_matches"] = False
        out["reason"] = "registry served %s, not the pinned %s" % (served, digest)
        return out
    out["digest_matches"] = True

    # 3. Does it carry linux/amd64?
    #
    # PARSED, NOT MATCHED ON SUBSTRINGS. An index lists each platform as an
    # entry whose own mediaType is `...image.manifest...`, so a substring test
    # matches INSIDE a multi-platform index and skips the check entirely.
    status, _hdrs, body, err = _request_with_retry(module, manifest_url, headers, "GET")
    if status != 200:
        out["reason"] = "could not read the manifest body (HTTP %s)" % (status,)
        return out
    try:
        import json

        manifest = json.loads(body.decode("utf-8"))
    except Exception as exc:
        out["reason"] = "could not parse the manifest: %s" % (exc,)
        return out

    media_type = manifest.get("mediaType", "")
    if media_type not in INDEX_TYPES and "manifests" not in manifest:
        out["amd64"] = False
        out["reason"] = (
            "single-platform manifest (%s); linux/amd64 cannot be confirmed "
            "from the manifest alone" % (media_type or "unknown media type",)
        )
        return out

    submanifest = None
    platforms = []
    for entry in manifest.get("manifests") or []:
        plat = entry.get("platform") or {}
        if plat.get("architecture"):
            platforms.append("%s/%s" % (plat.get("os"), plat.get("architecture")))
        if plat.get("architecture") == "amd64" and plat.get("os") == "linux":
            submanifest = entry.get("digest")

    if not submanifest:
        out["amd64"] = False
        out["reason"] = "index has no linux/amd64 entry (only: %s)" % (
            ",".join(sorted(set(platforms))) or "none",
        )
        return out
    out["amd64"] = True

    # 4. Can a LAYER be fetched, not just the manifest?
    #
    # A manifest is metadata. A registry can serve it and refuse the layers, and
    # then a pull fails on an image this just called fine.
    sub_url = "https://%s/v2/%s/manifests/%s" % (registry, repository, submanifest)
    status, _hdrs, body, err = _request_with_retry(module, sub_url, headers, "GET")
    if status != 200:
        out["reason"] = "could not read the linux/amd64 manifest (HTTP %s)" % (status,)
        return out
    try:
        import json

        sub = json.loads(body.decode("utf-8"))
    except Exception as exc:
        out["reason"] = "could not parse the linux/amd64 manifest: %s" % (exc,)
        return out

    layers = sub.get("layers") or []
    if not layers:
        out["reason"] = "the linux/amd64 manifest lists no layers"
        return out

    blob_url = "https://%s/v2/%s/blobs/%s" % (registry, repository, layers[0]["digest"])
    status, _hdrs, _body, err = _request_with_retry(module, blob_url, headers, "HEAD")
    out["layer_status"] = status
    if status not in (200, 307):
        out["reason"] = (
            "manifest is served but its layers are not (blob HEAD HTTP %s); a "
            "pull would fail on an image whose metadata looks fine" % (status,)
        )
        return out

    out["ok"] = True
    return out


def main():
    module = AnsibleModule(
        argument_spec=dict(
            images=dict(type="list", elements="str", required=True),
            expected_host=dict(type="str", required=False, default=None),
            forbidden_host=dict(type="str", required=False, default=None),
            retries=dict(type="int", default=4),
            timeout=dict(type="int", default=30),
        ),
        # Read-only: it opens sockets and returns facts, writing nothing. So
        # check mode gets the same answer a real run would, which is the point
        # of a preflight.
        supports_check_mode=True,
    )

    images = module.params["images"]
    expected = module.params["expected_host"]
    forbidden = module.params["forbidden_host"]

    execution_host = socket.gethostname()
    short_exec = execution_host.split(".")[0].lower()

    host_matches = True
    if expected:
        host_matches = short_exec == expected.split(".")[0].lower()

    ran_on_forbidden_host = bool(
        forbidden and short_exec == forbidden.split(".")[0].lower()
    )

    results = [_check_one(module, ref) for ref in images]
    verified = sum(1 for r in results if r["ok"])

    payload = dict(
        changed=False,
        images=images,
        results=results,
        verified_count=verified,
        input_count=len(images),
        execution_host=execution_host,
        expected_host=expected,
        host_matches=host_matches,
        forbidden_host=forbidden,
        ran_on_forbidden_host=ran_on_forbidden_host,
    )

    # Checked before anything else: if this ran on the controller, the result is
    # about the wrong machine and nothing else it says is worth reading.
    if ran_on_forbidden_host:
        module.fail_json(
            msg="ran on %s, which is the controller. Registry access is "
            "host-specific, so this says nothing about the deployment host. "
            "Remove the delegation from the calling task." % (execution_host,),
            **payload
        )

    if not images:
        module.fail_json(
            msg="no images supplied — a check over zero images is how a broken "
            "caller hides; refusing to report success",
            **payload
        )

    # ⚠️ A RESULT FROM THE WRONG MACHINE IS NOT A RESULT.
    #
    # The incident this module exists for was host-path-specific: another
    # machine could resolve an image while the deployment host got 401. So a
    # green answer computed somewhere else is worse than no answer — it is the
    # exact false assurance that let a broken deploy start. The module refuses
    # here rather than leaving it to the caller to remember to check, because
    # the caller forgetting is how this went wrong the first time.
    if expected and not host_matches:
        module.fail_json(
            msg="ran on %s but was expected to run on %s. Registry access is "
            "host-specific — DNS, routing, proxies, TLS trust and the source "
            "address the registry sees all differ — so this result says nothing "
            "about the deployment host and must not be reported as a pass. "
            "Remove any delegation from the calling task."
            % (execution_host, expected),
            **payload
        )

    if verified != len(images):
        failed = [r for r in results if not r["ok"]]
        module.fail_json(
            msg="verified %d of %d from %s — %d image(s) are not anonymously "
            "pullable as pinned: %s"
            % (
                verified,
                len(images),
                execution_host,
                len(failed),
                "; ".join("%s: %s" % (r["image"], r["reason"]) for r in failed),
            ),
            **payload
        )

    module.exit_json(
        msg="verified %d of %d from %s" % (verified, len(images), execution_host),
        **payload
    )


if __name__ == "__main__":
    main()
