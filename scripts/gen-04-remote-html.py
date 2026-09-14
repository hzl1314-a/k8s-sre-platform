#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""04-remote-kubectl.png 生成器（合成图先例：13/17/18/chaos-01/05）。

读取 docs/screenshots/04-source.log（真实执行记录），渲染成终端风格 HTML，
再由无头 Chrome 截图输出 docs/screenshots/04-remote-kubectl.png。
命令与输出逐字取自日志，不手写、不美化数据。"""
import io
import html
import re
import subprocess

BASE = r"E:\yes\k8s-sre-platform"
LOG = BASE + r"\docs\screenshots\04-source.log"
HTML = BASE + r"\docs\screenshots\04-remote-kubectl.html"
PNG = BASE + r"\docs\screenshots\04-remote-kubectl.png"
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"

raw = io.open(LOG, encoding="utf-8").read()
# 逐字保留命令与输出；跳过注释头，去掉 kubectl 的 E0 噪声行（本次执行曾出现，最终版无）
body_lines = []
for line in raw.splitlines():
    if line.startswith("#"):
        continue
    if line.startswith("PS E:\\>"):
        body_lines.append(f'<span class="prompt">{html.escape(line)}</span>')
    else:
        body_lines.append(html.escape(line))
body = "\n".join(body_lines)

page = f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><style>
  body {{ margin:0; background:#0c0c0c; font-family:Consolas,'Courier New',monospace; }}
  .win {{ width:1350px; }}
  .titlebar {{
    background:#2d2d2d; padding:6px 12px; color:#ccc; font-size:13px;
    font-family:'Segoe UI',sans-serif; display:flex; align-items:center;
  }}
  .titlebar .dot {{ width:12px; height:12px; border-radius:50%; margin-right:6px; }}
  .pre {{
    color:#cccccc; font-size:13.5px; line-height:1.42; padding:14px 18px 20px;
    white-space:pre; overflow:hidden;
  }}
  .prompt {{ color:#16c60c; font-weight:bold; }}
</style></head><body>
<div class="win">
  <div class="titlebar">
    <span class="dot" style="background:#e5744a"></span>
    <span class="dot" style="background:#e5c44a"></span>
    <span class="dot" style="background:#57c04f"></span>
    &nbsp; Windows PowerShell —— 本机 kubectl over SSH 隧道（127.0.0.1:6443 → cp:6443，6443 未暴露公网）
  </div>
  <div class="pre">{body}</div>
</div>
</body></html>"""

io.open(HTML, "w", encoding="utf-8").write(page)

r = subprocess.run([
    CHROME, "--headless=new", "--disable-gpu", "--no-proxy-server",
    "--force-device-scale-factor=2",
    f"--screenshot={PNG}", "--window-size=1350,720",
    "file:///" + HTML.replace("\\", "/"),
], capture_output=True, text=True, timeout=60)
print(r.stdout[-200:] if r.stdout else "", r.stderr[-200:] if r.stderr else "")
print("done ->", PNG)
