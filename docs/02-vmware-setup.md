# 02 — VMware Setup

## Hypervisor

This lab is built on a single VMware host on Vmware Workstation. One physical host. One internal network. One external network. Using Ubuntu Server/Desktop 26.04 LTS as the OS.

## Networks in VMware

| VMware network | Type | Purpose | Maps to |
|---|---|---|---|
| `VMnet-WAN` | Bridged | Uplink to the internet/host network | `firewall`'s `NIC_E` |
| `VMnet-LAN` | Host-only | The internal 10.0.0.0/24 lab network | Every VM's `NIC_I` |

**`firewall` is the only VM with access to both networks in the lab.**

## Why one flat network instead of VLANs

VLAN trunking isn't available in VMware Workstation. Virtual switches don't do 802.1Q tagging with some exceptions. So design the LAN as one flat network and put the segmentation logic on each host's firewall.

## Per-VM resource allocation

| Hostname | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| `firewall` | 2 | 4 GB | 20 GB | **Two NICs** (WAN + LAN) |
| `dhcp` | 1 | 4 GB | 20 GB | DHCP |
| `dns1` | 1 | 4 GB | 20 GB | Primary authoritative only dns |
| `dns2` | 1 | 4 GB | 20 GB | secondary to `dns1` |
| `dns-rslv` | 1 | 4 GB | 20 GB | caching resolver, no zone files |
| `admin` | 1 | 4 GB | 30 GB | Holds Ansible repo/playbooks |
| `db1` | 4 | 8 GB | 40 GB | PostgreSQL primary |
| `db2` | 4 | 8 GB | 40 GB | Replica, mirror `db1`'s sizing |
| `proxy` | 2 | 4 GB | 20 GB | Nginx |
| `app1` (+ app2/app3) | 1-4 | 4-8 GB | 20-30 GB | Sized to app needs |
| `logs` | 2 | 4 GB | 40 GB | Elasticsearch |
| `analytics` | 2 | 4 GB | 40 GB | Grafana + Prometheus/exporters |

Databases, apps, proxy, firewall, logs, analytics are the main ones for considering changes as they are the most affected by network size and user quantity.

## Base install process

1. Create the VM per the template above. **For `firewall` only**, add the second NIC before first boot (WAN + LAN). Every other VM gets a single NIC on the LAN network.
2. Install Ubuntu Server 26.04 LTS minimal, set user as sysadmin, OpenSSH enabled.
3. On boot confirm DHCP-assigned connectivity, `ssh` working, then run the set up script for that server.

   **Bring-up order matters**, because of the resolution dependency chain:
   - Bring up `firewall` first (it needs to be reachable for anything else to get outbound internet access).
   - Bring up `dns-rslv` next, everything points its DNS at `.53`.
   - Bring up `dhcp` (DHCP now hands out `firewall` as gateway and `dns-rslv` as DNS — both need to already exist for new DHCP clients to get a fully working lease).
   - Bring up `dns1`/`dns2` next.
   - Everything else (`admin`, `db1/db2`, `proxy`, `app1`, `logs`, `analytics`) can come up in any order after that, using static IPs and pointing at `firewall`/`dns-rslv`.

4. After the set up script deploys the static IP, reconnect on the new address.
5. Run `ansible_client.sh`, `ssh-copy-id` from `admin`, then lock the account (`passwd -l ansible`).
6. Snapshot once the node is confirmed working and reachable via Ansible.

## Snapshots

Two snapshots
- First: post base install. 
- Second: post set up script once the service is confirmed working.