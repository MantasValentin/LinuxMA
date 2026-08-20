```bash
cd ansible
ansible-playbook playbooks/site.yml
```

```bash
ansible-playbook playbooks/logging.yml       # just filebeat
ansible-playbook playbooks/monitoring.yml    # just node_exporter + target refresh
```