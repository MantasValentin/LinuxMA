# 01 — Architecture

## Node inventory (13 VMs)

| # | Hostname | Role | IP | Redundancy pair |
|---|---|---|---|---|
| 1 | `firewall` | Perimeter: WAN NIC, NAT, DNAT to proxy — the real default gateway | 10.0.0.1 | — (see note) |
| 2 | `dhcp` | DHCP server | 10.0.0.9 | — |
| 3 | `admin` | Ansible controller | 10.0.0.10 | — |
| 4 | `dns1` / `ns1` | Authoritative primary DNS for `lab.local` (no recursion) | 10.0.0.20 | `dns2` |
| 5 | `dns2` / `ns2` | Authoritative secondary DNS (AXFR from dns1, no recursion) | 10.0.0.21 | `dns1` |
| 6 | `dns-rslv1` | Recursive/caching resolver for the whole LAN | 10.0.0.53 | — |
| 7 | `logs` | ELK stack (log aggregation) | 10.0.0.30 | — |
| 8 | `analytics` | Grafana + metrics stack (monitoring) | 10.0.0.31 | — |
| 9 | `db1` | PostgreSQL primary | 10.0.0.40 | `db2` |
| 10 | `db2` | PostgreSQL streaming replica | 10.0.0.41 | `db1` |
| 11 | `proxy` | Reverse proxy / TLS termination | 10.0.0.60 | — |
| 12 | `app1` | Application node | 10.0.0.70 | `app2`, `app3` reserved for scale-out |

**Router/firewall split, and why the addressing looks the way it does:** `router` keeps the historic `.1` address for continuity, but after this split it no longer has a WAN interface, does no NAT, and forwards nothing — its only job is running `dnsmasq` as a DHCP server. The box that actually connects to the internet, does NAT/masquerade, and DNATs inbound 80/443 to the proxy is `firewall` (`.2`). DHCP hands clients `firewall` (`.2`) as their gateway and `dns-rslv` (`.53`) as their DNS server — **not** `router`. This is a deliberate call made while documenting the split (see `03-network-design.md`); flag it if you intended `router` to still be in the forwarding path.

**Note on firewall/proxy redundancy:** both remain single instances — same stated limitation as before (one VMware host, one uplink). VRRP/keepalived across a pair would be the production fix.

## DNS split, and why

Previously `dns1`/`dns2` did double duty: authoritative for `lab.local` *and* the LAN's recursive resolver (forwarding to `1.1.1.1`/`8.8.8.8`). That's now split:

- `dns1`/`dns2` are **authoritative only** — `recursion no;` in `named.conf.options`. They answer for `lab.local` and its reverse zone and nothing else, exactly the way you'd want a real authoritative pair to behave (an authoritative server that also recurses for the public is an open-resolver risk in a real deployment; splitting these out demonstrates knowing why that separation matters, not just how to configure BIND).
- `dns-rslv` is a **caching-only forwarder** — not authoritative for anything, holds no zone files. It forwards `lab.local` (and its reverse zone) specifically to `dns1`/`dns2` via a `type forward` zone stanza, and forwards everything else to `8.8.8.8`/`1.1.1.1` via the global `forwarders` block.
- DHCP now hands out `dns-rslv` (`.53`) as the DNS server for every LAN client, including `dns1`/`dns2` themselves — an authoritative server's own OS-level resolution (apt, etc.) goes through `dns-rslv` too, since it no longer recurses locally.

## Topology

```
                              Internet / Upstream
                                     │
                                     │ NIC_E (WAN)
                              ┌──────┴───────┐
                              │   firewall    │  10.0.0.2  <- real default gateway
                              │  nftables NAT │
                              │  DNAT 80/443  │
                              └──────┬────────┘
                                     │ NIC_I (LAN)   10.0.0.0/24
                                     │  flat, single broadcast domain
     ┌──────────┬────────────┬──────┴────┬────────────┬────────────┬────────────┐
     │          │            │           │            │            │            │
┌────┴───┐ ┌────┴───┐  ┌─────┴──┐  ┌─────┴───┐  ┌─────┴──┐   ┌─────┴───┐  ┌─────┴───┐
│ router │ │ admin  │  │ dns1   │  │ dns2    │  │dns-rslv│   │  logs   │  │analytics│
│  .1    │ │  .10   │  │.20 ns1 │◄─┤.21 ns2  │  │  .53   │   │  .30    │  │  .31    │
│ DHCP   │ │Ansible │  │ author.│  │ (AXFR)  │  │forwards│   │ ELK     │  │ Grafana │
│ only   │ │        │  │no recur│  │no recur │  │lab<->  │   └────▲────┘  └────▲────┘
└────────┘ └────────┘  └────────┘  └─────────┘  │public  │        │ metrics/logs   │
                                                └────────┘        └────────────────┘
                                             ┌────┴────┐
                                             │  proxy  │  .60
                                             └────┬────┘
                                                  │
                                             ┌────┴────┐
                                             │  app1   │  .70
                                             └────┬────┘
                                                  │
                                        ┌─────────┴─────────┐
                                        │   db1 (.40) primary │
                                        │  streaming replication
                                        │   db2 (.41) replica  │
                                        └──────────────────────┘
```

All 12 nodes remain on the same flat `10.0.0.0/24` — the router/firewall/resolver split is about separating *responsibilities* onto dedicated hosts, not about introducing new subnets (still no VLAN capability, see `03-network-design.md`).

## Design principles (updated)

1. **Every host firewalls itself** — unchanged from before; still the substitute for VLAN-based isolation.
2. **Single points get named, not hidden.** `firewall` and `proxy` remain single instances; documented as a known gap, not silently accepted.
3. **One ingress path, now clearly at the true edge.** `firewall` is the only node with a WAN-reachable interface; it DNATs 80/443 to `proxy` and nothing else is reachable from WAN — the same rule as before, just enforced on the box that's actually positioned to enforce it.
4. **Separation of duties, demonstrated even without needing it.** On a single flat subnet, splitting DHCP (`router`), perimeter/NAT (`firewall`), and recursive DNS (`dns-rslv`) into three boxes isn't strictly required by the topology — it's done deliberately to demonstrate that each function is understood and can be operated independently, the same reasoning as splitting authoritative DNS from recursive DNS.
5. **Centralized observability, config management from one controller** — unchanged.

## Data flow (representative request)

1. Client on the internet requests `https://app.example` -> resolves via public DNS to `firewall`'s WAN IP.
2. `firewall` DNATs 443 -> `proxy` (10.0.0.60) only.
3. `proxy` terminates TLS, resolves internal names via `dns-rslv` (which forwards `lab.local` lookups to `dns1`/`dns2`), forwards to `app1` (10.0.0.70).
4. `app1` queries `db1` (10.0.0.40); `db1` streams WAL to `db2`.
5. `app1` and `proxy` ship logs to `logs` (ELK) and metrics to `analytics` (Grafana/Prometheus).
6. Any LAN client's DHCP lease comes from `router` (`.1`), pointing them at `firewall` (`.2`) as gateway and `dns-rslv` (`.53`) as DNS.
7. Administrative changes originate from `admin` via Ansible over SSH to each node's `ansible` account.

## What's still open (tracked, not hidden)

- `firewall`/`proxy` HA (VRRP or a load-balanced pair) — deferred, single-host lab limitation.
- Secrets management beyond file permissions — planned for the Ansible doc.
- TLS certificate issuance/rotation on the proxy — planned for the reverse-proxy doc.
- `admin`'s own inbound access path (console vs. VPN) — see `03-network-design.md` open items.