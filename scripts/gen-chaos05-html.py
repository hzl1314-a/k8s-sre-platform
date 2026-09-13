# -*- coding: utf-8 -*-
"""生成演练二（w2 硬关机）合成图 chaos-05：时间线 + 可用性窗口条。
数据源：docs/chaos-drill2-timeline.log + docs/probe-drill2.log（脚本内为逐字摘录）。
用法：python gen-chaos05-html.py  →  docs/screenshots/tmp-chaos05.html
"""
import io, os

OUT = os.path.join(os.path.dirname(__file__), '..', 'docs', 'screenshots', 'tmp-chaos05.html')

EVENTS = [
    ('01:40:54', 'T+75s',  '流量消失（Traefik 双副本均在 w2，随节点断电）', 'bad'),
    ('01:41:26', 'T+103s', '节点 w2 转 NotReady',                          'warn'),
    ('01:42:49', 'T+186s', 'NodeNotReady 双通道投递（email+webhook +1）',  'ok'),
    ('01:46:28', 'T+406s', 'taint 驱逐：10 个 w2 Pod → Terminating',       'warn'),
    ('01:46:30', 'T+409s', '替补 Pod 在 w1 批量 Running',                  'ok'),
    ('01:47:14', 'T+454s', '探针恢复 200（中断 6m18s）',                   'ok'),
    ('01:48:51', 'T+551s', 'w2 重新 Ready（开机后 ~80s）',                 'ok'),
    ('01:49:12', 'T+569s', 'RESOLVED 恢复通知投递（email 8→12, webhook 2）','ok'),
]

# 探针可用性窗口条：[开始, 结束, 状态]（局部坐标秒，t0=01:39:40）
BARS = [
    (13,   74,  'ok'),    # 01:39:53-01:40:54 正常
    (74,   454, 'bad'),   # 01:40:54-01:47:14 中断（329×000 + 1×502）
    (454,  473, 'ok'),    # 01:47:14-01:47:33 恢复
    (473,  475, 'warn'),  # 01:47:33-35 抖动 3s
    (475,  594, 'ok'),    # 01:47:35-01:49:34
    (594,  596, 'warn'),  # 01:49:34 单次 5s 超时（w2 重入 endpoints 抖动）
    (596,  653, 'ok'),    # 至 01:50:33 观测窗末
]

COLOR = {'ok': '#2e7d32', 'warn': '#f9a825', 'bad': '#c62828'}

SCALE = 2.2  # px per second
rows = ''.join(
    f'<tr><td class="t">{t}</td><td class="r">{r}</td><td class="m {c}">{m}</td></tr>'
    for t, r, m, c in EVENTS)

bar_svg = ''.join(
    f'<rect x="{int(a*SCALE)}" y="8" width="{max(3,int((b-a)*SCALE))}" height="30" fill="{COLOR[s]}"/>'
    for a, b, s in BARS)

html = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body {{ font-family: 'Microsoft YaHei', sans-serif; background: #fff; margin: 24px; width: 1132px; }}
h2 {{ font-size: 20px; margin: 0 0 4px; }}
.sub {{ color: #555; font-size: 12px; margin-bottom: 14px; }}
table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
td, th {{ border: 1px solid #ddd; padding: 5px 9px; text-align: left; }}
th {{ background: #f0f2f5; }}
.t, .r {{ white-space: nowrap; font-family: Consolas, monospace; }}
.bad {{ color: #c62828; font-weight: bold; }}
.warn {{ color: #b26a00; }}
.ok {{ color: #2e7d32; }}
.bar {{ margin: 16px 0 4px; }}
.legend {{ font-size: 12px; color: #555; margin-bottom: 12px; }}
.box {{ background: #fff8e1; border-left: 4px solid #f9a825; padding: 8px 12px; font-size: 13px; margin-top: 14px; line-height: 1.6; }}
</style></head><body>
<h2>演练二：k8s-w2 断电（普通关机）· 时间线与可用性</h2>
<div class="sub">2026-09-14 01:39-01:50 · 数据源：chaos-drill2-timeline.log（2s 轮询）+ probe-drill2.log（460 请求）· T0 = 01:39:40</div>
<table><tr><th>时刻</th><th>T+</th><th>事件</th></tr>{rows}</table>
<div class="bar"><svg width="1132" height="46" xmlns="http://www.w3.org/2000/svg">
<rect x="0" y="8" width="{int(653*SCALE)}" height="30" fill="#eceff1"/>{bar_svg}
<text x="0" y="46" font-size="11" fill="#555">01:39</text>
<text x="{int(300*SCALE)}" y="46" font-size="11" fill="#555">01:44</text>
<text x="{int(600*SCALE)}" y="46" font-size="11" fill="#555">01:50</text></svg></div>
<div class="legend">■ 正常（130×200）　■ 短抖动　■ 中断（329×000 + 1×502）　整体可用率 28.3%，最长连续中断 6m18s（01:40:54→01:47:12）</div>
<div class="box"><b>根因与改进项：</b>Traefik 两副本均落在 w2（Deployment 无反亲和，drain 替补也未回流），
节点断电导致<b>入口层全灭</b>——业务 Pod 在 w1 存活但流量无法进入。改进：Traefik 增加 podAntiAffinity、
副本跨工作节点打散； ingress 层纳入与业务层同级的「双副本必须跨节点」检查清单。</div>
</body></html>"""

io.open(OUT, 'w', encoding='utf-8', newline='\n').write(html)
print('written', os.path.abspath(OUT))
