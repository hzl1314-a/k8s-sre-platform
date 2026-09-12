# S1 集群底座搭建手册

> 覆盖实施计划中的**任务 1 / 2 / 3**，对应规格文档的 S1 阶段。
> 目标：3 台 ECS 上跑起一个 kubeadm 集群，三节点 Ready，Calico 正常，可远程 kubectl。
>
> **使用方式：** 命令按顺序执行，每条都标注了「为什么」和「验收标准」。
> 执行中遇到的任何报错，记录到文末「踩坑记录」表——这份表是面试素材，不要删。

---

## 0. 开工前确认（5 件事，缺一件后面必卡）

| # | 检查项 | 怎么确认 | 不满足的后果 |
|---|---|---|---|
| 1 | 三台 ECS **同地域、同 VPC** | 控制台实例详情看「专有网络」 | 不同 VPC 内网不通，kubelet 直接无法 join |
| 2 | 记下三台**内网 IP 和公网 IP** | 控制台实例列表 | `/etc/hosts`、join 命令都要用 |
| 3 | 本机代理 7897 可用 | 浏览器开 google.com | 拉不到 Calico 清单 |
| 4 | 本机有 SSH 工具 | Windows 用 PowerShell 自带的 `ssh`，或 Xshell/PuTTY | 无法登录 ECS |
| 5 | 阿里云账号已实名、能开 3 台实例 | 控制台 | — |

**建议**：在一台机器上建一个 `~/nodes.txt` 把 IP 记下来，后面每一步都用得上，避免复制错。

```bash
# 建议在 k8s-cp 上建（后续命令都从这台发起）
cat > ~/nodes.txt <<'EOF'
k8s-cp  内网:172.16.0.11  公网:47.xx.xx.11
k8s-w1  内网:172.16.0.12  公网:47.xx.xx.12
k8s-w2  内网:172.16.0.13  公网:47.xx.xx.13
EOF
```

---

## 1. ECS 与系统初始化

### 1.1 创建实例（控制台操作）

| 配置项 | 选择 | 原因 |
|---|---|---|
| 地域 | 与你的 ACR 仓库**同地域**（如都选深圳） | 跨地域拉镜像慢且走公网计费 |
| 镜像 | Ubuntu 22.04 64 位 | K8s 1.31 官方支持列表内的 LTS |
| 规格 | cp: 2C4G / w1: 4C8G / w2: 4C8G | worker 要跑 Java(adservice)、Python(recommendation)，2C4G 会 OOM |
| 磁盘 | ≥40G 高效云盘 | 镜像 + 日志 + Prometheus 数据，20G 会爆 |
| 网络 | 同一 VPC、同一交换机（建议） | 内网互通 |
| 公网 IP | 分配，按使用流量计费 | 固定带宽会浪费钱 |
| 主机名 | `k8s-cp` / `k8s-w1` / `k8s-w2` | 控制台直接设，省去后面改 |
| 登录凭证 | 密钥对（推荐）或自定义密码 | 密钥对比密码安全，且免去每次输密码 |

> **坑位提示**：主机名如果在控制台没设，登录后用 `hostnamectl set-hostname` 改也行，
> 但阿里云镜像的 cloud-init 有概率在重启后还原。所以**优先在控制台创建时就指定**。

### 1.2 安全组规则（这一步做错，集群 100% 起不来）

新建一个安全组，绑到三台实例上，按下表加规则：

**入方向**

| 优先级 | 协议 | 端口范围 | 授权对象 | 说明 |
|---|---|---|---|---|
| 1 | 自定义 TCP | 22/22 | 你的本机公网 IP/32 | SSH，别开 0.0.0.0/0 |
| 1 | **全部** | **-1/-1** | **VPC 内网网段**（如 172.16.0.0/12） | ⚠️ **必须加！** 见下方说明 |
| 1 | 自定义 TCP | 6443/6443 | 你的本机公网 IP/32 | 远程 kubectl（可选，见 3.4） |
| 1 | 自定义 TCP | 30080/30080 | 0.0.0.0/0 | Traefik HTTP 入口 |
| 1 | 自定义 TCP | 30443/30443 | 0.0.0.0/0 | Traefik HTTPS 入口 |
| 1 | 自定义 TCP | 30300/30300 | 0.0.0.0/0（或限本机 IP） | Grafana |

**出方向**：默认全部放行即可（阿里云新安全组默认就是这样）。

> ⚠️ **最容易翻车的一条：内网全通规则**
>
> 阿里云安全组默认对**同组内实例之间的内网流量也是拒绝的**（这点和很多人想当然的"同组互信"不同）。
> 不加这条规则，现象是：`kubeadm join` 卡在 `Waiting for the kubelet to perform the TLS Bootstrap`，
> 然后超时失败；或者节点 Ready 但 Pod 之间互相 ping 不通。
>
> 三台机器之间需要互通的端口非常多（6443 apiserver、10250 kubelet、2379/2380 etcd、
> 179 BGP、4789 VXLAN、5473 Typha…），逐个加规则既累又容易漏，**直接放行内网网段全端口**。

**绑定方式**：控制台 → 实例 → 更多 → 网络和安全组 → 更换安全组，三台都换成这个。

### 1.3 系统初始化（三台都要执行）

> **省力做法（推荐）**：本节 4 个步骤已打包成幂等脚本 `scripts/00-system-init.sh`，三台各跑一次：
>
> ```bash
> # 本机上传（三台都传一份）
> scp scripts/00-system-init.sh root@<k8s-cp公网IP>:~/
> scp scripts/00-system-init.sh root@<k8s-w1公网IP>:~/
> scp scripts/00-system-init.sh root@<k8s-w2公网IP>:~/
>
> # 各自执行（只改第一个参数）
> ssh root@<k8s-cp公网IP> "bash ~/00-system-init.sh k8s-cp <cp内网IP> <w1内网IP> <w2内网IP>"
> ssh root@<k8s-w1公网IP> "bash ~/00-system-init.sh k8s-w1 <cp内网IP> <w1内网IP> <w2内网IP>"
> ssh root@<k8s-w2公网IP> "bash ~/00-system-init.sh k8s-w2 <cp内网IP> <w1内网IP> <w2内网IP>"
> ```
>
> 脚本会自动完成下面 4 步并打印验收结果（包括对端节点的 ping 连通性测试）。
>
> **但建议第一台手敲一遍**：面试被问「初始化都做了什么」时，手敲过才答得顺。
> 三台都跑完后回头对一遍脚本里的注释，比只跑脚本收获大得多。

SSH 登录每台机器，逐段执行。

**① 确认主机名**

```bash
hostname                      # 应该是 k8s-cp / k8s-w1 / k8s-w2
# 如果不对（比如显示 iZbp1xxxxxZ），手动设置：
sudo hostnamectl set-hostname k8s-cp
exec bash                     # 重载 shell，提示符才会变
```

**② 配置 hosts 解析（三台互写内网 IP）**

```bash
# ⚠️ 把下面三个 IP 换成你实际的**内网** IP（不是公网）
sudo tee -a /etc/hosts >/dev/null <<'EOF'
172.16.0.11  k8s-cp
172.16.0.12  k8s-w1
172.16.0.13  k8s-w2
EOF

cat /etc/hosts | tail -3        # 验收：能看到三行
```

> 为什么用内网 IP：K8s 各组件之间的通信全走内网（免流量费 + 低延迟）。
> 公网 IP 只在你自己 SSH 和外部访问 NodePort 时用得到。

**③ 关闭 swap**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

free -h                        # 验收：Swap 那一行全是 0B
```

> **为什么必须关**：kubelet 的调度和内存管理假设节点内存是"物理可预期"的。
> 有 swap 时，容器内存被换出到磁盘会导致性能剧烈抖动甚至 kubelet 启动失败。
> K8s 干脆在启动时直接报错拒绝（`running with swap on is not supported`）。
>
> 阿里云 Ubuntu 镜像默认本来就没有 swap，但这一步是标准动作，执行一遍确认无害。

**④ 时间同步**

```bash
sudo apt-get update
sudo apt-get install -y chrony
sudo systemctl enable --now chrony

timedatectl                    # 验收：System clock synchronized: yes
```

> **为什么重要**：K8s 依赖证书做认证，证书有有效期，节点间时间差过大（分钟级）会导致
> TLS 握手失败、etcd 选举异常。这类问题表现出来就是"莫名其妙的认证错误"，极难排查。

**⑤ （可选但推荐）预装常用工具**

```bash
sudo apt-get install -y curl wget vim net-tools jq bash-completion
```

### 1.4 任务 1 验收

三台上分别执行：

```bash
# 1) 三台互相 ping 通（这次用主机名，验证 hosts 配置生效）
ping -c 2 k8s-cp && ping -c 2 k8s-w1 && ping -c 2 k8s-w2

# 2) swap 为 0
free -h | grep -i swap

# 3) 时间已同步
timedatectl | grep -E "synchronized|Time zone"
```

三项都过 → **任务 1 完成**。有任何一项失败，回到对应小节排查，不要往下走。

---

## 2. containerd 与 kubeadm 安装（三台同样操作）

> **省力做法（推荐）**：本节已打包为幂等脚本 `scripts/10-install-runtime.sh`，三台各跑一次：
>
> ```bash
> # 本机上传（三台都传一份）
> scp scripts/10-install-runtime.sh root@<各台公网IP>:~/
>
> # 各自执行（建议带上你的阿里云专属加速地址）
> ssh root@<k8s-cp公网IP> \
>   "ALIYUN_MIRROR='https://xxxxxxx.mirror.aliyuncs.com' bash ~/10-install-runtime.sh"
> # w1 / w2 命令完全相同
> ```
>
> 脚本会自动完成：内核模块与 sysctl → containerd（含 cgroup 驱动修改 + certs.d 加速）
> → 实测拉镜像验证 → 装 kubeadm/kubelet/kubectl 并锁版本 → 打印 7 项验收结果。
>
> 这一节三台命令**完全一致**，手敲容易漏字，所以脚本是首选。
> 下面按小节给出手工步骤，**用于理解原理和出问题时的定位**。

### 2.1 内核前置配置

**① 加载内核模块**

```bash
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

lsmod | grep -E '^overlay|^br_netfilter'     # 验收：两行都有输出
```

> - `overlay`：containerd 的存储驱动，镜像分层靠它堆叠。
> - `br_netfilter`：让经过 Linux 网桥的流量也能被 iptables 规则处理。

**② 内核参数**

```bash
sudo tee /etc/sysctl.d/k8s.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

> 为什么需要这几项：Pod 网络是"容器 veth → 网桥 → 宿主机 → 网桥 → 容器 veth"的路径。
> 如果不让网桥流量经过 iptables，Service 的 NAT 转发规则就命中不了，
> 现象是**Pod 能出网但 Service ClusterIP 完全无法访问**——K8s 入门的经典坑。

### 2.2 安装 containerd 并配置镜像加速

**① 安装 containerd**

```bash
sudo apt-get update
sudo apt-get install -y containerd
containerd --version                          # 记下版本号，1.6 / 1.7 的配置差异见下
```

**② 生成默认配置**

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
```

> ⚠️ **先确认 containerd 版本**：现在的 Ubuntu 22.04 装出来可能是 **containerd 2.x**
> （实测 2.2.1，不是老教程里的 1.6/1.7）。2.x 的 config.toml 是 v3 格式，有两处与老教程不同：
>
> | 差异点 | containerd 1.x | containerd 2.x |
> |---|---|---|
> | 注册表配置段名 | `[plugins."io.containerd.grpc.v1.cri".registry]` | `[plugins."io.containerd.cri.v1.images".registry]` |
> | 空字符串写法 | 双引号 `""` | **单引号** `''` |
> | certs.d 默认值 | 空（需显式设置） | 已是 `/etc/containerd/certs.d` |
>
> 兼容性**不用慌**：官方矩阵里 K8s 1.31 支持 containerd `2.1.0+ / 2.0.0+ / 1.7.20+ / 1.6.34+`，
> 2.2.1 在支持范围内。但改配置的正则必须同时兼容单双引号，否则会漏判
> （`scripts/10-install-runtime.sh` 已处理）。

**③ 关键修改一：启用 systemd cgroup 驱动**

```bash
sudo sed -i 's/^\(\s*\)SystemdCgroup = false/\1SystemdCgroup = true/' /etc/containerd/config.toml
grep -n "SystemdCgroup" /etc/containerd/config.toml    # 验收：显示 SystemdCgroup = true
```

> **这是本阶段最重要的一个开关。** containerd 默认用 `cgroupfs` 驱动，而 kubelet 用 `systemd`。
> 两者不一致时，节点会一直停在 `NotReady`，kubelet 日志刷 `failed to run Kubelet:
> misconfiguration: kubelet cgroup driver: "cgroupfs" is different from docker cgroup driver: "systemd"`。
> 新版本 K8s 会直接拒绝启动 kubelet。

**④ 关键修改二：配置镜像加速（用 certs.d 方式，兼容性最好）**

这一步解决的是：**大陆 ECS 拉不动 gcr.io / quay.io / registry.k8s.io 的镜像**。

```bash
# 1) 让 containerd 读取 /etc/containerd/certs.d 下的按仓库配置
sudo sed -i 's|^\s*config_path = ""|  config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
grep -n 'config_path' /etc/containerd/config.toml      # 验收：config_path = "/etc/containerd/certs.d"
```

> 若上面这条 `grep` 没有任何输出，说明你的 config.toml 结构不同（containerd 1.7+ 有时用
> version 3 格式）。用 `sudo vim /etc/containerd/config.toml` 手动找到 `[plugins."io.containerd.grpc.v1.cri".registry]`
> 段（1.7 的 v3 格式是 `[plugins."io.containerd.cri.v1.images".registry]`），在其下加一行
> `config_path = "/etc/containerd/certs.d"`。

```bash
# 2) 为每个上游仓库写一份加速配置
sudo mkdir -p /etc/containerd/certs.d/{docker.io,quay.io,gcr.io,registry.k8s.io,ghcr.io}

# docker.io：优先用你的阿里云专属加速地址（ECS 上走内网，免流量且最快）
#   获取位置：容器镜像服务控制台 → 镜像工具 → 镜像加速器 → 专属地址
#   形如 https://xxxxxxx.mirror.aliyuncs.com
ALIYUN_MIRROR="https://<替换成你的阿里云专属加速地址>"

sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<EOF
server = "https://registry-1.docker.io"

[host."${ALIYUN_MIRROR}"]
  capabilities = ["pull", "resolve"]
[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# quay.io：Calico 全系镜像在这里，大陆直连基本失败
sudo tee /etc/containerd/certs.d/quay.io/hosts.toml >/dev/null <<'EOF'
server = "https://quay.io"

[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# gcr.io：Online Boutique 业务镜像在这里
sudo tee /etc/containerd/certs.d/gcr.io/hosts.toml >/dev/null <<'EOF'
server = "https://gcr.io"

[host."https://gcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# registry.k8s.io：kubeadm 控制面镜像、metrics-server 在这里
sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml >/dev/null <<'EOF'
server = "https://registry.k8s.io"

[host."https://k8s.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF

# ghcr.io：备用（部分云原生组件在这）
sudo tee /etc/containerd/certs.d/ghcr.io/hosts.toml >/dev/null <<'EOF'
server = "https://ghcr.io"

[host."https://ghcr.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
EOF
```

**⑤ 重启并验证**

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
systemctl status containerd --no-pager | head -5      # 验收：active (running)
```

**⑥ 验证加速真的生效（强烈建议做，别跳过）**

```bash
# crictl 是 CRI 的命令行客户端，用它模拟 kubelet 拉镜像
sudo apt-get install -y cri-tools

# 测试 quay.io（Calico 要用）
sudo crictl pull quay.io/tigera/operator:v1.32.7

# 测试 registry.k8s.io（控制面要用）
sudo crictl pull registry.k8s.io/pause:3.10
```

> 两条都成功 → 加速链路打通，后面 Calico / kubeadm 都不会卡在镜像上。
> 失败的话看 `/var/log/syslog` 或 `journalctl -u containerd -n 50`，
> 常见原因是 hosts.toml 里 server 字段被覆盖成了镜像地址（应为**原始**仓库地址）。
>
> **DaoCloud 镜像有懒加载机制**：某个镜像如果没人拉过，第一次请求会入队同步，
> 可能等 10~60 秒甚至超时。重试一次通常就好了。

### 2.3 安装 kubeadm / kubelet / kubectl

> ⚠️ **这里修正实施计划里的一个错误**：计划中给的阿里云 K8s 源地址
> `https://mirrors.aliyun.com/kubernetes-new/apt/doc/apt-key.gpg` 和
> `deb ... /kubernetes-new/apt/stable v1.31 main` **都是失效路径**，执行会 404。
> 阿里云新版源的正确格式是 `kubernetes-new/core/stable/v1.31/deb/`，GPG key 在该目录下的 `Release.key`。
> 下面是核实过的正确命令。

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
# GPG 公钥：注意路径是 core/stable/v1.31/deb/Release.key（不是 apt/doc/apt-key.gpg）
curl -fsSL https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.31/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# 仓库地址
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.31/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
# 先看看仓库里到底有哪些版本可选（关键一步，决定了后面 kubeadm 的版本号）
apt-cache madison kubeadm | head -5

sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl        # 锁版本，防止误升级
```

> **为什么先看 `apt-cache madison`**：仓库里的补丁版本（1.31.0 / 1.31.7 / 1.31.14…）
> 取决于阿里云同步到哪一版。你必须知道自己装的是哪一个，因为下一步 `kubeadm init`
> 要指定完全一致的版本号，否则会去拉一个仓库里不存在的镜像 tag。

**验收**：

```bash
kubeadm version -o short          # 例如 v1.31.14，记下这个数字
kubelet --version
kubectl version --client
systemctl is-enabled kubelet      # 输出 enabled 即可（此时 kubelet 尚未启动，正常）
```

> **注意**：`systemctl status kubelet` 此时是 `inactive (dead)`，**这是正常的**。
> kubelet 要等 kubeadm init 写入配置后才会运行。很多人在这里误以为装挂了。

### 2.4 任务 2 验收

三台各跑一遍：

```bash
lsmod | grep -E '^overlay|^br_netfilter'                     # 有输出
systemctl is-active containerd                               # active
grep SystemdCgroup /etc/containerd/config.toml               # true
kubeadm version -o short                                     # 有版本号
sudo crictl pull registry.k8s.io/pause:3.10                  # 成功
```

---

## 3. 集群组建

### 3.1 控制面 init（只在 k8s-cp 执行）

**① 预检镜像拉取（强烈建议，5 分钟内就能知道会不会卡）**

这一步只是拉镜像，不改变任何状态，失败了随时重来：

```bash
sudo kubeadm config images pull
```

> 这一步走的是 containerd 的 CRI 接口，因此**自动享受 2.2 节配好的加速**。
> 拉取的镜像地址是默认的 `registry.k8s.io/...`，实际由 containerd 转向 `k8s.m.daocloud.io`。
>
> **如果失败**，换阿里云镜像仓库作为兜底再试：
> ```bash
> sudo kubeadm config images pull \
>   --image-repository registry.cn-hangzhou.aliyuncs.com/google_containers
> ```
> 哪个成功，就把对应的参数带到下面的 `init` 命令里（成功用默认就**不要**加 `--image-repository`）。

**② 执行 init**

```bash
# 让版本号与 apt 装的实际版本严格一致，避免拉取不存在的镜像 tag
K8S_VERSION="$(kubeadm version -o short)"          # 例如 v1.31.14

sudo kubeadm init \
  --kubernetes-version="${K8S_VERSION}" \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-cert-extra-sans=<k8s-cp的公网IP>
```

**三个参数逐个解释（面试会问）：**

| 参数 | 作用 | 备注 |
|---|---|---|
| `--kubernetes-version` | 指定控制面组件版本 | 必须与 kubelet 实际版本一致。计划文档里写死的 `v1.31.0` 有风险——如果 apt 装的是 1.31.14，就会去拉 1.31.0 的镜像，可能拉不到 |
| `--pod-network-cidr=192.168.0.0/16` | Pod 网段 | **必须与 Calico 的默认配置一致**。Calico 的 `custom-resources.yaml` 里写死了 `192.168.0.0/16`，这里写别的就得同步改 |
| `--apiserver-cert-extra-sans` | 给 apiserver 证书额外加一个 IP/域名 | ⚠️ **这是实现「远程 kubectl」的关键**，见下方说明 |

> ⚠️ **关于远程 kubectl（计划里的一个遗漏）**
>
> 规格文档 S1 的验收标准写了「3 台 ECS kubeadm 集群 + Calico + **远程 kubectl**」，
> 但实施计划的任务 3 里没有对应的步骤。这里补上。
>
> 问题在于：kubeadm 生成的 apiserver 证书默认只签**内网 IP**。你在本机用
> kubeconfig 连公网 IP:6443 时，会报 `x509: certificate is valid for 172.16.0.11,
> not 47.xx.xx.11`——证书校验不过。
>
> 所以要加 `--apiserver-cert-extra-sans=<公网IP>`，把公网 IP 写进证书 SAN 列表。
> （如果 init 时忘了加，也可以事后改证书，但流程麻烦得多，不如一次做对。）
>
> **不想暴露 6443 到公网的话**，用 SSH 隧道也完全可行，见 3.4 节方案 B。

**③ 配置 kubectl（cp 节点本地使用）**

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes          # 验收：能看到 k8s-cp，状态 NotReady（正常，还没装 CNI）
```

> **`NotReady` 是此时唯一正确的状态**。因为 CNI 还没装，Pod 网络不可用，
> kubelet 的 `NetworkReady` 条件为假。装完 Calico 就会变 Ready。
>
> 顺便记一下：`kubectl cluster-info` 能输出 apiserver 地址。

### 3.2 安装 Calico

**① 本机（Windows，走代理）下载清单**

在**你自己的电脑**上打开 PowerShell 或 Git Bash：

```bash
# PowerShell 里如果 curl 是别名，用 curl.exe；Git Bash 直接用 curl 即可
curl -L -o calico-operator.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
curl -L -o calico-custom-resources.yaml \
  https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

# 检查文件大小，两个都应该 > 1KB（几十字节说明下载到的是 404 页面）
ls -lh calico-*.yaml

# 上传到控制面
scp calico-operator.yaml calico-custom-resources.yaml root@<k8s-cp公网IP>:~/
```

> **坑位**：`raw.githubusercontent.com` 在大陆时通时不通。如果下载失败，
> 用本机代理重试（`curl -x http://127.0.0.1:7897 -L -o ...`），
> 或直接把仓库克隆下来（calico 仓库的 manifests 目录）。

**② 在 k8s-cp 上安装**

```bash
kubectl create -f calico-operator.yaml
# 等 operator 就绪（约 30-60 秒）
kubectl get pods -n tigera-operator -w
# 看到 tigera-operator 变成 Running 后，Ctrl+C 退出

kubectl create -f calico-custom-resources.yaml
```

**③ 观察安装过程**

```bash
# 第一次拉镜像会稍慢（走 DaoCloud 加速）
kubectl get pods -n calico-system -w
```

预期最终状态（大约 2-5 分钟）：

| Pod | 数量 | 作用 |
|---|---|---|
| `calico-kube-controllers` | 1 | 同步 K8s 网络策略到 Calico 数据面 |
| `calico-node` | 每节点 1 个 | 数据面：BGP 宣告路由、下发 iptables/eBPF 规则 |
| `calico-typha` | 1 | 规模化时的 API 缓存代理（小集群也部署，面试可讲） |
| `csi-node-driver` | 每节点 1 个 | 不需要 CSI 的集群里它是闲置的，属正常现象 |

```bash
# 验收：全部 Running（tigera-operator 那条可能在别的 ns）
kubectl get pods -n calico-system
kubectl get pods -n tigera-operator

# 再看节点状态
kubectl get nodes         # 验收：k8s-cp 变成 Ready
```

> **如果 `calico-node` 一直 `Init:ImagePullBackOff`**：
> 说明镜像没拉下来。手动确认一次 `sudo crictl pull quay.io/calico/node:v3.28.0`，
> 排查 certs.d 配置。实在不行走兜底方案：把 `custom-resources.yaml` 里的
> `spec.registry: quay.io` 改成 `spec.registry: quay.m.daocloud.io`
> （这样 Calico 会直接去镜像站拉，绕过 containerd 的 mirror 逻辑）。
>
> **如果 `calico-node` 是 `Running` 但节点仍 `NotReady`**：
> 通常是内网端口没通。`kubectl logs -n calico-system <calico-node-pod>` 里
> 会看到 BGP 连接失败（179 端口）。回去检查安全组的内网全通规则。

**④ 消除控制面污点（不用，但要知道）**

```bash
# 看看控制面上有什么污点
kubectl describe node k8s-cp | grep -A3 Taints
# 输出：node-role.kubernetes.io/control-plane:NoSchedule
```

> 默认控制面不跑业务 Pod，这是正确的生产做法，**不要移除这个污点**。
> 我们有两个 worker 承担业务负载，控制面专心跑控制面组件。
> （面试如果被问"为什么控制面不跑业务"，答：隔离故障域 + 避免业务争抢 apiserver/etcd 资源）

### 3.3 worker 加入集群

**① 取 join 命令**

`kubeadm init` 成功时会打印一段 `kubeadm join ...`，直接复制即可。
如果终端已经滚过去了：

```bash
# 在 k8s-cp 上重新生成（token 有效期 24 小时，过期就能这么补）
kubeadm token create --print-join-command
```

输出形如：

```
kubeadm join 172.16.0.11:6443 --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:xxxxx
```

> ⚠️ **检查这个 IP 是内网 IP（172.16.x.x）而不是公网 IP**。
> 阿里云 ECS 的网卡上只有内网地址，kubeadm 会自动选到内网 IP，一般是对的。
> 如果是公网 IP 就说明检测有误，需要给 worker 加 `--apiserver-advertise-address` 修正。

**② 两个 worker 分别执行**

```bash
sudo kubeadm join 172.16.0.11:6443 --token <...> --discovery-token-ca-cert-hash sha256:<...>
```

成功的输出末尾是：

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.
```

> **卡住不动怎么办**：
> - 卡在 `[preflight] Running pre-flight checks` → 大概率是安全组内网不通
> - 卡在 `Waiting for the kubelet to perform the TLS Bootstrap` → 看 `journalctl -u kubelet -n 50`，
>   绝大多数是 containerd 的 cgroup 驱动没改（回 2.2 节第 ③ 步）
> - 提示 `token expired` → 回 k8s-cp 重新生成 token

**③ 回到 k8s-cp 验收**

```bash
kubectl get nodes
```

预期（三个都 Ready，注意 worker 的 ROLES 是 `<none>`，正常）：

```
NAME     STATUS   ROLES           AGE   VERSION
k8s-cp   Ready    control-plane   10m   v1.31.14
k8s-w1   Ready    <none>          2m    v1.31.14
k8s-w2   Ready    <none>          1m    v1.31.14
```

给 worker 打上角色标签，`kubectl get nodes` 看起来更规范（简历截图会好看）：

```bash
kubectl label node k8s-w1 node-role.kubernetes.io/worker=worker
kubectl label node k8s-w2 node-role.kubernetes.io/worker=worker
```

### 3.4 配置远程 kubectl（本机管理集群）

**方案 A：证书已加公网 IP SAN（推荐，配置一次长期可用）**

1. 安全组放行 6443，授权对象限你本机公网 IP/32（**不要开 0.0.0.0/0**）
2. 本机安装 kubectl（Windows）：

```bash
# PowerShell 里执行
curl.exe -LO "https://dl.k8s.io/release/v1.31.0/bin/windows/amd64/kubectl.exe"
# 本机走代理下载，或从 cp 节点直接 scp 一份（/usr/bin/kubectl 是 Linux 二进制，不能用）
```

3. 把 kubeconfig 拷到本机：

```bash
# 本机执行
mkdir -p ~/.kube
scp root@<k8s-cp公网IP>:/etc/kubernetes/admin.conf ~/.kube/config
```

4. 修改 server 地址为公网 IP：

```bash
# 本机执行（Git Bash）
sed -i 's|server: https://172.16.0.11:6443|server: https://<k8s-cp公网IP>:6443|' ~/.kube/config
kubectl get nodes        # 验收：能列出三台节点
```

> **安全提醒**：`admin.conf` 里是 **cluster-admin 全权凭据**。
> 不要提交到 Git（`.gitignore` 已经排除了），不要发到群里，演示完考虑吊销或轮换。

**方案 B：SSH 隧道（不暴露 6443，更安全）**

```bash
# 本机开着这条命令保持连接
ssh -N -L 6443:127.0.0.1:6443 root@<k8s-cp公网IP>
# 另开一个终端
sed -i 's|server: https://172.16.0.11:6443|server: https://127.0.0.1:6443|' ~/.kube/config
kubectl get nodes
```

> 方案 B 的证书校验怎么过？因为隧道的出口在 cp 节点本机，
> apiserver 会认为请求来自 127.0.0.1，而 `admin.conf` 里签的 CA 就是本机的，
> 把 server 改成 `https://127.0.0.1:6443` 后 **SAN 校验也是通过的**（kubeadm 默认证书含 127.0.0.1）。
> 所以方案 B **不需要** `--apiserver-cert-extra-sans`，也不需要开安全组 6443。
>
> 代价：每次要开隧道。适合安全敏感场景。想把"远程 kubectl 管理集群"写进简历，
> 用方案 A 更好讲。

### 3.5 任务 3 验收清单

```bash
# 1) 三节点 Ready
kubectl get nodes -o wide

# 2) 系统组件全部 Running
kubectl get pods -n kube-system
# 关注：etcd / kube-apiserver / kube-controller-manager / kube-scheduler / kube-proxy / coredns

# 3) Calico 全部 Running
kubectl get pods -n calico-system
kubectl get pods -n tigera-operator

# 4) DNS 与网络连通性实测（比看状态更可靠）
kubectl run nettest --image=registry.k8s.io/e2e-test-images/agnhost:2.45 \
  --restart=Never -- nslookup kubernetes.default
kubectl logs nettest
kubectl delete pod nettest
# 验收：能解析出 kubernetes.default 的 ClusterIP（10.96.0.1）

# 5) CoreDNS 是否真的在工作
kubectl get svc -n kube-system kube-dns       # ClusterIP 应为 10.96.0.10
```

**留证截图（放进 `docs/screenshots/`）**：

| 文件名 | 内容 |
|---|---|
| `01-nodes-ready.png` | `kubectl get nodes -o wide` 三节点 Ready |
| `02-calico-pods.png` | `kubectl get pods -n calico-system` 全 Running |
| `03-kube-system.png` | `kubectl get pods -n kube-system` 全 Running |

截图命令（在 Windows Terminal 里用 Win+Shift+S，或直接手机拍也行，但截图更专业）。

---

## 4. 踩坑记录（执行中填写）

> **这张表是面试素材。** 面试官问"部署过程中遇到什么问题"时，
> 具体的报错信息 + 排查路径 + 根因，比"遇到一些问题，后来解决了"强一百倍。

| # | 现象（原文报错） | 排查过程 | 根因 | 解决 |
|---|---|---|---|---|
| 1 | `[注意] 未能自动设置 config_path，请手工在 config.toml 的 registry 段下添加` | `containerd --version` → **2.2.1**，与脚本预期的 1.6/1.7 不符；`grep config_path /etc/containerd/config.toml` → 值用的是**单引号** `''` | containerd 2.x 改用 TOML v3 格式：注册表段名变为 `io.containerd.cri.v1.images`，空字符串序列化为单引号，只匹配双引号的正则必然漏判 | 脚本正则改为 `['\"]{2}` 兼容单双引号；对完全没有该字段的 2.x 情况识别为「默认值即 /etc/containerd/certs.d，无需修改」 |
| 2 | `[注意] cri-tools 安装失败，跳过镜像验证` | `apt-get install -y cri-tools` 报 `E: Unable to locate package cri-tools` | Ubuntu 自带源里**没有** cri-tools 包，它属于 Kubernetes 的 apt 源；而脚本把它放在「配 K8s apt 源」之前执行，顺序错了 | 把 cri-tools 安装与镜像验证整体挪到配好 K8s 源之后的步骤 4/4 |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |

### 已知高频坑速查

| 现象 | 大概率原因 | 定位命令 |
|---|---|---|
| 节点一直 NotReady | cgroup 驱动不一致 / CNI 未就绪 | `journalctl -u kubelet -n 100` |
| Pod 拉不到镜像 | certs.d 配置错误 / 镜像站无缓存 | `sudo crictl pull <image>` |
| join 卡在 preflight | 安全组内网未打通 | 从 worker `telnet <cp内网IP> 6443` |
| Service 无法访问 | net.bridge 参数未生效 | `sysctl net.bridge.bridge-nf-call-iptables` |
| 远程 kubectl 证书报错 | 未加公网 IP 到 SAN | 看报错里的 `is valid for` 列表 |
| token 过期 | 默认 24 小时有效期 | `kubeadm token create --print-join-command` |
| 镜像站返回 429/超时 | DaoCloud 懒加载队列排队 | 重试一次，或换阿里云专属加速 |

---

## 5. 面试要点自检（S1 完成后你应该能答出来）

1. **kubeadm init 到底做了哪几件事？**
   预检环境 → 生成证书与 kubeconfig → 生成静态 Pod 清单（apiserver/controller-manager/scheduler/etcd）
   → 写 kubelet 配置并启动 → 安装 CoreDNS 与 kube-proxy → 生成 join token 并打控制面污点。

2. **为什么必须关 swap / 统一 cgroup 驱动 / 开 ip_forward？**
   见 1.3③、2.2③、2.1② 的注释——这三条是最容易被追问的"为什么"。

3. **Calico 相比 Flannel 的优势？**
   Flannel 只解决"通不通"，Calico 还能做 NetworkPolicy（Pod 级防火墙）且基于 BGP 走三层路由，
   少一层 VXLAN 封装开销；面试可延伸讲"我们集群里可以用 NetworkPolicy 实现租户隔离"。

4. **`--pod-network-cidr` 为什么要和 CNI 配置一致？**
   它决定了每个节点从 Pod CIDR 里分到的子网块（kube-controller-manager 分配），
   CNI 若按另一网段配置，路由表会对不上，表现为跨节点 Pod 不通。

5. **内网 IP 和公网 IP 在架构里各承担什么角色？**
   集群内部全走内网（免流量费、低延迟），公网只用于外部访问入口（NodePort）和你的 SSH 管理。
   这是云上架构的基本功。

---

## 附：本阶段产出物

| 产出 | 位置 |
|---|---|
| 集群搭建手册 + 踩坑记录 | `docs/setup-cluster.md`（本文） |
| 留证截图 | `docs/screenshots/` |
| 下一阶段要用的 values 文件 | `monitoring/`、`manifests/`（已就绪） |
