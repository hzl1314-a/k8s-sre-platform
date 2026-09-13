# chaos-01 合成图：演练一（drain w1）Pod 漂移 + 可用性统计
# 数据源: docs/chaos-drill1-timeline.log + docs/probe-drill1.log（逐字，先例同截图 13/17）
import io, os

OUT = r'E:/yes/k8s-sre-platform/docs/screenshots'
os.makedirs(OUT, exist_ok=True)

CSS = """
body { margin:0; background:#1e1e1e; font-family:'Cascadia Mono','Consolas',monospace; }
.term { padding:18px 22px; color:#d4d4d4; font-size:14px; line-height:1.55; white-space:pre; }
.prompt { color:#16c60c; } .path { color:#3b8eea; } .dim { color:#8a8a8a; }
.hl { color:#f9f1a5; } .ok { color:#16c60c; } .warn { color:#e5c07b; } .key { color:#4ec9b0; } .bad { color:#e06c75; }
.note { margin:0; padding:10px 22px 16px; color:#8a8a8a; font-size:12px;
        border-top:1px solid #333; white-space:normal; }
"""

L = []
a = L.append
a('<span class="dim">╔══ 演练一 · 优雅排水 k8s-w1（模拟计划内维护）══╗</span>')
a('<span class="prompt">root@k8s-cp</span>:<span class="path">~</span># kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data   <span class="dim"># 01:15:01 = T+0s</span>')
a('')
a('<span class="key">── Pod 漂移时间线（2s 轮询，取自 chaos-drill1-timeline.log）──</span>')
a('T+2s   8 个 w1 Pod 进入 Terminating，节点转 Ready,SchedulingDisabled')
a('T+4s   首批替补在 w2/cp 进入 ContainerCreating（adservice / checkout / redis-cart…）')
a('T+6s   <span class="ok">frontend 替补 frontend-58c745c7-nkzch Running</span>（原 vf752 已驱逐）')
a('T+9s   10 个被驱逐服务中 8 个已有 Running 替补')
a('T+11s  <span class="hl">w1 清空（10 pod evicted），drain 返回 —— 排水全程 11s</span>')
a('T+12s  kubectl uncordon k8s-w1')
a('<span class="dim">T+24s~ 节点 Ready 可调度；无 Pod 迁回 w1（K8s 无自动 rebalance，预期行为）</span>')
a('')
a('<span class="key">── 可用性探针（每秒 1 次 → 127.0.0.1:30080，600s 窗口）──</span>')
a('总请求 309 | <span class="ok">200 × 306</span> | <span class="bad">000 × 2，500 × 1</span> | <span class="hl">可用率 99.03%</span>')
a('异常全部集中在驱逐窗口: 01:15:15(000)、01:15:17(500)，<span class="hl">最长连续失败 2 秒</span>')
a('最高延迟 3.11s（01:15:27，驱逐后 endpoints 收敛期），其余全部 &lt;1.25s')
a('')
a('<span class="key">── 告警行为（AM 通知计数 email / webhook）──</span>')
a('<span class="ok">DeploymentReplicasUnavailable 未触发</span> —— 迁移 11s 远小于 for:1m 阈值，优雅排水连告警线都没碰到')
a('窗口内新增通知 email+3 / webhook+2，全部为监控栈自噪音:')
a('  <span class="warn">AlertmanagerClusterDown</span> —— AM Pod 驻留在 w1，驱逐瞬间 AM 给自己报了警（Counter 随 Pod 迁移清零）')
a('  CPUThrottlingHigh（node-exporter 替补 Pod 短时节流）| InfoInhibitor(boutique) 按路由被抑制未通知')
a('')
a('<span class="dim">── 反亲和验证：演练前双副本服务均为一 w1 一 w2，drain 只损失一半容量，可用性不丢 ──</span>')

html1 = (
    '<!DOCTYPE html><html><head><meta charset="utf-8"><style>' + CSS + '</style></head>'
    '<body><div class="term">\n' + '\n'.join(L) +
    '\n</div>\n<div class="note">合成图说明：全部数值逐字取自 docs/chaos-drill1-timeline.log'
    '（drill 脚本 2s 轮询）与 docs/probe-drill1.log（探针原始数据），终端样式为排版重构。'
    '合成先例：截图 13 / 17。</div></body></html>'
)
io.open(os.path.join(OUT, 'tmp-chaos01.html'), 'w', encoding='utf-8').write(html1)
print('written')
