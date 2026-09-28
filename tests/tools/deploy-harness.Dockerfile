# Linux harness for roles/truewealth deploy tests: Docker CLI + Compose (talks
# to the local engine through its socket), Ansible and the host tools the role
# uses (ss, getent, flock, age). Built locally, labelled, never pushed.
FROM docker@sha256:851f91d241214e7c6db86513b270d58776379aacc5eb9c4a87e5b47115e3065c
RUN apk add --no-cache ansible-core bash python3 iproute2 git shadow ca-certificates util-linux \
      coreutils rsync age curl musl-utils findutils procps jq
