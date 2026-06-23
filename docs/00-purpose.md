To simulate a real-world production environment where a website (project-x.local) is served to internal users. All traffic must be routed securely, databases isolated, logs aggregated, and system health visualized in real-time. Every configuration change must be traceable and automated.

Key Success Criteria:

Zero hard-coded IPs (DNS resolves all internal communication).

Centralized logging (No tail -f on individual boxes).

Automated monitoring alerts (Disk, CPU, HTTP status).

All services restart automatically after reboot.