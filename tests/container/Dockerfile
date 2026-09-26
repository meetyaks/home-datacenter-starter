# Disposable Linux host for the runtime-group scenarios.
#
# The four group states and the two real runs cannot be exercised on the control
# node: creating and colliding system groups needs root on a throwaway machine,
# and dc1-x86 is not one. A container is.
#
# ansible-core only — no collections are needed; the role uses builtin modules.
FROM python:3.12-slim-bookworm

RUN pip install --no-cache-dir 'ansible-core>=2.16,<2.19'

# `getent`, `groupadd` and friends. The scenarios set up real NSS state.
RUN apt-get update \
    && apt-get install -y --no-install-recommends passwd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
