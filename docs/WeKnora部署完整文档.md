# WeKnora 部署完整文档（Helm）

> 整理日期：2026-09-22
> 状态：**✅ 部署完成 + 模型已配 + 端到端 RAG 验证通过** —— 5 个 Pod 全部 Running，能上传文档、能提问并答对
> 目标集群：目标 k8s 集群（3 节点，v1.35.0）
> 项目：腾讯开源 [WeKnora](https://github.com/Tencent/WeKnora) —— 企业级 LLM 知识平台（RAG + ReAct Agent + 自维护 Wiki）
> 配套文档：[`WeKnora架构与部署结构图.md`](./WeKnora架构与部署结构图.md) —— 组件拓扑 / 部署结构 / 请求链路 / RAG 数据流
>
> **最终结果**：`helm install` 一次成功；app 早期重启 2 次是「等 postgres 就绪」的预期行为，之后稳定；
> 前端 `HTTP 200 + <title>WeKnora</title>`；`/api` 正确路由到后端；ParadeDB 扩展 `pg_search`/`vector` 已就位；
> **模型已配置（DeepSeek 对话 + 百炼向量），上传文档解析到 `completed`，提问得到带原文引用的正确答案**。

---

## 〇、给未来的自己：这份文档怎么用

- **想重跑一遍**：直接看 **第十四章「从零重建全流程」**，命令按顺序复制即可
- **卡住了**：看 **第十章「排障手册」** + **第十一章「完整踩坑清单」**
- **接着上次干**：看 **第十三章「完成清单与后续动作」**，当前进度和下一步命令都在那
- **只想抄配置**：第七章的 `values.yaml`、第六章的 `storage.yaml` 可直接用
- **想搞懂系统长什么样**：看配套的 [`WeKnora架构与部署结构图.md`](./WeKnora架构与部署结构图.md)
  —— 组件拓扑图、部署结构图、请求链路图、RAG 数据流图、命名对照表、故障域分析
- **模型配不通（页面能开但一问三不知）**：直接跳 **第十七章「模型服务配置」**
  —— 这是最容易漏的一章，模型配置在**数据库**里不在 values.yaml 里

---

## 一、任务背景与操作红线

### 任务要求
用 Helm 把 WeKnora 部署到现成 k8s 集群，独立命名空间 `weknora`。

### 操作红线（必须遵守）
1. **禁止任何破坏性命令**（`kubectl delete ns`、`rm -rf` 等），除非用户明确授权
2. **出错必须先 `kubectl describe pod` + `kubectl logs`，把日志总结给用户，绝对禁止盲目重试**
3. **生产敏感信息（DB 密码、JWT secret）不得明文写在命令行上**，一律走 `values.yaml` / Secret

> 本次实践下来，红线 2 特别值钱：磁盘爆满、Secret 不匹配这类问题，`describe` + `logs` 一看就明白，盲目重试只会浪费时间还掩盖真因。

---

## 二、环境全貌（已实测确认）

### 2.1 集群节点

| 节点 | 内网 IP | 角色 | 版本 | 内核 | 运行时 |
|---|---|---|---|---|---|
| `base` | 172.30.30.21 | worker | v1.35.0 | 6.8.0-111-generic | containerd 1.7.28 |
| `master01` | 172.30.30.11 | control-plane | v1.35.0 | 6.8.0-86-generic | containerd 1.7.28 |
| `node02` | 172.30.30.22 | worker | v1.35.0 | 6.8.0-111-generic | containerd 1.7.28 |

- 操作系统：Ubuntu 24.04.3 LTS
- 集群年龄：325 天（搭建后一直在用）
- **登录方式**：`ssh candidate@172.30.30.21`（密钥免密，`base` 节点是操作入口）
- 节点角色是 `candidate`，kubectl 免 sudo 可用

### 2.2 集群附加组件

| 组件 | 状态 | 说明 |
|---|---|---|
| CNI | calico | — |
| Ingress | ingress-nginx | 2 个 controller pod，IngressClass = **`nginx`** |
| cert-manager | 已装 | — |
| argocd | 已装 | — |
| metrics-server | 已装 | `kubectl top` 可用 |

### 2.3 StorageClass —— 关键陷阱，务必看完

```bash
$ kubectl get sc
NAME         PROVISIONER   RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
local-path   nfs-client    Delete          Immediate           true                   324d
```

**看起来有 SC，实际是空壳！**

```bash
$ kubectl get pods -A | grep -i nfs
(无输出)
```

SC 声明的 provisioner 是 `nfs-client`，但**集群里根本没有对应的 provisioner Pod**。
叠加 `VolumeBindingMode: Immediate`，结论是：

> ⚠️ **建了 PVC 会永远 Pending。必须手工创建 PV 并强制绑定。**

这就是为什么旧的 `pvc-8ma68a57-...` PV 上带着 `kubectl.kubernetes.io/last-applied-configuration` 注解 —— 它是**手工 apply 出来的**，不是动态供应的。

### 2.4 NFS 存储后端

- 服务端：`master01`（172.30.30.11）
- 导出路径：`/nfs/pv01`
- 导出配置：`172.30.30.0/24(rw,no_root_squash)`（`no_root_squash` 是必须的，否则容器内 root 写不进去）

本次新建了 3 个目录：
```bash
# 在 master01 上执行
sudo mkdir -p /nfs/pv01/weknora-{postgres,redis,data-files}
sudo chmod 0777 /nfs/pv01/weknora-{postgres,redis,data-files}
```

### 2.5 运行平台资源

| 项 | 值 |
|---|---|
| 物理 CPU | i5-7300HQ，**4 核 4 线程（无超线程）** |
| 运行平台 | VMware Workstation |
| base 节点内存 | 分配 6208 MB（节点内可见 5940 MB） |
| base 磁盘 | 48 G，已用 19 G，可用 27 G |

> **CPU 分配经验**：宿主 4 核 4 线程，给节点 **2 vCPU（最多 3）** 就够。
> 曾经想过给 4 vCPU —— 那是 100% 超售，宿主机本身会卡，而且 master01 上的 etcd/apiserver 会被抢 CPU。
> 内存给 6 GB 是因为 WeKnora 全套（app + postgres + redis + docreader）实测要吃 3~4 GB。

---

## 三、WeKnora 组件与资源需求

### 3.1 Chart 信息

| 项 | 值 |
|---|---|
| Chart 版本 | `0.1.0` |
| appVersion | `v0.8.0` |
| kubeVersion 要求 | `>=1.25.0-0` |
| License | MIT |
| Chart 路径 | `WeKnora/helm/` |

### 3.2 组件清单与镜像

| 组件 | 镜像 | 端口 | 本环境是否启用 |
|---|---|---|---|
| app（Go 主服务） | `wechatopenai/weknora-app:v0.8.0` | 8080 | ✅ |
| frontend（Web UI） | `wechatopenai/weknora-ui:latest` | 80 | ✅ |
| docreader（文档解析） | `wechatopenai/weknora-docreader:latest` | 50051 (gRPC) | ✅ |
| postgresql（**ParadeDB**） | `paradedb/paradedb:v0.18.9-pg17` | 5432 | ✅ |
| redis | `redis:7-alpine` | 6379 | ✅ |
| neo4j | `neo4j:2025.10.1` | 7687 | ❌ **关闭**（省 2Gi 内存 + 10Gi 存储） |
| minio | — | — | ❌ 关闭（用本地文件存储） |
| qdrant | — | — | ❌ 关闭（用 ParadeDB 做向量检索） |

### 3.3 关于 ParadeDB（容易忽略的知识点）

WeKnora 的 `RETRIEVE_DRIVER=postgres` 模式下，Postgres 用的**不是官方镜像，而是 ParadeDB**。

ParadeDB 是 Postgres 的增强发行版，内置 `pg_search`（BM25 全文检索）+ `pgvector`（向量检索）。
所以 **它一个容器同时承担了「关系库 + 全文检索 + 向量库」三个角色** —— 这是 WeKnora 不需要额外向量数据库的原因。

> 相应地：**不能用 `postgres:17` 替换它**，会缺扩展导致 app 起不来。

### 3.4 关于 Neo4j（用户特别要求提醒的点）

**Neo4j 是内存杀手**：
- 默认 `limits: {cpu: "1", memory: 2Gi}` —— 这只是 limit，JVM 堆 + page cache 实际上很容易吃满
- 额外还要 10Gi 持久化存储
- 只有开启 **GraphRAG**（知识图谱增强检索）才需要它

**本环境决策：`neo4j.enabled: false`。** 理由：base 节点总共才 6 GB 内存，开 Neo4j 后 postgres + neo4j + app + docreader 会打到 OOM。

> 以后要开 GraphRAG，先把 base 内存加到 8 GB 以上，再 `neo4j.enabled: true`。

### 3.5 关于 LITE 模式（评估过，本次没用）

WeKnora 提供 **LITE 模式**：单个 Go 二进制，SQLite + sqlite-vec/FTS5，内存队列，**不需要 Postgres/Redis**。
- 构建命令：`make build-lite`（底层 `go build -tags "sqlite_fts5"`）
- **坑**：GitHub Release v0.8.0 **没有提供预编译二进制**，assets 是空的，必须自己 `go build`
- 结论：本次走标准 Helm chart 模式（组件化、可维护），没用 LITE

---

## 四、阶段一：环境预检

```bash
ssh candidate@172.30.30.21

# 1. 集群版本
kubectl version --short
kubectl get nodes -o wide

# 2. 节点资源（需要 metrics-server）
kubectl top nodes

# 3. Helm 版本（要求 >= 3.10）
helm version --short

# 4. StorageClass
kubectl get sc

# 5. Ingress Controller
kubectl get ingressclass
kubectl get pods -A | grep ingress
```

**预检结论**：
- ✅ k8s v1.35.0 ≥ 1.25，满足
- ✅ Helm 需安装 → 阶段二解决（装成 v3.16.3）
- ⚠️ StorageClass 有但 provisioner 没跑 → 走手工 PV（见 2.3）
- ✅ Ingress 就绪，class = `nginx`

---

## 五、阶段二：国内网络下的依赖获取（本次最大的坑）

### 5.1 网络实测结果

| 目标 | 结果 | 应对 |
|---|---|---|
| `github.com` | ❌ 阻塞/不稳定 | 用 `api.github.com` 走 API 拿文件 |
| `raw.githubusercontent.com` | ✅ 通 | **直接逐个下载 chart 文件**（绕开 git clone） |
| `get.helm.sh` | ✅ 通 | 直接装 Helm |
| Docker Hub | ❌ 阻塞 | 用 `docker.m.daocloud.io` 镜像站 |

### 5.2 安装 Helm（v3.16.3）

```bash
# 下载
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz

# 解压安装
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm

# 验证
helm version --short
# v3.16.3+gcfd0749
```

### 5.3 获取 WeKnora Chart（不用 git clone）

`github.com` 不通，但 `raw.githubusercontent.com` 通。逐个下载 chart 文件：

```bash
mkdir -p ~/weknora-helm/templates
cd ~/weknora-helm

BASE="https://raw.githubusercontent.com/Tencent/WeKnora/main/helm"

curl -fsSL -o Chart.yaml          "$BASE/Chart.yaml"
curl -fsSL -o values.yaml         "$BASE/values.yaml"
curl -fsSL -o README.md           "$BASE/README.md"

# templates 目录下的所有文件
for f in _helpers.tpl app.yaml docreader.yaml frontend.yaml ingress.yaml \
         neo4j.yaml pvc.yaml redis.yaml secrets.yaml serviceaccount.yaml \
         postgres.yaml; do
  curl -fsSL -o "templates/$f" "$BASE/templates/$f"
done
```

> **踩坑**：`WebFetch` 工具访问 github.com 被拦；提前列全 templates 文件名很关键，漏一个渲染就报错。
> 实际 `~/weknora-helm/` 结构就是 `Chart.yaml` + `README.md` + `values.yaml` + `templates/`。

### 5.4 校验 chart

```bash
helm lint ~/weknora-helm
# ==> Linting .
# 1 chart(s) linted, 0 chart(s) failed
```

### 5.5 Docker Hub 镜像站方案（核心技巧）

这类镜像站就是 Docker Hub 的代理，**路径规则统一是把 `docker.io/` 换成镜像站域名**：

| 规范名（k8s 要用的） | 镜像站地址（实际拉的） |
|---|---|
| `docker.io/wechatopenai/weknora-app:v0.8.0` | `docker.m.daocloud.io/wechatopenai/weknora-app:v0.8.0` |
| `docker.io/wechatopenai/weknora-ui:latest` | `docker.m.daocloud.io/wechatopenai/weknora-ui:latest` |
| `docker.io/wechatopenai/weknora-docreader:latest` | `docker.m.daocloud.io/wechatopenai/weknora-docreader:latest` |
| `docker.io/paradedb/paradedb:v0.18.9-pg17` | `docker.m.daocloud.io/paradedb/paradedb:v0.18.9-pg17` |
| `docker.io/library/redis:7-alpine` | `docker.m.daocloud.io/library/redis:7-alpine` |

**关键两步**：拉下来之后必须 `tag` 回规范名，否则 chart 引用的 `docker.io/...` 找不到镜像。

> 官方镜像（`library/` 前缀）在镜像站上要写成 `library/redis`，别写成 `redis`。
> 探测镜像站是否可用：`curl -sI https://docker.m.daocloud.io/v2/` —— 返回 **401 是正常的**（说明服务活着，只是要认证）。

⚠️ **不要只押一个镜像站**。本次实测 `docker.m.daocloud.io` 拉小镜像没问题，但遇到 docreader 的 740 MiB 单层会反复断流（卡了两次）。换成 `docker.1ms.run` 立刻就通。**拉取脚本里务必写成镜像站数组，按顺序 fallback**（见 9.2 / 9.4）。

---

## 六、阶段三：存储准备（手工 PV/PVC 强制绑定）

### 6.1 为什么必须手工绑定

见 2.3：SC 的 provisioner Pod 不存在 → 动态供应是死的 → PVC 会永远 Pending。

### 6.2 先建好 NFS 目录（在 master01 上）

```bash
sudo mkdir -p /nfs/pv01/weknora-{postgres,redis,data-files}
sudo chmod 0777 /nfs/pv01/weknora-{postgres,redis,data-files}
```

### 6.3 建命名空间 + PV/PVC

先建 namespace：

```bash
kubectl create namespace weknora
```

再写 `~/weknora-storage.yaml`（**完整内容**）：

```yaml
# ---- PersistentVolumes: 手工创建，指向 master01 的 NFS 导出 ----
apiVersion: v1
kind: PersistentVolume
metadata:
  name: weknora-postgres-pv
spec:
  capacity:
    storage: 8Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  nfs:
    server: 172.30.30.11
    path: /nfs/pv01/weknora-postgres
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: weknora-redis-pv
spec:
  capacity:
    storage: 1Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  nfs:
    server: 172.30.30.11
    path: /nfs/pv01/weknora-redis
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: weknora-data-files-pv
spec:
  capacity:
    storage: 8Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-path
  nfs:
    server: 172.30.30.11
    path: /nfs/pv01/weknora-data-files
---
# ---- PersistentVolumeClaims: 用 volumeName 强制绑定到上面的 PV ----
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: weknora-postgres
  namespace: weknora
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  volumeName: weknora-postgres-pv
  resources:
    requests:
      storage: 8Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: weknora-redis
  namespace: weknora
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  volumeName: weknora-redis-pv
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: weknora-data-files
  namespace: weknora
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  volumeName: weknora-data-files-pv
  resources:
    requests:
      storage: 8Gi
```

应用并验证：

```bash
kubectl apply -f ~/weknora-storage.yaml
kubectl get pv,pvc -n weknora
```

**实测结果（全部 Bound）**：

```
NAME                                          CAPACITY  ACCESS  STATUS   CLAIM
persistentvolume/weknora-data-files-pv        8Gi       RWO     Bound    weknora/weknora-data-files
persistentvolume/weknora-postgres-pv          8Gi       RWO     Bound    weknora/weknora-postgres
persistentvolume/weknora-redis-pv             1Gi       RWO     Bound    weknora/weknora-redis

NAME                                STATUS  VOLUME                 CAPACITY
persistentvolumeclaim/weknora-data-files  Bound  weknora-data-files-pv  8Gi
persistentvolumeclaim/weknora-postgres    Bound  weknora-postgres-pv    8Gi
persistentvolumeclaim/weknora-redis       Bound  weknora-redis-pv       1Gi
```

### 6.4 要点说明

- **`volumeName` 是强制绑定的关键**。不写它，即便 PV 存在，PVC 也可能去等动态供应而一直 Pending。
- **`storageClassName` 两边必须一致**（这里都用 `local-path`）。PV 侧写 `""` 而 PVC 侧写 `local-path`，就绑不上。
- **`persistentVolumeReclaimPolicy: Retain`**：删 PVC 也不会删 NFS 数据，安全。
- **PVC 容量必须 ≤ PV 容量**，否则不绑。
- **PVC 名字要和 chart 对得上**：`weknora-postgres` / `weknora-redis` / `weknora-data-files`。

---

## 七、阶段四：Secret 与自定义 values.yaml

### 7.1 先看清 chart 的 Secret 结构

`templates/secrets.yaml` 会创建一个 Secret，包含这些 key：

| Key | 来源 | 是否必填 |
|---|---|---|
| `DB_USER` | `secrets.dbUser` | 必填 |
| `DB_PASSWORD` | `secrets.dbPassword` | **必填** |
| `DB_NAME` | `secrets.dbName` | 必填 |
| `REDIS_USERNAME` | `secrets.redisUsername` | 可空 |
| `REDIS_PASSWORD` | `secrets.redisPassword` | **必填** |
| `JWT_SECRET` | `secrets.jwtSecret` | **必填** |
| `SYSTEM_AES_KEY` | `secrets.systemAesKey` | 强烈建议，**必须恰好 32 字节** |
| `NEO4J_USERNAME` / `NEO4J_PASSWORD` | 同前缀 | 仅 Neo4j 开启时需要 |

> 模板用 `lookup` 读取已有 Secret —— **升级时已存在的密钥不会被覆盖**。这是好事，但也意味着「改 values 里的密码」在 upgrade 时**不一定生效**。要改密码得先删 Secret。

### 7.2 ⚠️ SYSTEM_AES_KEY 的致命性

`systemAesKey` 用于加密租户的 `api_key` 和模型 key。

> **丢失它 = 已加密的数据永久不可恢复。** 迁集群、重装前必须备份这个值。

**必须是恰好 32 字节**：

```bash
openssl rand -hex 16    # 输出 32 个十六进制字符 = 32 字节 ✅
openssl rand -base64 32 # 输出 44 字符，base64 解码后 32 字节，也可以但要小心
```

用 `openssl rand -hex 32`（64 字符）就会因为超长而报错。

### 7.3 生成密钥（不要在命令行明文写）

```bash
cd ~
DB_PASS=$(openssl rand -hex 16)
REDIS_PASS=$(openssl rand -hex 16)
JWT_SEC=$(openssl rand -hex 32)
AES_KEY=$(openssl rand -hex 16)

# 校验长度必须 = 32
echo -n "$AES_KEY" | wc -c
```

> 红线 3 的落实方式：**只让随机值存在于 shell 变量和最终的 values.yaml 文件里，不把密码本身敲进命令行参数**。

### 7.4 完整 `~/weknora-values.yaml`

```yaml
# ============================================================
# WeKnora 自定义 values（部署到本地集群 / weknora namespace）
# ============================================================

# ---- 全局 ----
global:
  # 用 existingClaim，不走动态供应（本集群无 provisioner 是正常的）
  storageClass: ""
  maxFileSizeMB: 50

# ---- 密钥（不在命令行明文，全部收敛在这个文件里）----
secrets:
  dbUser: postgres
  dbPassword: "<CHANGE_ME_openssl_rand_hex_16>"
  dbName: weknora
  redisUsername: ""
  redisPassword: "<CHANGE_ME_openssl_rand_hex_16>"
  jwtSecret: "<CHANGE_ME_openssl_rand_hex_32>"
  # 必须恰好 32 字节；加密租户 api_key / 模型 key，丢失则已加密数据不可恢复
  systemAesKey: "<CHANGE_ME_openssl_rand_hex_16>"

# ---- 存储：指向手工创建并已 Bound 的 PVC ----
postgresql:
  persistence:
    enabled: true
    existingClaim: weknora-postgres
  nodeSelector:
    kubernetes.io/hostname: base
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: "1",  memory: 1Gi }

redis:
  persistence:
    enabled: true
    existingClaim: weknora-redis
  nodeSelector:
    kubernetes.io/hostname: base

dataFiles:
  persistence:
    enabled: true
    existingClaim: weknora-data-files

# ---- 关掉 Neo4j（省 2Gi 内存 + 10Gi 存储，不开 GraphRAG 用不到）----
neo4j:
  enabled: false

# ---- 各组件：全部钉到 base 节点（6GB 内存 + 镜像已缓存在这台）----
app:
  nodeSelector:
    kubernetes.io/hostname: base
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: "1",  memory: 1Gi }
  # ===== 模型服务配置 =====
  # ⚠️ 不要在这里写 LLM_BASE_URL / EMBEDDING_BASE_URL！
  #    这些 env 只有在你另外挂载 config/builtin_models.yaml（用 ${NAME} 占位）
  #    时才会被读取；单独设置它们【完全无效】，而且 chart 也不挂载那个文件。
  #    模型是通过 Web UI（或 REST API）写进数据库的 —— 见第十七章。
  # extraEnv:
  #   - name: WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL   # 自举系统管理员用，见 17.5
  #     value: "you@example.com"

frontend:
  nodeSelector:
    kubernetes.io/hostname: base

docreader:
  nodeSelector:
    kubernetes.io/hostname: base
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 500m, memory: 512Mi }

# ---- Ingress（集群已有 nginx IngressClass，直接对上 chart 默认值）----
ingress:
  enabled: true
  className: nginx
  host: weknora.local
  tls:
    enabled: false
```

> ⚠️ **本节密钥是本次部署实际使用的真实值**。迁集群或重装时应当**重新生成**（见 7.3），
> 但要迁已有数据的话，`systemAesKey` 必须原样保留，否则历史加密数据解不开。

### 7.5 values.yaml 关键设计决策

| 决策 | 原因 |
|---|---|
| `global.storageClass: ""` | 配合 `existingClaim`，走手工 PV，不让 chart 去动态供应 |
| `nodeSelector: base` | base 内存最大（6GB）且是操作入口；镜像也只导到了这台 |
| `neo4j.enabled: false` | 内存不够；不开 GraphRAG 用不到 |
| `minio.enabled: false` | 用本地文件存储（`STORAGE_TYPE=local`） |
| `ingress.className: nginx` | 对齐集群已有 IngressClass |
| 模型配置留空 | 官方推荐装完在 Web UI 里配，灵活；避免 key 落在 values 文件里 |

### 7.6 chart 的 `existingClaim` 机制（原理）

chart 的 PVC 模板是这么写的：

```yaml
# templates/pvc.yaml
{{- if and .Values.X.enabled .Values.X.persistence.enabled (not .Values.X.persistence.existingClaim) }}
# 创建 PVC
{{- end }}
```

Deployment 侧引用时：

```yaml
# templates/postgres.yaml:94
claimName: {{ .Values.postgresql.persistence.existingClaim | default (printf "%s-postgres" (include "weknora.fullname" .)) }}
```

**所以：一旦填了 `existingClaim`，chart 就不再创建 PVC，直接用我们手工建的那个。** 这正是我们要的。

---

## 八、阶段五：渲染校验（安装前必做）

**永远先 `helm template` 看一眼，再 `install`。**

```bash
# 1. lint
helm lint ~/weknora-helm

# 2. 渲染并检查关键点
helm template weknora ~/weknora-helm -n weknora -f ~/weknora-values.yaml > /tmp/rendered.yaml

# 3. 验证 PVC 挂载是否真的指向手工 PVC
grep -n "claimName" /tmp/rendered.yaml
# 期望看到：
#   claimName: weknora-postgres
#   claimName: weknora-redis
#   claimName: weknora-data-files

# 4. 验证 Ingress
grep -n -A5 "kind: Ingress" /tmp/rendered.yaml

# 5. 验证 Neo4j 确实没渲染出来
grep -c "neo4j" /tmp/rendered.yaml   # 应为 0 或极少
```

### 8.1 docreader 的 `-addr=localhost:50051` —— 虚惊一场

渲染结果里有这么一段，**曾一度以为是跨 Pod 连不通的 bug**：

```yaml
livenessProbe:
  exec:
    command:
      - grpc_health_probe
      - -addr=localhost:50051     # ← 这里
readinessProbe:
  exec:
    command:
      - grpc_health_probe
      - -addr=localhost:50051
```

**结论：没问题。** 这是**容器内**的健康检查探针，`grpc_health_probe` 跑在 docreader 容器自己的进程空间里，`localhost` 完全正确。

app 访问 docreader 走的是另一条路，用的是 Service DNS：

```yaml
# app 容器的 env
- name: DOCREADER_ADDR
  value: "docreader:50051"
```

**文档到此澄清，别再重复怀疑。**

### 8.2 docreader Service 名是硬编码的（重要）

```yaml
# templates/docreader.yaml
# Service name must be "docreader" - app references this
name: docreader
```

- **Service 名**：`docreader`（硬编码，**没有**走 `weknora.fullname`）
- **Deployment 名**：`weknora-docreader`（走了 fullname）

> 这意味着**不能用 `fullnameOverride` 或改 release 名来改 docreader 的 Service 名**，否则 app 的 `DOCREADER_ADDR=docreader:50051` 就解析不了。
> 本次 release 名叫 `weknora`，Service 恰好在同 namespace 内解析正常。

---

## 九、阶段六：镜像落盘到 containerd

### 9.1 为什么要落盘

集群节点不能访问 Docker Hub，所以镜像必须**提前拉好并导入 containerd 的 `k8s.io` 命名空间**。

k8s 用的是 containerd 的 **`k8s.io` namespace**，不是默认的 `default`。用 `ctr` 时必须带 `-n k8s.io`，否则 k8s 看不见。

### 9.2 拉取脚本（已放在 VM 上：`~/weknora-pull-images.sh`）

```bash
#!/bin/bash
# WeKnora 镜像拉取（国内网络：走镜像站，再重命名回 docker.io 规范名）
#
# 幂等：已存在的镜像自动跳过，可反复执行。
# 防挂死：containerd 默认无拉取超时，会永久卡住 —— 这里单次最长 3600s，失败自动换镜像站。
set -u

# 镜像站列表：按顺序尝试。daocloud 大 layer 会断流，1ms.run 实测稳定（见 9.4）
MIRRORS=(
  "docker.1ms.run"
  "docker.m.daocloud.io"
)
PER_TRY_TIMEOUT=3600       # 单次拉取超时（秒）。1.5G 镜像慢链路要 40+ 分钟，别设小

IMAGES=(
  "wechatopenai/weknora-app:v0.8.0"
  "wechatopenai/weknora-ui:latest"
  "wechatopenai/weknora-docreader:latest"
  "paradedb/paradedb:v0.18.9-pg17"
  "library/redis:7-alpine"
)

FAILED=()

for im in "${IMAGES[@]}"; do
  echo "=== $im ==="

  if sudo ctr -n k8s.io i ls -q | grep -qx "docker.io/$im"; then
    echo "  -> 已存在，跳过"
    continue
  fi

  ok=0
  for M in "${MIRRORS[@]}"; do
    echo "  -- 镜像站 $M（单次超时 ${PER_TRY_TIMEOUT}s）--"
    # 注意：并发参数名是 --max-concurrent-downloads，不是 --concurrency（新版 ctr 无此 flag）
    if timeout "$PER_TRY_TIMEOUT" sudo ctr -n k8s.io i pull --max-concurrent-downloads 8 "$M/$im"; then
      SRC="$M"
      ok=1
      break
    fi
    echo "  !! $M 失败/超时，换下一个镜像站"
    sleep 5
  done

  if [ "$ok" -ne 1 ]; then
    echo "  !! 放弃：$im"
    FAILED+=("$im")
    continue
  fi

  sudo ctr -n k8s.io i tag "$SRC/$im" "docker.io/$im"
  echo "  -> 已重命名为 docker.io/$im（来源 $SRC）"
done

echo
echo "=== 最终结果（目标是 5 行 docker.io/ 开头）==="
sudo ctr -n k8s.io i ls -q | grep -E "weknora|paradedb|redis:7-alpine"

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "全部就位"
else
  echo "以下镜像仍未成功，可重跑本脚本："
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
```

执行：

```bash
bash ~/weknora-pull-images.sh
```

### 9.3 镜像落盘最终结果（5/5 全部就位）

```
$ sudo ctr -n k8s.io i ls -q | grep -E "weknora|paradedb|redis:7-alpine"
docker.io/library/redis:7-alpine
docker.io/paradedb/paradedb:v0.18.9-pg17
docker.io/wechatopenai/weknora-app:v0.8.0
docker.io/wechatopenai/weknora-ui:latest
docker.io/wechatopenai/weknora-docreader:latest
```

| 镜像 | 结果 | 实际来源镜像站 |
|---|---|---|
| `docker.io/wechatopenai/weknora-app:v0.8.0` | ✅ | daocloud |
| `docker.io/wechatopenai/weknora-ui:latest` | ✅ | daocloud |
| `docker.io/library/redis:7-alpine` | ✅ | daocloud |
| `docker.io/paradedb/paradedb:v0.18.9-pg17` | ✅ | daocloud |
| `docker.io/wechatopenai/weknora-docreader:latest` | ✅ | **1ms.run**（daocloud 拉不下来，见 9.5） |

> 镜像站名字会残留在 store 里（`docker.m.daocloud.io/...`、`docker.1ms.run/...`），**这是正常的**，不影响使用。
> 关键是 `docker.io/` 开头的规范名必须存在 —— k8s 只认这个。

### 9.4 ⚠️ 拉取挂死 + 镜像站选择（本次最耗时的坑）

#### 现象

docreader（1.5 GiB，最大单层 740 MiB）反复卡死：进程在、不报错、不退出、**永远不动**。
前后遇到 **两次**，分别卡在 77 MB 和 371 MB。

#### 怎么判断「慢」还是「死」—— 三层指标

单看 `ps` 没用（进程活着）。必须看**有没有在增长**：

```bash
# 指标① containerd 总目录（最可靠，不受路径变化影响）
sudo du -sm /var/lib/containerd; sleep 60; sudo du -sm /var/lib/containerd

# 指标② ctr 自报进度（日志里的 total 值）
tail -c 4000 ~/docreader-pull.log | tr '\r' '\n' | grep -oE "total: +[0-9.]+ +[KMG]?" | tail -1

# 指标③ 进程真实 IO（root 才读得到）
for p in $(pgrep -f "ctr -n k8s.io i pull"); do echo "PID $p"; sudo cat /proc/$p/io | grep -E "read_bytes|write_bytes"; done
```

**实测的「死」长这样**：ctr 的 `total` 冻结在 `371.0` 不动；containerd 目录 75 s 零增长；进程 `write_bytes: 0`。

> ⚠️ **踩过的坑**：只盯 `ingest/` 目录会误判 —— containerd 1.7 走 transfer service，落盘路径不止 ingest 一个。
> **改用「整个 `/var/lib/containerd` 的增量」最稳。**

#### 根因（两个，缺一不可）

1. **containerd/ctr/crictl 默认没有拉取超时** —— 连接被对端掐断后，它就一直等，永远不会自己失败。
2. **`docker.m.daocloud.io` 在大 layer 上会断流** —— 小镜像正常，docreader 这种带 740 MiB 单层的就卡死。

#### 关键发现：换镜像站立刻解决

```
docker.m.daocloud.io   401 可达，但大 layer 断流（卡了两次）
docker.1ms.run         401 可达，实测稳定 4.5 MiB/s  ← 最终用它拉完
docker.1panel.live     200 可达（备选）
hub.rat.dev            302 可达（备选）
docker.nju.edu.cn      403（需带路径前缀）
dockerpull.org         000 不可达
```

**换站不会重下已完成的部分**：镜像层是内容寻址的（content-addressable），已完成的 layer 会被直接复用（日志里显示 `exists`），只有那个没下完的大 layer 需要续传。

#### 处理步骤（实际用的）

```bash
# ① 杀掉卡死的拉取
sudo pkill -f "ctr -n k8s.io i pull"

# ② 换 1ms.run 重拉，脱离 ssh 会话（nohup），超时放宽，并发提高
nohup timeout 3600 sudo ctr -n k8s.io i pull --max-concurrent-downloads 8 \
  docker.1ms.run/wechatopenai/weknora-docreader:latest \
  > ~/docreader-pull2.log 2>&1 &

# ③ 打回规范名
sudo ctr -n k8s.io i tag \
  docker.1ms.run/wechatopenai/weknora-docreader:latest \
  docker.io/wechatopenai/weknora-docreader:latest
```

#### 几个踩过的细节

| 细节 | 说明 |
|---|---|
| **并发参数名** | 是 `--max-concurrent-downloads`，**不是** `--concurrency`（新版 ctr 没这个 flag，会直接报 `flag provided but not defined`） |
| **超时别设小** | 最初设 900 s，但 1.5 GiB @ 500 KB/s 需要 ~44 分钟，超时会反复重启永远跑不完。改成 3600 s |
| **续传是有效的** | 拉取被 kill 后，`ingest` 里的部分数据**还在**，重拉会从中断处继续（实测 364 MiB → 371 MiB 接着涨） |
| **用 nohup 脱离 ssh** | 否则本地 ssh 一断，拉取就被带走 |
| **别用 `crictl pull`** | 它没有超时控制也没有可控的并发参数，就是最初挂死的原因 |

### 9.5 检查镜像是否就位

```bash
sudo ctr -n k8s.io i ls -q | grep -E "weknora|paradedb|redis:7-alpine"
```

**期望看到 5 行，且都是 `docker.io/` 开头**。如果只有 `docker.m.daocloud.io/` 开头的，说明 `tag` 步骤没跑，k8s 会拉不到镜像报 `ErrImagePull`。

---

## 十、阶段七：安装与验证

### 10.1 安装

```bash
helm install weknora ~/weknora-helm -n weknora -f ~/weknora-values.yaml
```

### 10.2 监控 Pod 启动

```bash
kubectl get pods -n weknora -w
```

期望最终 5 个 Pod 全部 `Running`：

| Pod | 说明 |
|---|---|
| `weknora-app-xxx` | 主服务 |
| `weknora-frontend-xxx` | Web UI |
| `weknora-docreader-xxx` | 文档解析 |
| `weknora-postgres-xxx` | **ParadeDB**（不是 `weknora-postgresql`） |
| `weknora-redis-xxx` | Redis |

> ⚠️ **app 会先崩溃重启 2 次，这是预期的**。原因：app 的 `initDatabase` 连不上还没就绪的 postgres，直接 **panic** 退出，k8s 反复重启直到 postgres ready。实测日志：
> ```
> failed to connect to `user=postgres database=weknora`: ...:5432 (postgres):
>   dial error: dial tcp ...:5432: connect: connection refused
> panic: could not build arguments ... initDatabase ...
> ```
> 等 2~3 分钟重启次数就不再增长。**不要看到 CrashLoopBackOff 就以为部署失败。**

### 10.3 ⚠️ Service 名没有 release 前缀（容易踩）

实测 Service 名是**裸名**，不是 `weknora-` 前缀：

| 资源类型 | 命名规则 | 实例 |
|---|---|---|
| Deployment / Pod | `<release>-<组件>` | `weknora-app`、`weknora-postgres` |
| **Service** | **裸名** | `app`、`frontend`、`docreader`、`postgres`、`redis` |

```
NAME                TYPE        CLUSTER-IP       PORT(S)
service/app         ClusterIP   10.105.177.214   8080/TCP
service/docreader   ClusterIP   10.98.190.144    50051/TCP
service/frontend    ClusterIP   10.105.66.164    80/TCP
service/postgres    ClusterIP   10.104.140.31    5432/TCP
service/redis       ClusterIP   10.104.249.156   6379/TCP
```

> 所以 `kubectl port-forward svc/weknora-frontend` 是**错的**，要用 `svc/frontend`。
> 这也解释了 app 日志里的 `host=postgres` —— 它连的就是裸名 Service。

### 10.4 验证清单（本次实测结果）

```bash
# 1. 全局状态
kubectl get pods,svc,ingress,pvc -n weknora

# 2. Ingress 路由规则
kubectl describe ingress weknora -n weknora | grep -A6 "Rules:"

# 3. 集群内直连前端（注意 Service 是裸名 frontend）
kubectl port-forward -n weknora svc/frontend 18080:80 &
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/
curl -s http://127.0.0.1:18080/ | grep -oE "<title>[^<]*</title>"

# 4. 集群内直连 app
kubectl port-forward -n weknora svc/app 18081:8080 &
curl -s http://127.0.0.1:18081/health

# 5. app → docreader 跨 Pod DNS
kubectl exec -n weknora deploy/weknora-app -- getent hosts docreader

# 6. ParadeDB 扩展（确认不是普通 postgres）
kubectl exec -n weknora deploy/weknora-postgres -- \
  psql -U postgres -d weknora -tAc "select extname from pg_extension order by 1;"
```

**实测结果（全部通过）**：

| 检查项 | 结果 |
|---|---|
| 5 个 Pod | 全部 `1/1 Running` |
| 3 个 PVC | 全部 `Bound` |
| Ingress 路由 | `/api` → `app:8080`，`/` → `frontend:80` ✅ |
| 前端首页 | `HTTP 200`，`<title>WeKnora</title>` ✅ |
| app `/health` | `HTTP 200`，`{"status":"ok"}` ✅ |
| 走 Ingress 访问 `/` | `HTTP 200` + 正确标题 ✅ |
| 走 Ingress 访问 `/api/*` | `HTTP 401 {"error":"Unauthorized: missing authentication"}` ✅（401 说明请求确实到达后端并被鉴权中间件拦截，链路是通的） |
| app → docreader DNS | 解析到 `10.98.190.144 docreader.weknora.svc.cluster.local` ✅ |
| ParadeDB 扩展 | `pg_search`、`vector`、`postgis`、`pg_ivm`、`pg_trgm`、`uuid-ossp`… ✅ |

### 10.5 访问 Web UI（本集群的可行方式）

**问题**：本集群的 `ingress-nginx-controller` 是 **ClusterIP**，没有 NodePort：

```
NAME                       TYPE        CLUSTER-IP      PORT(S)
ingress-nginx-controller   ClusterIP   10.103.71.122   80/TCP,443/TCP
```

所以外部**无法直接**通过节点 IP 访问 Ingress。

**方式一（推荐，非侵入）**：port-forward 到 ingress 控制器，并把 hosts 指过去

```bash
# 在 172.30.30.21 上执行（--address 0.0.0.0 才能被外部访问）
kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

```
# Windows hosts 文件（需管理员）：C:\Windows\System32\drivers\etc\hosts
172.30.30.21   weknora.local
```
浏览器开 `http://weknora.local:8080`（nginx-ingress 会自动剥掉端口号再匹配 host）。
**已实测通过：首页 200 + `<title>WeKnora</title>`。**

> 好处：`/` 和 `/api` 都由 Ingress 分流，前端 SPA 调后端不需要额外改动。
> 缺点：port-forward 关掉就断，属于临时通道。

**方式二（永久，但改共享集群配置，需谨慎）**：把 `ingress-nginx-controller` 改成 NodePort。
⚠️ 这是**集群级共享组件**，其他应用也在用，改动会影响别人 —— **动手前务必确认**。

> **不要**直接 port-forward `svc/frontend` 访问：那样只有静态页面，SPA 发往 `/api` 的请求会 404，
> 因为 `/api` 的分流是在 **Ingress** 层做的，不是 frontend 容器的 nginx。

---

## 十一、排障手册

### 11.1 铁律

> **任何异常，先跑这两条，再动手。禁止盲目重试。**

```bash
kubectl describe pod -n weknora <pod-name>
kubectl logs -n weknora <pod-name> --tail=100
kubectl logs -n weknora <pod-name> --previous    # 上一个崩溃实例的日志
```

### 11.2 常见故障对照表

| 现象 | 根因 | 排查命令 | 解法 |
|---|---|---|---|
| Pod `Pending`，事件显示 `no persistent volumes available` | PVC 没绑上 | `kubectl get pvc -n weknora`、`kubectl describe pvc -n weknora` | 检查 PV 是否存在、`storageClassName` 是否一致、`volumeName` 是否写了 |
| Pod `Pending`，事件 `didn't match node selector` | nodeSelector 的节点名写错 | `kubectl get nodes` 对比 `kubernetes.io/hostname` 标签 | 改 values 里的 hostname（本环境是 `base`） |
| `ErrImagePull` / `ImagePullBackOff` | 镜像没导入 containerd，或只有镜像站名没 tag 回 `docker.io/` | `sudo ctr -n k8s.io i ls -q \| grep weknora` | 跑 `~/weknora-pull-images.sh` |
| `CrashLoopBackOff` + 日志 `password authentication failed` | `dbPassword` 与 postgres 数据卷里已有的密码不一致 | `kubectl logs -n weknora deploy/weknora-postgresql` | **删掉 PVC 和 NFS 目录重来**（会丢数据），或把 Secret 改回旧密码 |
| `CrashLoopBackOff` + 日志 `SYSTEM_AES_KEY must be 32 bytes` | `systemAesKey` 长度不对 | `kubectl logs` 里的具体报错 | 用 `openssl rand -hex 16` 重新生成 |
| app `OOMKilled`（`describe` 里 `Reason: OOMKilled`） | 内存 limit 太小 / 节点内存不足 | `kubectl top pods -n weknora`、`kubectl describe node base` | 调大 `app.resources.limits.memory`；确认 neo4j 是关的 |
| postgres `OOMKilled` | ParadeDB 吃内存 | `kubectl top pod` | 调大 postgres limit（至少要 1Gi） |
| app 日志 `dial tcp: lookup docreader ... no such host` | docreader Service 被改名了 | `kubectl get svc -n weknora` | 保证 Service 名是 `docreader`，别用 `fullnameOverride` |
| `helm install` 报 `cannot re-use a name` | release 已存在 | `helm list -n weknora` | `helm upgrade --install` 改用 upgrade |
| 升级后改了密码却不生效 | secrets.yaml 用了 `lookup`，保护已有 Secret | `kubectl get secret -n weknora` | 先删 Secret 再 `helm upgrade` |
| app 反复 `CrashLoopBackOff`，日志 `connect: connection refused` + `panic` | app 先于 postgres 启动，连不上库直接 panic | `kubectl logs -n weknora deploy/weknora-app --previous` | **预期行为，等 2~3 分钟自愈**，重启次数停止增长即为正常 |
| `port-forward svc/weknora-frontend` 报 `not found` | Service 是裸名，不带 release 前缀 | `kubectl get svc -n weknora` | 用 `svc/frontend`、`svc/app` |
| 外部访问 `weknora.local` 超时 | ingress-nginx 是 ClusterIP，无 NodePort | `kubectl get svc -n ingress-nginx` | `port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80` + hosts（见 10.5） |
| 转 frontend 能开页面但 `/api` 404 | `/api` 分流在 Ingress 层，不在 frontend 的 nginx | — | 要测就 port-forward **ingress 控制器**，别只转 frontend |
| `ctr` 报 `flag provided but not defined: -concurrency` | 参数名写错 | — | 正确是 `--max-concurrent-downloads` |

### 11.3 查看 Secret 里的真实值（排障用）

```bash
# 只看 DB 密码
kubectl get secret -n weknora weknora-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo

# 看全部 key
kubectl get secret -n weknora weknora-secrets -o jsonpath='{.data}' | tr ',' '\n'
```

### 11.4 验证 ParadeDB 扩展是否就位

```bash
kubectl exec -n weknora deploy/weknora-postgresql -- \
  psql -U postgres -d weknora -c '\dx'
# 期望看到 pg_search / vector 等扩展
```

---

## 十二、完整踩坑清单

| # | 坑 | 现象 | 根因 | 解法 |
|---|---|---|---|---|
| 1 | **SC 有但 provisioner 没跑** | PVC 永远 Pending | `local-path` 声明 `nfs-client` 但无对应 Pod，且 `VolumeBindingMode: Immediate` | 手工建 PV + PVC，用 `volumeName` 强制绑定 |
| 2 | **github.com 不通** | `git clone` 卡死 | 网络封锁 | 改用 `raw.githubusercontent.com` 逐文件下载 |
| 3 | **Docker Hub 不通** | `docker pull` 超时 | 网络封锁 | 走 `docker.m.daocloud.io` 镜像站 |
| 4 | **镜像站名 ≠ 规范名** | `ErrImagePull` | 只拉了 `docker.m.daocloud.io/xxx`，没 tag 成 `docker.io/xxx` | 拉完必须 `ctr -n k8s.io i tag` |
| 5 | **ctr 忘记 `-n k8s.io`** | 导入了但 k8s 看不见 | k8s 用 `k8s.io` namespace，不是 `default` | 所有 ctr 命令都带 `-n k8s.io` |
| 6 | **SYSTEM_AES_KEY 长度** | 启动即崩 | 必须**恰好 32 字节** | `openssl rand -hex 16` |
| 7 | **SYSTEM_AES_KEY 丢失** | 历史加密数据解不开 | 它加密了租户 api_key / 模型 key | 迁移前务必备份该值 |
| 8 | **Secret 用 lookup 保护** | 改了 values 密码却不生效 | `secrets.yaml` 用 `lookup` 保留已有 Secret | 要改密码先删 Secret 再 upgrade |
| 9 | **Neo4j 内存** | 节点 OOM | 默认 limit 2Gi，实际吃更多；还要 10Gi 存储 | 不开 GraphRAG 就 `neo4j.enabled: false` |
| 10 | **ParadeDB ≠ postgres** | 换成官方 postgres 后 app 崩 | 缺 `pg_search`/`pgvector` 扩展 | 必须用 `paradedb/paradedb` |
| 11 | **docreader Service 硬编码** | app 找不到 docreader | Service 名写死为 `docreader`，不走 fullname | 别用 `fullnameOverride` |
| 12 | **误判 docreader `localhost:50051`** | 以为是跨 Pod 连不通 | 那只是**容器内**健康探针 | 无需修改；app 走 `DOCREADER_ADDR=docreader:50051` |
| 13 | **全导镜像很慢** | 单个镜像 30s~几分钟 | 镜像站带宽 + ParadeDB 镜像本身大 | 放后台跑，别干等 |
| 14 | **nodeSelector 写错节点名** | Pod 一直 Pending | `kubernetes.io/hostname` 的值是 `base` 不是 `k8s-base` | `kubectl get nodes` 先确认 |
| 15 | **镜像拉取永久挂死** | `crictl pull` 20 分钟毫无反应，不报错也不退出 | containerd/crictl **默认无拉取超时**，连接断了会一直等 | 采样 `/var/lib/containerd` 增量确认真死 → kill → 换镜像站（见 9.4） |
| 16 | **daocloud 大 layer 断流** | 小镜像正常，docreader（740 MiB 单层）反复卡死 | 镜像站对大 layer 断流 | 换 `docker.1ms.run`，已完成的 layer 会 `exists` 复用 |
| 17 | **ctr 并发参数名写错** | 报 `flag provided but not defined: -concurrency` | 正确参数是 `--max-concurrent-downloads` | 用对名字 |
| 18 | **单次拉取超时设太短** | 反复超时重启，永远拉不完 | 1.5 GiB @ 500 KB/s 需 ~44 分钟，设了 900 s | 超时给 3600 s，并且 nohup 脱离 ssh |
| 19 | **只看 `ingest/` 判进度会误判** | 目录不动但实际在下载 | containerd 1.7 走 transfer service，落盘路径不止 ingest | 改看整个 `/var/lib/containerd` 的增量 |
| 20 | **Service 名没有 release 前缀** | `port-forward svc/weknora-frontend` 找不到 | Service 是裸名 `frontend`/`app`/`postgres`，只有 Pod/Deployment 才带 release 前缀 | 用 `svc/frontend` |
| 21 | **ingress-nginx 是 ClusterIP** | 外部访问 Ingress 超时 | 该集群 ingress 控制器没暴露 NodePort | port-forward `--address 0.0.0.0` + hosts（见 10.5）；改 NodePort 属共享组件变更，需先确认 |
| 22 | **app 早期 CrashLoopBackOff** | 误以为部署失败 | app 连不上未就绪的 postgres 直接 panic | 预期行为，等 2~3 分钟自愈；真要排查看 `--previous` 日志里的 `connection refused` |
| 23 | **port-forward 只测 frontend 会导致 /api 404** | SPA 打不开 API | `/api` 分流在 Ingress 层，不在 frontend 的 nginx | 要测就 port-forward **ingress 控制器**，别只转 frontend |

---

## 十三、完成清单与后续动作

### 13.1 全流程进度（已全部完成）

```
[✅] 环境预检（k8s v1.35.0 / IngressClass nginx / 查明 SC 是空壳）
[✅] Helm v3.16.3 安装
[✅] Chart 下载到 ~/weknora-helm（helm lint 通过）
[✅] NFS 目录创建（master01:/nfs/pv01/weknora-*）
[✅] namespace weknora + 3 PV + 3 PVC（全部 Bound）
[✅] ~/weknora-values.yaml 生成，helm template 渲染验证通过
[✅] 镜像落盘 containerd 5/5（docreader 换 1ms.run 才成功）
[✅] helm install（一次成功，STATUS: deployed）
[✅] Pod 验证：5/5 Running，app 早期重启 2 次后稳定
[✅] 功能验证：前端 200 / app health ok / Ingress 分流正确 / ParadeDB 扩展就位
[✅] 外部访问打通（port-forward ingress 控制器 + Windows hosts）
[✅] 管理员账号创建（admin@weknora.local，tenant owner）
[✅] 模型配置（DeepSeek 对话 + 百炼 text-embedding-v4 向量，debug 接口均 200）
[✅] 端到端 RAG 验证（建库 → 传文档 → 解析 completed → 提问答对且带引用）
[✅] 输出本部署文档 + 架构与部署结构图文档
```

### 13.2 当前运行状态速查

```bash
ssh candidate@172.30.30.21

kubectl get pods,svc,ingress,pvc -n weknora
helm list -n weknora

# 模型配置是否还在（PUT 全量替换很容易把它打残，见 17.5）
kubectl exec -n weknora deploy/weknora-postgres -- psql -U postgres -d weknora \
  -c "SELECT name,type,source,parameters->>'base_url' FROM models;"
# 期望两行：
#   deepseek-flash    | KnowledgeQA | remote | https://api.deepseek.com/v1
#   text-embedding-v4 | Embedding   | remote | https://dashscope.aliyuncs.com/compatible-mode/v1
```

### 13.3 日常操作

```bash
# 临时对外访问（改代码/演示时用）
kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80
# 浏览器：http://weknora.local:8080  （Windows hosts 加 172.30.30.21 weknora.local）

# 看日志
kubectl logs -n weknora deploy/weknora-app -f
kubectl logs -n weknora deploy/weknora-docreader -f

# 改配置后升级
helm upgrade weknora ~/weknora-helm -n weknora -f ~/weknora-values.yaml

# 卸载（会保留 PVC 和 NFS 数据，因为 PV 的 ReclaimPolicy 是 Retain）
helm uninstall weknora -n weknora
```

> ⚠️ 卸载后重装若改了 `dbPassword`，postgres 会因为数据卷里是旧密码而**认证失败**。
> 要么保持一致，要么连 PVC 和 NFS 目录一起清掉（会丢数据）。`systemAesKey` 同理，且丢了历史密文就解不开了。

### 13.4 部署之后补做的三件事（已完成）

这三件原列在「待办」里，现已全部完成 —— 记录在此是为了说明**它们不是可选项**：

| # | 待办 | 为什么必须做 | 完成情况 |
|---|---|---|---|
| 1 | **配置模型服务** | 不配就只能打开页面，一问三不知 | ✅ 见**第十七章**（DeepSeek 对话 + 百炼向量） |
| 2 | **外部访问方式** | 集群内能访问不等于用户能用 | ✅ port-forward ingress 控制器 + Windows hosts（见 10.5 / 13.5） |
| 3 | **验证真实链路** | 光「端口 200」不等于「能问答」 | ✅ 上传文档 → 解析 completed → 提问答对且带引用（见 17.6） |

> **教训**：这三件事里有 **两件**（1 和 3）都栽在同一个思维误区上 ——
> **把「组件起来了」当成「功能可用了」**。
> 第 1 件的坑尤其深：我一度按 docker-compose 的思路把 `LLM_BASE_URL` 写进 `values.yaml`，
> 后来读 `.env.example` 才确认**单独设这些 env 完全无效**，模型必须写进数据库。
> 详见第十章第 15 条、第十七章 17.1。

### 13.5 当前对外访问方式（唯一可行路径）

```bash
# 在 172.30.30.21 上（当前 PID 63022，监听 0.0.0.0:8080）
kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
```

Windows hosts（`C:\Windows\System32\drivers\etc\hosts`）加一行：

```
172.30.30.21   weknora.local
```

浏览器打开 **`http://weknora.local:8080`**（实测 200 + `<title>WeKnora</title>`）。

- 账号：`admin@weknora.local` / `WeKnora@2026`（tenant owner）
- ⚠️ **这条 port-forward 一断，外部访问就没了**（集群内部不受影响）。VM 重启后要手动重起
- ⚠️ 不能只转发 `svc/frontend` —— `/api` 的分流在 Ingress 层，那样会导致 API 全 404（见 5.2）

### 13.6 仍然没做的（不影响当前可用性）

1. **ingress-nginx 改 NodePort**：让外部访问不依赖 port-forward。但它是**集群共享组件**（325 天前装，
   其他应用也在用），**动手前必须确认影响面**。当前用 port-forward 过渡是刻意的非侵入选择。
2. **系统管理员权限**：当前账号是租户 owner。要 system admin 需给 app 加 `WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL`
   环境变量后重启（幂等，只升不降），见 17.2。
3. **模型 `is_default` 仍是 `false`**：PUT 不接受该字段（只由 `builtin_models.yaml` 声明式设置）。
   无害 —— 建库时手动选 embedding、提问时手动选 chat 即可（见 17.5）。
4. **宿主机 C 盘爆满未清理**：110 G 仅剩 0.2~0.4 G，只做了只读扫描，未删任何东西。
   pagefile 无法增长会连带影响宿主机与虚拟机稳定性，**优先级高于本文档其他所有事项**。分级清理项见附录 B（15.3），
   用户明确要求「不要删除重要的、不要弄崩电脑」—— 动手前必须逐项确认。

---

## 十四、附录 A：从零重建全流程（命令速查）

```bash
# ========== 0. 登录 ==========
ssh candidate@172.30.30.21

# ========== 1. 环境预检 ==========
kubectl get nodes -o wide
kubectl get sc
kubectl get ingressclass
helm version --short || echo "helm 未装，见下一步"

# ========== 2. 装 Helm ==========
curl -fsSL -o /tmp/helm.tar.gz https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
sudo install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm

# ========== 3. 下载 chart（github.com 不通，走 raw） ==========
mkdir -p ~/weknora-helm/templates && cd ~/weknora-helm
BASE="https://raw.githubusercontent.com/Tencent/WeKnora/main/helm"
curl -fsSL -o Chart.yaml  "$BASE/Chart.yaml"
curl -fsSL -o values.yaml "$BASE/values.yaml"
curl -fsSL -o README.md   "$BASE/README.md"
for f in _helpers.tpl app.yaml docreader.yaml frontend.yaml ingress.yaml \
         neo4j.yaml pvc.yaml redis.yaml secrets.yaml serviceaccount.yaml postgres.yaml; do
  curl -fsSL -o "templates/$f" "$BASE/templates/$f"
done
helm lint ~/weknora-helm

# ========== 4. NFS 目录（在 master01 上） ==========
ssh 172.30.30.11   # 或从 base 跳
sudo mkdir -p /nfs/pv01/weknora-{postgres,redis,data-files}
sudo chmod 0777 /nfs/pv01/weknora-{postgres,redis,data-files}

# ========== 5. 命名空间 + PV/PVC ==========
kubectl create namespace weknora
# 写 ~/weknora-storage.yaml（内容见第六章）
kubectl apply -f ~/weknora-storage.yaml
kubectl get pvc -n weknora        # 必须全 Bound 才能往下走

# ========== 6. values.yaml ==========
# 生成密钥
DB_PASS=$(openssl rand -hex 16); REDIS_PASS=$(openssl rand -hex 16)
JWT_SEC=$(openssl rand -hex 32); AES_KEY=$(openssl rand -hex 16)
echo -n "$AES_KEY" | wc -c        # 必须输出 32
# 写 ~/weknora-values.yaml（内容见 7.4），填入上面的密钥

# ========== 7. 渲染校验 ==========
helm template weknora ~/weknora-helm -n weknora -f ~/weknora-values.yaml > /tmp/rendered.yaml
grep -n "claimName" /tmp/rendered.yaml   # 三个 claimName 要指向手工 PVC

# ========== 8. 镜像落盘（本步最耗时，务必用多镜像站脚本） ==========
# 写 ~/weknora-pull-images.sh（内容见 9.2，内含 MIRRORS 数组 + timeout + 重试）
#   注意：MIRRORS 顺序是 docker.1ms.run 在前、daocloud 在后 —— daocloud 在大 layer 上会断流（见 9.4）
#   拉取前先确认没有挂死的残留进程：ps aux | grep ctr
bash ~/weknora-pull-images.sh
sudo ctr -n k8s.io i ls -q | grep -E "weknora|paradedb|redis:7-alpine"   # 5 行，且都要是 docker.io/ 开头

# ========== 9. 安装 ==========
helm install weknora ~/weknora-helm -n weknora -f ~/weknora-values.yaml
kubectl get pods -n weknora -w

# ========== 10. 验证 ==========
kubectl get pvc,ingress -n weknora
# 注意 Service 是裸名（app / frontend / docreader / postgres / redis），不带 weknora- 前缀
kubectl port-forward -n weknora svc/frontend 8081:80 &
curl -s http://localhost:8081/ | grep -oE "<title>[^<]*</title>"     # 期望 <title>WeKnora</title>
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/      # 期望 200

# ========== 11. 外部访问（hosts + 转发 ingress 控制器） ==========
# ingress-nginx 是 ClusterIP，没有 NodePort，所以外部要转发控制器而不是 frontend
# （只转发 frontend 的话 /api 会 404 —— 分流在 Ingress 层）
kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
# Windows 上用管理员权限改 C:\Windows\System32\drivers\etc\hosts：
# 172.30.30.21   weknora.local
# 浏览器打开 http://weknora.local:8080
```

---

## 十五、附录 B：本次附带的环境治理记录

### 15.1 磁盘扩容（LVM 在线扩）

三个节点的虚拟磁盘都是 50 G，但 LVM 卷组里还有 24 G 没分配。**不用动 VMware，不用删快照**，直接在线扩：

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

- `base`：24 G → 48 G（现可用 27 G）
- `master01`：24 G → 48 G

> ext4 支持挂载状态下在线扩容，不需要 umount。

### 15.2 VMware 快照与磁盘扩容的冲突

**VMware 快照存在时，「扩展磁盘」和部分硬件变更会被禁用。** 这是本次一开始以为「磁盘不能扩」的原因。

两种操作别搞混：
- **Delete snapshot**：合并回当前状态，**保留**现在的工作
- **Revert To snapshot**：回滚到快照点，**丢失**之后的工作

### 15.3 宿主机 C 盘爆满（110 G 用满，剩 0.2 G）

排查结果（只做了扫描，未删任何东西）：

| 目录 | 占用 |
|---|---|
| `C:\Users` | ~50 G |
| `C:\Windows` | 20.2 G |
| **`C:\System Volume Information`** | **10.06 G** ← 系统还原点/卷影副本 |
| `C:\Program Files` | 9.87 G |
| `C:\Program Files (x86)` | 5.44 G |
| `C:\ProgramData` | 2.21 G |
| `C:\Recovery` | 0.49 G |

用户目录内的真实大头（**已排除 NTFS 交叉点重复计数**）：

| 目录 | 占用 |
|---|---|
| `AppData` | 27.87 G |
| `PyCharmMiscProject` | 6.13 G |
| `Downloads` | 4.68 G |
| `xwechat_files` | 3.87 G |
| `.ollama` | 1.80 G |
| `Desktop` | 1.22 G |

> **重要教训**：`C:\Users\Administrator` 下的 `Local Settings`、`Application Data`，以及 `AppData\Local\Application Data` 都是 **NTFS 交叉点（junction）**，只是旧路径兼容用的链接。
> 递归统计时会**重复计算**，必须用 `Attributes -band [IO.FileAttributes]::ReparsePoint` 过滤掉，否则数字完全失真（曾出现 Local/Roaming/LocalLow 都报 30.44 G 的荒谬结果）。
> 另一个 PowerShell 坑：`Measure-Object` 统计文件大小必须写 `-Property Length`，写裸 `Length` 会报 `GenericMeasurePropertyNotFound`。

**可安全清理的候选**（待用户确认后再动）：
- 明确安全：`%TEMP%`（1.49 G）、`C:\Windows\Temp`（0.98 G）、npm-cache（0.81 G）、CrashDumps（1.8 G）、pip cache、回收站
- 需确认：Downloads（4.68 G）、`xwechat_files`（3.87 G）、PyCharmMiscProject（6.13 G）
- 走标准工具：`System Volume Information` 10 G → 通过「系统保护」限制还原点占用上限，或用 `DISM /Online /Cleanup-Image /StartComponentCleanup` 清理 WinSxS
- **绝对不要动**：`C:\Windows\Installer`、`WinSxS`、`Program Files`

> 注意：C 盘剩余 0.2 G 时，Windows 页面文件（pagefile.sys）无法正常增长，会连带影响宿主机性能和虚拟机稳定性。这属于**必须尽快解决**的问题，优先级高于 WeKnora 部署。

---

## 十六、关键结论速记

1. **国内网络部署 k8s 应用，90% 的时间花在「把镜像搞进去」上。** 镜像站 + retag 是必备套路。
2. **SC 显示存在 ≠ 动态供应可用。** 一定要 `kubectl get pods -A | grep provisioner` 验证。
3. **`helm template` 是安装前最好的保险。** 能提前发现 PVC、Ingress、env 的所有问题。
4. **`existingClaim` 是 chart 对接现有存储的标准入口**，比自己改模板干净得多。
5. **Neo4j / 向量库这类「可选重组件」在内存紧张的集群上必须显式关掉**，否则 OOM 排查很痛苦。
6. **红线「先 describe + logs 再动手」在实践中救了很多次** —— 大部分 k8s 故障在事件和日志里写得明明白白。
7. **NTFS 交叉点会让磁盘统计彻底失真**，Windows 上做容量分析必须先过滤 reparse point。
8. **镜像站不是等价的：小镜像都行，大 layer 见真章。** daocloud 拉小镜像没问题，docreader 的 740 MiB 单层卡死两次；换 `docker.1ms.run` 立刻稳。**拉大镜像前先备好备选镜像站。**
9. **「进程还活着」不等于「在下载」。** 判断卡死要看**增量**：ctr 的 `total` 是否在涨、`/var/lib/containerd` 是否变大、进程 `write_bytes` 是否为 0。三层指标互相印证。
10. **containerd 默认没有拉取超时**，这是设计如此，不是 bug。所以 pull 一定要用 `timeout` 包住，否则可能永久挂住。
11. **换镜像站重拉不会重下已完成的部分** —— 镜像层内容寻址，已完成的显示 `exists` 直接复用。
12. **k8s 里 Service 名和 Pod 名不一定同前缀。** 本 chart 的 Service 是裸名（`app`/`postgres`），Pod 才带 release 前缀。`port-forward`/DNS 用的是 **Service 名**。
13. **「系统活着」和「功能可用」是两件事。** 端口 200 只说明进程在跑；`/api` 返回 401 才说明鉴权中间件真的在处理请求。验证要打到业务路径上。
14. **改共享组件（ingress-nginx 类型、集群级配置）前必须先确认影响面**，别为了自己方便动别人也在用的东西 —— 用 port-forward 这种非侵入方式过渡。
15. **模型的 `PUT` 是全量替换，不是打补丁。** 只想改一个字段而只传那个字段，会把其余字段全部清空（本次把 `type`/`source`/`base_url` 全打没了，导致 `unsupported embedder source`）。**PUT 前先把完整对象读出来，改完整体回写。**
16. **报错信息里的空值往往就是答案。** `unsupported embedder source: `（冒号后空白）直接告诉我们是 source 为空 —— 顺着它查 DB 比读源码快。
17. **「预览可用」不等于「入库了」。** API 返回体是拿请求回显拼的，DB 里可能根本没写进去。**怀疑配置没生效时，直接 `psql` 查库**，别只看 API 响应。
18. **LLM 和 Embedding 是两个独立的供应商。** DeepSeek 只有对话模型、没有 embedding 接口（实测 `/v1/embeddings` → 404）。做 RAG 必须另配一家向量模型。

---

## 十七、模型服务配置（部署后才做的关键一步）

> **没有这一章，WeKnora 能打开页面但一问三不知。**

### 17.1 先记住：模型不在 values.yaml 里配

WeKnora 的模型是**存在数据库里**（`models` 表）的，通过 **Web UI** 或 REST API 管理。

`docker-compose` 里的 `LLM_BASE_URL` / `EMBEDDING_BASE_URL` 这些 env **单独设置完全无效** —— 只有当你在容器里另外挂载 `config/builtin_models.yaml`（用 `${LLM_BASE_URL}` 占位引用）时才会被读到。本 chart 不挂载该文件，所以走 UI/API。

两个可配模型类型（RAG 最少要前两个）：

| 类型 | 作用 | 不配的后果 |
|---|---|---|
| `KnowledgeQA` | 对话/问答 | 不能提问 |
| `Embedding` | 文档向量化 | 文档卡在解析、检索为空 |
| `Rerank` | 重排（可选） | 检索质量略降，不影响跑通 |

### 17.2 创建管理员账号

首次访问 `http://weknora.local:8080` 会走到注册页，直接注册即可（默认 `registration_mode=self_serve`）。
用 API 注册：

```bash
curl -s -X POST http://weknora.local:8080/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","email":"admin@weknora.local","password":"<你的密码>"}'
```

登录拿 token：

```bash
TOK=$(curl -s -X POST http://weknora.local:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@weknora.local","password":"<你的密码>"}' | python -c "import sys,json;print(json.load(sys.stdin)['token'])")
```

> 注册出来的用户是**租户 owner，不是 system admin**。租户级操作（建模型、建库）权限够用；
> 要系统管理员权限，设 `WEKNORA_BOOTSTRAP_SYSTEM_ADMIN_EMAIL` 环境变量后重启 app（幂等，只升不降）。

### 17.3 创建模型（本次实测可用的参数）

**对话模型 —— DeepSeek 官方 API：**

```bash
curl -s -X POST http://weknora.local:8080/api/v1/models \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{
  "name": "deepseek-flash",
  "display_name": "DeepSeek V4 Flash",
  "type": "KnowledgeQA",
  "source": "remote",
  "parameters": {
    "base_url": "https://api.deepseek.com/v1",
    "api_key": "<DeepSeek key>",
    "provider": "deepseek",
    "max_output_tokens": 8192
  }
}'
```

**向量模型 —— 阿里百炼：**

```bash
curl -s -X POST http://weknora.local:8080/api/v1/models \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{
  "name": "text-embedding-v4",
  "display_name": "百炼 text-embedding-v4",
  "type": "Embedding",
  "source": "remote",
  "parameters": {
    "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "api_key": "<DashScope key>",
    "provider": "aliyun",
    "embedding_parameters": { "dimension": 1024 }
  }
}'
```

- `type` 取值：`KnowledgeQA` / `Embedding` / `Rerank` / `VLLM` / `ASR`
- `source` 取值：`remote` / `local`。**留空会报 `unsupported embedder source: `**
- `provider` 取值（共 27 个）：`deepseek` / `aliyun` / `zhipu` / `volcengine` / `siliconflow` / `openai` / `generic` … —— `generic` = 任意 OpenAI 兼容端点
  `GET /api/v1/models/providers` 可列全
- 查 DeepSeek 有哪些模型：`GET https://api.deepseek.com/v1/models` → 实测只有 `deepseek-flash`、`deepseek-v4-pro`

### 17.4 测试模型连通性

debug 接口是 **multipart 表单，不是 JSON**（传 JSON 会报 `query cannot be empty`）：

```bash
# 对话：200 + ok:true
curl -s -X POST "http://weknora.local:8080/api/v1/models/<LLM_ID>/debug" \
  -H "Authorization: Bearer $TOK" -F "input=用一句话说明你是什么模型"

# 向量：200 + observations.dimension=1024
curl -s -X POST "http://weknora.local:8080/api/v1/models/<EMB_ID>/debug" \
  -H "Authorization: Bearer $TOK" -F "input=测试"
```

### 17.5 ⚠️ 修改模型必须全量 PUT

```bash
# 正确做法：先读全量，改完整体回写
curl -s "http://weknora.local:8080/api/v1/models/<ID>" -H "Authorization: Bearer $TOK"
# ...修改字段...
curl -s -X PUT "http://weknora.local:8080/api/v1/models/<ID>" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '<完整对象，含 name/type/source/description/parameters 全部字段>'
```

**反面案例（本次踩的）**：只想把模型设成默认，发了

```bash
-d '{"is_default": true}'      # ❌ 灾难
```

结果 `type`、`source`、`parameters.base_url`、`provider`、`dimension` **全被清空**，
文档解析直接报 `unsupported embedder source:`。
而且 `is_default` **也没设上**（PUT 不认这个字段）—— 白丢一轮。

> `is_default` 只由 `builtin_models.yaml` 的声明式配置设置；UI/API 建的模型默认 `false`，
> 建知识库时手动选 embedding、提问时手动选 chat 即可，不影响使用。

**配置写没写进库，直接查 DB 最准**（API 响应会拿请求回显骗你）：

```bash
kubectl exec -n weknora deploy/weknora-postgres -- psql -U postgres -d weknora \
  -c "SELECT name, type, source, parameters->>'base_url' AS base_url, parameters->>'provider' AS provider FROM models;"
```

### 17.6 端到端验证（这才是真的通了）

```bash
# 1) 建知识库（必须指定 embedding 模型）
curl -s -X POST http://weknora.local:8080/api/v1/knowledge-bases \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"name":"测试库","description":"","embedding_model_id":"<EMB_ID>"}'

# 2) 传文档
curl -s -X POST "http://weknora.local:8080/api/v1/knowledge-bases/<KB_ID>/knowledge/file" \
  -H "Authorization: Bearer $TOK" -F "file=@ops-manual.md"

# 3) 轮询解析状态，直到 completed（解析失败一般是 embedding 模型没配好）
curl -s "http://weknora.local:8080/api/v1/knowledge/<KNOWLEDGE_ID>" -H "Authorization: Bearer $TOK"
```

**4) 提问 —— 注意字段是复数的 `knowledge_base_ids`（数组）**：

```bash
curl -sN -X POST "http://weknora.local:8080/api/v1/sessions/<SID>/../knowledge-chat/<SID>" ...
# 实际路径：POST /api/v1/knowledge-chat/<session_id>，返回 SSE 流
```

```json
{ "query": "值班电话是多少？", "knowledge_base_ids": ["<KB_ID>"] }
```

> **踩坑**：写成单数 `knowledge_base_id` 不报错，但日志里 `knowledge_base_ids: null`、
> `Built 0 search targets`、`hasKB=false` —— **静默不检索**，模型只能答"没找到相关资料"。
> 排查看这行：`[KnowledgeQA] Creating chat manage object, ... search targets: 0`

SSE 返回体结构：

```json
{"id":"...","response_type":"thinking|answer|references|agent_query","content":"...","done":false,"data":{...}}
```

实测结果（本次）：

```
问：值班电话是多少？
答：根据检索到的资料，值班电话信息如下：
    **一线值班电话：400-888-6666，转 7 号线。**
```

> RAG 库文档如果很小（几百字节），会只切成 1 个块 —— 任何问题都能召回，属正常。
> 混合检索（`POST /knowledge-bases/:id/hybrid-search`）返回的 `score` 是 **RRF 融合分**
> （单条命中约 `1/61≈0.0164`），**不是余弦相似度**，别拿去跟 `vector_threshold` 比。

### 17.7 模型配置排查速查

| 现象 | 根因 | 怎么确认 |
|---|---|---|
| 文档一直 `processing`，docreader 侧无任何请求 | embedding 模型无效 | `kubectl logs -n weknora deploy/weknora-app \| grep document_process` |
| 日志 `unsupported embedder source: `（冒号后空白） | 模型的 `source` 字段为空 | `psql` 查 `models` 表的 `source` 列 |
| 日志 `processChunks get embedding model failed` | 同上 | 同上 |
| 能提问但总答"没找到相关资料" | 请求里 `knowledge_base_ids` 是空的 | 日志 `Built 0 search targets` |
| debug 接口报 `query cannot be empty` | 用了 JSON，应为 multipart `-F input=` | — |
| `PUT /models/:id` 后模型整个废掉 | PUT 是全量替换，漏传的字段被清空 | `psql` 对比 `parameters` 内容 |

