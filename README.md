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
