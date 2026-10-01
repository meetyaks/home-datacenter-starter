# First-party MinIO images

`ghcr.io/meetyaks/minio` and `ghcr.io/meetyaks/minio-mc`, built from upstream
source at pinned commits by
[`.github/workflows/publish-minio-images.yml`](../../.github/workflows/publish-minio-images.yml).

## Why these exist

The lab stack pinned the upstream images by digest. They stopped being pullable
mid-deployment:

```
HEAD https://quay.io/v2/minio/minio/manifests/sha256:7d80fd23… → 401
```

The withdrawal is total, and it is not about us:

| source | state |
|---|---|
| `docker.io/minio/minio`, `minio/mc` | Docker Hub API: `object not found` |
| `quay.io/minio/minio`, `minio/mc` | `401` to anonymous clients — while `minio/operator`, `minio/console` and every unrelated public repository answer `200` from the same client at the same moment |
| `mirror.gcr.io`, `public.ecr.aws` | not found |
| `dl.min.io` binaries | **HTTP 410 GONE**, including `latest` |

`410` is not `404`: every published binary and image was deliberately removed,
for all releases, not only the ones pinned here. No credential, network path or
digest on our side is involved.

**The source is still public**, so these images are *built*, not mirrored. That
distinction matters — there is nothing left to mirror, for any architecture.

## What is built

| image | upstream | release | source commit |
|---|---|---|---|
| `ghcr.io/meetyaks/minio` | [minio/minio](https://github.com/minio/minio) | `RELEASE.2024-09-22T00-33-43Z` | `03e996320ebb887112fb2a15c6f27936e5f124a0` |
| `ghcr.io/meetyaks/minio-mc` | [minio/mc](https://github.com/minio/mc) | `RELEASE.2024-09-16T17-43-14Z` | `11ebe952ea30e426e564f66e78d178465ae7c432` |

Same releases as before — nothing was upgraded to work around the withdrawal.

Those commits are **independently corroborated**: while the upstream images
were still pullable, they reported exactly these values at runtime —
`minio version RELEASE.2024-09-22T00-33-43Z (commit-id=03e996320ebb…)` and
`mc version RELEASE.2024-09-16T17-43-14Z (commit-id=11ebe952ea30…)`. So this
rebuilds the releases that were withdrawn, rather than something that merely
shares a version string.

The server image also carries `mc`, as the upstream image did: the stack's
healthcheck is `mc ready local`, which runs inside that container.

## Tags

Only the upstream release and the source commit:

```
ghcr.io/meetyaks/minio:RELEASE.2024-09-22T00-33-43Z
ghcr.io/meetyaks/minio:src-03e996320ebb887112fb2a15c6f27936e5f124a0
```

**Never `latest`.** A tag that can quietly start meaning different code is the
hazard this whole exercise exists to answer. The deployment pins the digest
regardless; the tags are for humans.

## Reproducibility

- **Base images pinned by digest** — builder and runtime both, in
  [`allowlist.json`](allowlist.json) and as `ARG` defaults in each Dockerfile.
- **Toolchain pinned** — Go 1.22, matching each release's `go.mod`.
- **The final stage downloads nothing.** Every file in it is `COPY --from` an
  earlier stage, including the CA bundle, which comes from the builder rather
  than an `apk add`.
- **Source arrives at a commit, never at a tag**, through the build context.
- **`-trimpath`** so local build paths do not enter the binary.
- **Recorded per build**: upstream tag, source commit, the build invocation
  (run URL) and the produced digest — in the job summary, in the image labels,
  and in `/licenses/CORRESPONDING_SOURCE.txt` inside the image.

### The allowlist is a gate, not documentation

A git tag is mutable: it can be deleted and recreated against different code.
The workflow resolves the tag at build time and **refuses to build** unless it
dereferences to the commit committed here, then re-checks the checked-out tree.
"We built the tag" is a weaker claim than it sounds; this makes the build assert
the commit rather than trust it.

## Licence compliance

Both programs are **AGPL-3.0-or-later**. These are unmodified upstream sources
built as-is; no patches are applied.

The basis on which the redistribution obligations are met:

1. **The complete corresponding source is public and identified exactly** — the
   upstream repositories at the commits above, which anyone can fetch.
2. **The scripts controlling compilation are public** — the Dockerfiles and the
   workflow in this repository, which is public. AGPL §1 counts these as part
   of the corresponding source, which is why the build recipe lives in a public
   repository rather than a private one.
3. **Licence and notices travel with the artifact** — each image carries the
   upstream `LICENSE` under `/licenses`, plus
   `/licenses/CORRESPONDING_SOURCE.txt` naming the upstream repository, the
   commit, this recipe and the build run.
4. **Image metadata states it** — `org.opencontainers.image.licenses`,
   `.revision` and `.url` on every image.
5. **Network use is covered by the same pointers.** AGPL §13 concerns users
   interacting remotely; the offer of corresponding source is the upstream
   repository at the stated commit, recorded inside the image itself.

> This documents the compliance **basis**. It is not legal advice and not a
> claim that anyone has given legal approval. If these images are ever exposed
> beyond this lab, have the position reviewed by someone qualified — in
> particular AGPL §13, which is the clause that bites on network services.

## Rebuilding

The workflow runs on `workflow_dispatch`, or on a push touching
`images/minio/**` or the workflow file. It authenticates with the job's own
`GITHUB_TOKEN` scoped by `permissions: packages: write`; **no personal access
token is used or needed**, and no credential is ever placed on a deployment
host.
