# Logging & monitoring agents for the lab

This project only handles the **agent side**: getting every server in the
`monitored` group shipping logs to `logs.lab.internal` (ELK) and exposing
metrics to `analytics.lab.internal` (Prometheus/Grafana). It assumes
`logging_server.sh` and `analytics_server.sh` have already been run once on
those two boxes to stand up the central stack.

## Layout

```
ansible/
├── ansible.cfg                       # remote_user=ansible, your ed25519 key, become=true
├── inventory/
│   └── hosts.ini                     # your inventory, unchanged
├── group_vars/
│   ├── all.yml                       # python interpreter
│   └── monitored.yml                 # logstash host/port, prometheus scrape source, node_exporter version/port
├── roles/
│   ├── filebeat/                     # installs + configures Filebeat, ships journald -> logstash:5044
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   ├── templates/filebeat.yml.j2
│   │   └── defaults/main.yml
│   ├── node_exporter/                # installs node_exporter, opens 9100 to analytics box only
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml
│   │   ├── templates/node_exporter.service.j2
│   │   └── defaults/main.yml
│   └── prometheus_targets/           # (runs on analytics_server) regenerates the file_sd target list from inventory
│       ├── tasks/main.yml
│       └── templates/node_exporters.yml.j2
└── playbooks/
    ├── site.yml                      # everything: filebeat -> node_exporter -> refresh targets
    ├── logging.yml                   # just filebeat, for a quick re-run
    └── monitoring.yml                # just node_exporter + target refresh
```

## What each role does

- **filebeat** - trusts the same Elastic 8.x repo your `logging_server.sh`
  already uses, installs `filebeat`, points it at
  `logs.lab.internal:5044` via `output.logstash`, and tags every event with
  the host's inventory group (`firewalls`, `dns`, `ipa`, ...) so you can
  filter by role in Kibana. Ships journald by default since that covers
  every Rocky box uniformly - add per-role log paths later if a service
  writes outside the journal.

- **node_exporter** - downloads the pinned release from GitHub (mirrors how
  `analytics_server.sh` installs Prometheus itself), runs it as a
  `node_exporter` system user on port 9100, and inserts an nftables rule
  scoped to just `10.0.0.31` / `fd00:10::31` (the analytics box) so the
  metrics port isn't open to the whole LAN.

- **prometheus_targets** - runs only against `analytics_server` and
  regenerates `/etc/prometheus/targets/node_exporters.yml` from
  `groups['monitored']` in the inventory. This is the piece the comment in
  your `analytics_server.sh` was pointing at - add a host to `hosts.ini`,
  re-run the playbook, and Prometheus picks it up within 30s (its
  `file_sd_configs.refresh_interval`) with no restart.

## One important assumption

The `node_exporter` role inserts its firewall rule with
`insertbefore: "^    chain forward"` in `/etc/sysconfig/nftables.conf`.
That matches the structure of both `logging_server.sh` and
`analytics_server.sh`. If your bootstrap scripts for `firewalls`, `dhcp`,
`ipa`, `dns`, `admin`, `database`, `proxy`, or `apps` build their nftables
config with a different layout, that anchor line needs to match theirs too
- otherwise the blockinfile insert will fail on those hosts. Worth checking
before your first full run.

## Running it

```bash
cd ansible
ansible-playbook playbooks/site.yml
```

Or narrower:

```bash
ansible-playbook playbooks/logging.yml       # just filebeat
ansible-playbook playbooks/monitoring.yml    # just node_exporter + target refresh
```

## Not covered here (possible next steps)

- Converting `logging_server.sh` / `analytics_server.sh` themselves into
  Ansible roles for idempotent re-runs (right now they're one-shot bash).
- SELinux booleans/labels if any of the other host types run SELinux in
  enforcing mode with policies that block filebeat/node_exporter - the two
  provided scripts only label ports for Elasticsearch/Kibana/Logstash and
  Prometheus/Grafana, not for the agents.
- TLS between Filebeat and Logstash, and between Prometheus and
  node_exporter - both are currently plaintext, fine for an internal lab
  VLAN but worth flagging.
