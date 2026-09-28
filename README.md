# Home Datacenter Bootstrap

This repository configures the primary Ubuntu server (`dc1-x86`) from the Mac
management account. It deliberately stops before deploying databases or
applications.

## What it changes

- Verifies `/srv/data` is a mounted filesystem before using it.
- Installs basic operating and diagnostic tools.
- Enables unattended security updates.
- Installs Docker Engine from Docker's official Ubuntu APT repository.
- Installs the Buildx and Compose plugins.
- Limits Docker JSON logs to five 10 MB files per container.
- Adds `labadmin` to the `docker` group.
- Creates the service directory structure.

It does **not** configure a firewall, publish ports, install Kubernetes, deploy
applications, or store secrets.

## Prerequisites

On the Mac management account:

```bash
brew install ansible git
```

The Ubuntu server must already have:

- hostname or DNS/Tailscale name `dc1-x86` (otherwise edit `ansible_host`);
- user `labadmin` with sudo access;
- SSH key `~/.ssh/home_datacenter_admin` authorized for `labadmin`;
- `/srv/data` mounted from the dedicated logical volume.

## First run

If `dc1-x86` does not resolve from the Mac, edit `inventory/hosts.yml` and
replace `dc1-x86` under `ansible_host` with the reserved LAN or Tailscale IP.

```bash
cd home-datacenter-starter
ansible-galaxy collection install -r requirements.yml
ansible all -m ping
ansible-playbook playbooks/site.yml --syntax-check
ansible-playbook playbooks/site.yml --ask-become-pass
```

The first run installs Docker and may take several minutes. The playbook does
not reboot the server.

Log out and reconnect so the new Docker group membership takes effect:

```bash
ssh dc1-x86
docker version
docker compose version
docker run --rm hello-world
```

## Prove repeatability

Run the same playbook again:

```bash
ansible-playbook playbooks/site.yml --ask-become-pass
```

The second run should report no unexpected changes. Package metadata refreshes
can appear as successful tasks without changing the host.

## Verify the host

```bash
ssh dc1-x86
findmnt /srv/data
df -h / /srv/data
systemctl is-enabled docker
systemctl is-active docker
docker info --format '{{json .DriverStatus}}'
docker info --format '{{.LoggingDriver}}'
```

The next milestone is a private core Compose stack containing PostgreSQL,
Redis, Caddy and Uptime Kuma, with persistent data bind-mounted beneath
`/srv/data`.

## Continuous integration on dc1-x86

`playbooks/ci-runner.yml` provisions a **self-hosted GitHub Actions runner for
`meetyaks/keel`** in a dedicated LXD virtual machine (`dc1-ci-1`) on the same
host — with no path to the production Keel deployment that shares it.

```bash
ansible-playbook playbooks/ci-runner.yml --ask-become-pass            # provision
read -rs CI_RUNNER_TOKEN && export CI_RUNNER_TOKEN                   # token: never argv/history
ansible-playbook playbooks/ci-runner.yml --tags register \
  --ask-become-pass; unset CI_RUNNER_TOKEN                            # register
tests/run-ci-runner-isolation.sh                                      # verify
```

It is deliberately **not** part of `site.yml`: an ordinary site run manages
production, and must not also build or alter a machine whose job is to run
whatever a workflow tells it to. Registration, removal and rebuild are
`never`-tagged, so none of them can happen as a side effect.

The threat model, the ownership boundary, what the egress policy does and does
not promise, and why ephemeral registration is off are in
[roles/ci_runner/README.md](roles/ci_runner/README.md).
