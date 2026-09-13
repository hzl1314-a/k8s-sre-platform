# 生成截图 17/18 的合成图 HTML（数据逐字取自真实日志，先例：截图 13）
# 用法: python gen-hpa-shot-html.py  ->  输出两个 HTML 到 screenshots/tmp/
import html, io, os

OUT = r'E:/yes/k8s-sre-platform/docs/screenshots/tmp'
os.makedirs(OUT, exist_ok=True)

CSS = """
body { margin:0; background:#1e1e1e; font-family:'Cascadia Mono','Consolas',monospace; }
.term { padding:18px 22px; color:#d4d4d4; font-size:14px; line-height:1.55; white-space:pre; }
.prompt { color:#16c60c; } .path { color:#3b8eea; } .dim { color:#8a8a8a; }
.hl { color:#f9f1a5; } .ok { color:#16c60c; } .warn { color:#e5c07b; } .key { color:#4ec9b0; }
.note { margin:0; padding:10px 22px 16px; color:#8a8a8a; font-size:12px;
        border-top:1px solid #333; font-family:'Consolas',monospace; white-space:normal; }
"""

frames = [
    ("00:39:39", "cpu: 10%/60%", "2", "静息基线（hey 未启动）"),
    ("00:40:17", "cpu: 77%",     "2", "负载打入 37 秒，CPU 逼近阈值"),
    ("00:40:36", "cpu: 80%",     "3", "★ 扩容触发 2 → 3（越过 60% 目标）"),
    ("00:43:35", "cpu: 55%",     "3", "3 副本分摊后回到阈值下（HPA 求衡点）"),
    ("00:45:21", "cpu: 7%",      "3", "hey 5 分钟窗口结束，负载归零"),
    ("00:50:12", "cpu: 11%",     "2", "★ 缩容 3 → 2（300s 稳定窗口到期）"),
]

rows = []
for t, cpu, rep, note in frames:
    star = ' ★' if '★' in note else ''
    hl = ' class="hl"' if star else ''
    rows.append(
        f'<span class="dim">── [{t}] {html.escape(note)}</span>\n'
        f'<span class="prompt">root@k8s-cp</span>:<span class="path">~</span># watch -n 2 \'date +%T; kubectl get hpa -n boutique\'\n'
        f'<span class="dim">Every 2.0s: kubectl get hpa -n boutique                                              k8s-cp: {t}</span>\n'
        f'NAME<span class="dim">           </span>REFERENCE<span class="dim">             </span>TARGETS<span class="dim">        </span>MINPODS   MAXPODS   REPLICAS   AGE\n'
        f'frontend-hpa   Deployment/frontend   <span{hl}>cpu: {cpu.replace("cpu: ","")}</span>   2         8         <span{hl}>{rep}</span>          30m\n\n'
    )

promo = """<span class="key">■ Prometheus 交叉验证（query_range, step=15s）</span>
kube_horizontalpodautoscaler_status_current_replicas{namespace="boutique"}
  00:41:00 → 3   <span class="dim">（日志 00:40:36 触发，采样差 1 步）</span>
  00:50:30 → 2   <span class="dim">（日志 00:50:12 触发，采样差 1 步）</span>
<span class="ok">两路独立观测一致 ✓</span>"""

html17 = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{CSS}</style></head>
<body><div class="term">
<span class="dim">╔══ 任务 8 · HPA 扩缩容全周期（压测 hey -z 5m -c 50 → frontend）══╗</span>
{''.join(rows)}
{promo}
</div>
<div class="note">合成图说明：时间与数值逐字取自 docs/hpa-drill-timeline.log（drill 脚本每 3s 轮询 kubectl + jsonpath），
并用 Prometheus API 独立复核；终端样式为排版重构。合成先例：截图 13。</div>
</body></html>"""

hey_text = html.escape(io.open(r'E:/yes/k8s-sre-platform/docs/hpa-hey-result.txt', encoding='utf-8').read().strip())
# 高亮关键行
hey_text = hey_text.replace('Total:\t301.1481 secs', '<span class="hl">Total:\t301.1481 secs</span>')
hey_text = hey_text.replace('Requests/sec:\t24.6590', '<span class="hl">Requests/sec:\t24.6590</span>')
hey_text = hey_text.replace('[200]\t7426 responses', '<span class="ok">[200]\t7426 responses</span>')
hey_text = hey_text.replace('99% in 2.7775 secs', '<span class="hl">99% in 2.7775 secs</span>')
hey_text = hey_text.replace('00:39:53', '<span class="prompt">00:39:53</span>  <span class="dim">← hey 启动</span>')
hey_text = hey_text.replace('00:44:54', '<span class="prompt">00:44:54</span>  <span class="dim">← hey 退出（5m 窗口自然结束）</span>')
hey_text = hey_text.replace('Summary:', '<span class="key">Summary:</span>')
hey_text = hey_text.replace('Status code distribution:', '<span class="key">Status code distribution:</span>')

html18 = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>{CSS}</style></head>
<body><div class="term">
<span class="dim">╔══ 任务 8 · hey 压测报告（cp 节点，打 127.0.0.1:30080 走 NodePort→Traefik→frontend 全链路）══╗</span>
<span class="prompt">root@k8s-cp</span>:<span class="path">~</span># date +%T; ~/go/bin/hey -z 5m -c 50 http://127.0.0.1:30080/; date +%T

{hey_text}
</div>
<div class="note">合成图说明：内容逐字取自 docs/hpa-hey-result.txt（hey v0.1.4 原始输出，drill 脚本自动回传），
仅做排版着色与时间标注。合成先例：截图 13。零错误：7426/7426 全部 200。</div>
</body></html>"""

io.open(os.path.join(OUT, 'shot17.html'), 'w', encoding='utf-8').write(html17)
io.open(os.path.join(OUT, 'shot18.html'), 'w', encoding='utf-8').write(html18)
print('written:', OUT)
