# 00 — Purpose

## What this is

A self-built, self-hosted microservices infrastructure lab, run as a set of Ubuntu 26.04 LTS virtual machines under VMware, designed and documented to demonstrate hands-on Linux systems administration and small-network architecture skills: routing/NAT, authoritative + recursive DNS with secondary zone transfer, host-based firewalling with nftables, reverse proxying, a primary/replica PostgreSQL database, centralized log aggregation (ELK), centralized monitoring (Grafana), and configuration management (Ansible) — all built from first principles rather than from managed cloud services.

## Why it exists

This lab is a portfolio artifact. The goal is to show, with real configuration and real documentation rather than a resume bullet, that I can:

- Design a small network topology and justify the design decisions (addressing, segmentation, redundancy, blast radius).
- Stand up and harden individual Linux services (DNS, firewall, database, proxy, log/metrics pipelines) rather than only consuming them as managed products.
- Apply consistent security practices across a fleet: least-privilege firewall rules, key-based SSH, a dedicated automation account, secrets handling (TSIG keys, DB credentials).
- Document infrastructure the way a team would need it documented to operate and hand it off — not just "commands I ran once."

## Goals

- **Reproducibility.** Every VM can be rebuilt from the scripts and documentation in this repo without guessing at missing steps.
- **Realistic redundancy on a budget.** No VLAN-capable switch is available (this runs on a single VMware host), so redundancy and segmentation are achieved through software (firewall zones, replica services) instead of hardware/network segmentation.
- **Operational clarity.** Anyone reading the docs should be able to answer: what talks to what, over which port, why, and what happens if a given node dies.
- **Realistic constraints, not a toy.** Services are configured the way they'd need to be configured to survive a review: TSIG-authenticated zone transfers, restricted `allow-recursion`/`allow-query`, DNAT only to the intended backend, SSH restricted to a management range, a locked-out automation user after key deployment.

## Non-goals

- **High availability at the infrastructure layer.** There is one VMware host and one flat L2 network — this lab demonstrates service-level redundancy (secondary DNS, DB replica) not hypervisor/network HA.
- **Production-grade secrets management.** TSIG keys and DB passwords are handled carefully for a lab (correct file permissions, ownership, not committed in plaintext to any public repo) but this is not Vault/KMS-backed.
- **Internet-facing production hardening.** The router NATs and DNATs traffic as a demonstration of the pattern; it is not intended to be exposed to the public internet as-is.
- **VLAN-based segmentation.** Called out explicitly because it's the most common "why didn't you do X" question — see `03-network-design.md` for the reasoning.

## Technology choices at a glance

| Concern | Choice | Why |
|---|---|---|
| OS | Ubuntu 26.04 LTS (server) | Common enterprise Linux baseline, long support window, systemd + NetworkManager stack matches most shops |
| DNS | BIND9 (primary + secondary, TSIG AXFR) | Industry-standard authoritative/recursive resolver; demonstrates zone transfer security, not just `dnsmasq` |
| Firewall | nftables | Current standard replacing iptables; used on every node, not just the router |
| Routing/NAT/DHCP (edge) | dnsmasq + nftables NAT | Lightweight edge services for a single-uplink lab router |
| Database | PostgreSQL, primary + streaming replica | Widely used OSS RDBMS; demonstrates streaming replication, not just a single instance |
| Reverse proxy | Nginx (or similar) | Standard L7 entry point, TLS termination, routing to app tier |
| Logging | ELK (Elasticsearch, Logstash, Kibana) — referred to as "ELK" in these docs, the user's original notes said "EKL" | Centralized log aggregation and search |
| Monitoring | Grafana (+ Prometheus/exporters) | Centralized metrics and dashboards |
| Config management | Ansible, dedicated `ansible` service account | Demonstrates a repeatable, key-only automation pattern instead of manual SSH-and-hope |

## Document map

- `00-purpose.md` — this document.
- `01-architecture.md` — logical architecture: roles, topology, redundancy model, data flow.
- `02-vmware-setup.md` — per-VM specs, VMware networking setup, base OS install process.
- `03-network-design.md` — IP addressing, DNS zone design, firewall zone model, port matrix.
- (Planned) `04-dns.md`, `05-database.md`, `06-reverse-proxy.md`, `07-logging-elk.md`, `08-monitoring-grafana.md`, `09-ansible.md` — per-service build and hardening notes, one per stack component.