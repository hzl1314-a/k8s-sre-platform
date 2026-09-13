#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只读稳态复验：确认 Traefik 滚动更新收敛后的最终副本分布。"""
import sys
import datetime
import paramiko

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect('8.155.129.89', username='root', password=sys.argv[1], timeout=15,
            look_for_keys=False, allow_agent=False)

cmds = [
    ("rollout status", "kubectl -n traefik rollout status deploy/traefik --timeout=60s"),
    ("最终副本分布", "kubectl -n traefik get pods -o wide"),
    ("探活", "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:30080/"),
]
results = []
for title, cmd in cmds:
    _, out, err = ssh.exec_command(cmd, timeout=70)
    rc = out.channel.recv_exit_status()
    text = out.read().decode('utf-8', 'replace').strip()
    results.append(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] === {title} (rc={rc}) ===\n{text}")
    print(results[-1], flush=True)
ssh.close()

with open('docs/traefik-affinity-fix.log', 'a', encoding='utf-8', newline='\n') as f:
    f.write("\n--- 稳态复验（追加） ---\n" + "\n\n".join(results) + "\n")
print("已追加到 docs/traefik-affinity-fix.log")
