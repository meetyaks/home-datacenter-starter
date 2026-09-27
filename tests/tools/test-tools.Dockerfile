# Throwaway Linux toolbox for the runner tests that need real Linux behaviour
# (runuser, /proc, network namespaces, nftables). Built locally by the test
# drivers, labelled for exact cleanup; never pushed.
FROM ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ansible-core procps jq nftables iproute2 python3 netcat-openbsd util-linux bsdutils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
