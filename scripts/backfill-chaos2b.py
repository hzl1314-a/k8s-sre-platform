# -*- coding: utf-8 -*-
"""演练二收尾：改进项表 + 做得对的地方 + 附件表 + 截图 README 登记。"""
import io

P = r'E:/yes/k8s-sre-platform/docs/chaos-drill.md'
s = io.open(P, encoding='utf-8').read()

# 1) 改进项表：填 1/2 行，追加 5/6 行
old = """| # | 问题 | 影响 | 改进方案 | 是否已实施 |
|---|---|---|---|---|
| 1 | 硬关机有 `__` 秒中断窗口 | 用户感知到失败 | 缩短 grace period / 增加副本数 / 前端重试 | |
| 2 | 告警到达延迟 `__` 秒 | 值班响应变慢 | 调整 `for` 持续时间、增加告警通道 | |
| 3 | 节点恢复后未自动 rebalance | 负载不均 | 引入 descheduler，或依赖 HPA 自然均衡 | |
| 4 | Pod 漂移期间新 Pod 拉镜像慢 | 恢复时间变长 | 各节点预热镜像（DaemonSet 预拉） | |"""
assert s.count(old) == 1, 'improve table anchor'
new = """| # | 问题 | 影响 | 改进方案 | 是否已实施 |
|---|---|---|---|---|
| 1 | 节点失联到驱逐有 338s 窗口（心跳 40s + toleration 300s） | 故障期间流量全部失败（本次因入口层同灭） | 缩短 tolerationSeconds / grace period（增大误判风险，需权衡） | 否（保持默认，理由见结论） |
| 2 | 告警到达延迟 84s（断电→邮箱） | 值班响应变慢 | 已在合理范围（采集15s+求值15s+for 60s）；可增加即时通道 | 已达标 |
| 3 | 节点恢复后未自动 rebalance | 负载不均（本次全部堆在 w1） | 引入 descheduler，或定期人工再均衡 | 否 |
| 4 | Pod 漂移期间新 Pod 拉镜像慢 | 恢复时间变长 | 各节点预热镜像（DaemonSet 预拉） | 否 |
| 5 | ★ **Traefik 双副本同节点（无反亲和）**，且 drain 替补不回流 | **入口层单点：节点断电=整站不可用，尽管业务层存活** | Traefik values 加 podAntiAffinity（required，按 hostname）；把 ingress/监控/存储纳入「双副本必须跨节点」检查清单 | 待实施（下一步） |
| 6 | kube-state-metrics、metrics-server、redis-cart 均无跨节点冗余 | w2 断电期间部分指标缺失、购物车暂不可用 | 关键组件反亲和 / redis-cart 改主从 | 否 |"""
s = s.replace(old, new)

# 2) 做得对的地方：修正 NodePort 那条 + 追加两条实测加分项
old2 = """- 副本 ≥2 + 反亲和，单节点故障只损失一半容量，不损失可用性
- NodePort 暴露在**所有节点**上，入口不随某个节点宕机而失效
- 就绪探针配置正确，Pod 未就绪时不会接收流量，避免了 5xx
- 探测脚本提供了**连续可量化的证据**，而不是"我感觉没断\""""
assert s.count(old2) == 1, 'good-things anchor'
new2 = """- 副本 ≥2 + 反亲和（业务层），单节点故障业务层只损失一半容量
- 告警链路（Prometheus → AM → 邮箱/钉钉）在故障场景下 84s 触达，恢复通知 502s 到达，全程无需人工介入
- taint 驱逐 + 重建全自动完成：断电后 340s 替补已在健康节点 Running，无需人工
- 探测脚本提供了**连续可量化的证据**，而不是"我感觉没断"
- ⚠️ 修正预设认知：原以为「NodePort 在所有节点监听 = 入口高可用」——实测**入口的可用性
  取决于后端 Traefik Pod 在哪个节点**，而不是 NodePort 端口在哪监听。这正是演练二的价值"""
s = s.replace(old2, new2)

# 3) 附件表补 chaos-05 和两个日志
old3 = '| `screenshots/chaos-04-recovery.png` | 恢复通知截图 |'
assert s.count(old3) == 1, 'attach anchor'
new3 = ('| `screenshots/chaos-04-recovery.png` | 恢复通知截图 |\n'
        '| `screenshots/chaos-05-poweroff.png` | 演练二时间线 + 可用性窗口条（合成图，数据源 chaos-drill2-timeline.log / probe-drill2.log） |\n'
        '| `chaos-drill2-timeline.log` / `probe-drill2.log` | 演练二 2s 轮询时间线 / 460 条探针原始数据 |')
s = s.replace(old3, new3)

io.open(P, 'w', encoding='utf-8', newline='\n').write(s)

# 4) 截图 README 登记
P2 = r'E:/yes/k8s-sre-platform/docs/screenshots/README.md'
s2 = io.open(P2, encoding='utf-8').read()
old4 = """| `chaos-02-alert-email.png` | 宕机告警邮件 | 待采集 |
| `chaos-03-alert-dingtalk.png` | 宕机告警钉钉 | 待采集 |
| `chaos-04-recovery.png` | 恢复通知 | 待采集 |"""
assert s2.count(old4) == 1, 'readme anchor'
new4 = """| `chaos-02-alert-email.png` | 宕机告警邮件（NodeNotReady critical，01:42:14 到达） | ✅ 2026-09-14 |
| `chaos-03-alert-dingtalk.png` | 宕机告警钉钉（01:43 到达） | ✅ 2026-09-14 |
| `chaos-04-recovery.png` | 恢复通知（RESOLVED，约 01:49 到达） | 待采集 |
| `chaos-05-poweroff.png` | 演练二时间线 + 可用性窗口条（合成图） | ✅ 2026-09-14 |"""
s2 = s2.replace(old4, new4)
io.open(P2, 'w', encoding='utf-8', newline='\n').write(s2)
print('improvements + readme OK')
