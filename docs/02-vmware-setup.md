# Server Roles & VMware Specifications (Ubuntu 26.04)

**Part of:** Multi-Tiered Linux Environment  
**Related:** [Main Architecture](../00-architecture.md) | [Network Design](04-network-design-security.md)

## Virtual Machine Summary

| Server ID | Hostname                | Role                               | Ubuntu Edition | vCPU | RAM  | Disk | VMware Network   | Logical VLAN |
| :-------- | :---------------------- | :--------------------------------- | :------------- | :--- | :--- | :--- | :--------------- | :----------- |
| **1**     | `dns.infra.lab`         | Internal DNS & nameserver          | 26.04 Server   | 1    | 1 GB | 20GB | Host‑Only (trunk) | 20 (Infra)   |
| **2**     | `db.infra.lab`          | Relational database                | 26.04 Server   | 2    | 4 GB | 40GB | Host‑Only (trunk) | 20 (Infra)   |
| **3**     | `web.dmz.lab`           | Application server                 | 26.04 Server   | 2    | 2 GB | 30GB | Host‑Only (trunk) | 30 (DMZ)     |
| **4**     | `proxy.dmz.lab`         | Reverse proxy / load balancer      | 26.04 Server   | 1    | 1 GB | 20GB | Host‑Only (trunk) | 30 (DMZ)     |
| **5**     | `logs.infra.lab`        | Centralised logging (Loki stack)   | 26.04 Server   | 2    | 2 GB | 50GB | Host‑Only (trunk) | 20 (Infra)   |
| **6**     | `monitor.infra.lab`     | Metrics & alerting                 | 26.04 Server   | 2    | 2 GB | 40GB | Host‑Only (trunk) | 20 (Infra)   |
| **7**     | `admin.infra.lab`       | Admin jump host & orchestration    | **26.04 Desktop** | 2    | 4 GB | 60GB | Host‑Only (trunk) | 10 (Mgmt)    |
| **8**     | `router.infra.lab`      | **Router, DHCP & NAT gateway**     | 26.04 Server   | 1    | 1 GB | 20GB | Host‑Only + **Bridged** | Trunk + WAN |

## VMware Virtual Network Editor Setup

1. **Host‑Only (VMnet1)** – Subnet `10.0.0.0/24` (disable built‑in DHCP).  
   - Connect **all 8 VMs** to this network.  
   - This is our **VLAN trunk** link.  

2. **Bridged (VMnet0)** – Connect **only `router.infra.lab`** to this network.  
   - Provides internet access (via your host’s physical NIC).  

> **Why this works:** The router server will tag/untag 802.1Q frames on the Host‑Only interface. The other servers will create VLAN sub‑interfaces to place themselves into the correct logical broadcast domain.

## OS Installation Notes

- **Servers 1–6 & 8:** Ubuntu 26.04 LTS **Server** – minimal installation + OpenSSH.  
- **Server 7 (Admin):** Ubuntu 26.04 LTS **Desktop** – for GUI tools and local development.  
- **Static IPs** are assigned inside the guest OS via **VLAN sub‑interfaces** (not on the physical `eth0`). The physical `eth0` will have **no IP** (or a dummy IP) to avoid confusion.