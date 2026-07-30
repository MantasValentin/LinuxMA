# 03 — Network Design

## IP addressing scheme

| Range | Tier | Hosts |
|---|---|---|
| `10.0.0.1` | Firewall Primary | `firewall1` |
| `10.0.0.2` | Firewall Secondary | `firewall2` |
| `10.0.0.3` | DHCP | `dhcp` |
| `10.0.0.4` | IdM OpenIPA Primary | `ipa1` |
| `10.0.0.5` | IdM OpenIPA Secondary | `ipa2` |
| `10.0.0.6` | Authoritative DNS Primary | `dns1` |
| `10.0.0.7` | Authoritative DNS Secondary | `dns2` |
| `10.0.0.20–29` | Management | `admin` (`.20`) |
| `10.0.0.30–39` | Observability | `logs` (`.30`), `analytics` (`.31`) |
| `10.0.0.40–49` | Database | `db1` (`.40`), `db2` (`.41`) |
| `10.0.0.53-54` | Recursive DNS resolver Primary | `dns-rslv1` |
| `10.0.0.53-54` | Recursive DNS resolver Secondary | `dns-rslv2` |
| `10.0.0.60–69` | Proxy | `proxy` (`.60`) |
| `10.0.0.70–99` | Application | `app1` (`.70`) |
| `10.0.0.100–200` | DHCP pool | Dynamic clients |

**`10.0.0.1-10.0.0.19`** are reserved for infrastructure

## DNS design

- **Domain:** `lab.local`, purely internal.
- **Authority:** `dns1` (`ns1`) is primary for the forward zone (`lab.local`) and reverse zone (`0.0.10.in-addr.arpa`). `dns2` (`ns2`) is secondary for both, pulling zone data via AXFR authenticated with a TSIG key.
- **Zone transfer security:** `allow-transfer` is restricted to `key xfer-key` only, so a secondary has to present the shared secret.
- **No recursion on the authoritative pair.** `dns1`/`dns2` set `recursion no;` — they answer only for zones they're authoritative for, restricted to `localhost` and `10.0.0.0/24`. They do not resolve anything outside `lab.local` for LAN clients.
- **Recursion lives on `dns-rslv` instead.** It's a caching-only forwarder, not authoritative for anything: `lab.local` and its reverse zone are forwarded specifically to `dns1`/`dns2`, and everything else is forwarded to `8.8.8.8`/`1.1.1.1`. DHCP hands This to every LAN client. This includes `dns1`/`dns2` themselves for their own resolution, since they can no longer resolve external names locally.

## Firewall model

Every host follows the same basic structure: default-drop `input`, explicit accepts, default-accept `output`. The differences are which service ports each host accepts and from where.

| Host | Accepts | From |
|---|---|---|
| `firewall1` / `firewall2` | SSH 22 | management range |
| | Forward: LAN→WAN | LAN interface |
| | Forward: WAN→`proxy` 80/443 only | WAN interface |
| `dhcp` | SSH 22 | management range |
| | DHCP 67 (server) | LAN interface |
| `dns1` / `dns2` | SSH 22 | management range |
| | DNS 53 tcp/udp | `10.0.0.0/24` |
| `dns-rslv1` / `dns-rslv2` | SSH 22 | management range |
| | DNS 53 tcp/udp | `10.0.0.0/24` |
| `admin` | Outgoing | admin servers only allow outgoing connections including logs and analitics |
| `db1` / `db2` | SSH 22 | management range |
| | PostgreSQL 5432 | app tier (`10.0.0.70-99`) and peer DB for replication |
| `proxy` | SSH 22 | management range |
| | HTTP/HTTPS 80/443 | intended public entry point |
| `app1` (+scale-out) | SSH 22 | management range |
| | HTTP/HTTPS 80/443 | `proxy` only |
| `logs` | SSH 22 | management range |
| | Beats/Logstash intake 5044 | `10.0.0.0/24` |
| | Kibana 5601 | management range |
| `analytics` | SSH 22 | management range |
| | Prometheus scrape / exporter ports | `10.0.0.0/24` |
| | Grafana 3000 | management range |

## Management access pattern

- SSH is only accepted from range `10.0.0.10-19` on every node from `admin` servers.
- `admin` runs the Ansible controller and holds the only private key for the `ansible` service account.
- No human user logs in as `ansible`; it exists solely for Ansible's own SSH transport.

## Future design considerations for this layer

- **Egress filtering.** `output` policy is currently accept-all on every host, best to allow only for expected outgoing traffic.
- **`admin` inbound configuration.** Right now `admin` is isolated from incoming traffic but could be configured for vpn access to allow for remote control, this would require configuration on the firewall.
- **`firewall`/`proxy` are single points of failure** but the fix is out of scope for a VMware lab.