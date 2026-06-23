# Network Design & Security (VLAN-over-Host-Only)

**Part of:** Multi-Tiered Linux Environment  
**Related:** [Server Roles](03-server-roles-vmware-specs.md) | [IP Plan](06-ip-addressing-plan.md)

## Physical VMware Networks

| VMware Network | Purpose                      | Subnet (physical) | Connected VMs          |
| -------------- | ---------------------------- | ----------------- | ---------------------- |
| **Host‑Only**  | 802.1Q **Trunk** link        | 10.0.0.0/24       | All 8 VMs              |
| **Bridged**    | WAN / Internet uplink        | DHCP from host    | `router.infra.lab` only |

## Logical VLANs (802.1Q tagging)

| VLAN ID | Name         | Subnet        | Gateway (Router) | Servers                       |
| :------ | :----------- | :------------ | :--------------- | :---------------------------- |
| **10**  | Management   | 10.0.10.0/24  | 10.0.10.1        | `admin.infra.lab` (Server 7)  |
| **20**  | Infra        | 10.0.20.0/24  | 10.0.20.1        | `dns`, `db`, `logs`, `monitor`|
| **30**  | DMZ          | 10.0.30.0/24  | 10.0.30.1        | `web`, `proxy`                |

> All routing between VLANs is performed by **Server 8** (`router.infra.lab`).

## Security & Firewall Zones

- **Default policy:** Deny all inter‑VLAN traffic **except** where explicitly required.
- **Required allowed flows (on the router, using `iptables`):**
  - `VLAN 30 (DMZ)` → `VLAN 20 (Infra)` : only `web.dmz.lab` (10.0.30.10) to `db.infra.lab` (10.0.20.11) on port 5432.
  - `VLAN 10 (Mgmt)` → `VLAN 20/30` : only `admin.infra.lab` (10.0.10.10) to **port 22** on all servers (Ansible/SSH).
  - `VLAN 20 (Infra)` → `VLAN 30 (DMZ)` : only `monitor.infra.lab` (10.0.20.13) to port 9100 (Node Exporter) and 3100 (Loki) on DMZ servers.
- **Internet access (NAT):**
  - Only `router.infra.lab` reaches the internet via Bridged.
  - All other servers use `router.infra.lab` (10.0.10.1, 10.0.20.1, 10.0.30.1) as their default gateway.  
  - The router performs **MASQUERADE** to forward their traffic out over the Bridged interface.

## Router Configuration (Server 8) – Overview

- **Physical NICs:**
  - `ens160` – Bridged (WAN) – gets IP via DHCP from your home router.
  - `ens192` – Host‑Only (Trunk) – **no IP assigned** to the parent interface.
- **VLAN sub‑interfaces (on `ens192`):**
  - `ens192.10` – IP `10.0.10.1/24`
  - `ens192.20` – IP `10.0.20.1/24`
  - `ens192.30` – IP `10.0.30.1/24`
- **Enable IP forwarding:** `net.ipv4.ip_forward=1`
- **DHCP server:** `isc-dhcp-server` bound to `ens192.10`, `ens192.20`, `ens192.30` to hand out static leases.

## Client VLAN Configuration (Servers 1–7)

On each server, the physical `ens160` (attached to Host‑Only) has **no IP**. Instead, create a sub‑interface:

```bash
# Example for Server 1 (DNS, VLAN 20)
sudo ip link add link ens160 name ens160.20 type vlan id 20
sudo ip addr add 10.0.20.10/24 dev ens160.20
sudo ip link set ens160.20 up
sudo ip route add default via 10.0.20.1