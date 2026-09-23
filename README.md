# WeKnora 私有化部署 —— 配置归档 + GitHub Actions CD

把腾讯开源 [WeKnora](https://github.com/Tencent/WeKnora)（企业级 LLM 知识平台：RAG + ReAct Agent）
用 Helm 部署到目标 3 节点 k8s 集群，并接上 GitHub Actions 自动化流水线（`git push` → `helm upgrade`）。

**当前状态**：✅ 部署完成 · ✅ 模型已配 · ✅ 端到端 RAG 验证通过 · ✅ CI/CD 流水线打通

---

## 这套东西解决什么问题

```
  本地改配置 ──git push──► GitHub ──长轮询──► base 节点上的 Runner ──► helm upgrade ──► 集群
                                    (出站连接，不开任何入站端口)
```

Self-hosted Runner 主动向 GitHub 长轮询拉活，所以**内网不需要开端口、不需要公网 IP、
不需要 frp/ngrok/Tailscale**。详细原理和完整配置步骤见
[`docs/GitHub-Actions-SelfHosted-Runner方案.md`](docs/GitHub-Actions-SelfHosted-Runner方案.md)。

---

## 目录结构

```
.
├── README.md                              ← 本文件
├── .github/workflows/deploy.yml           ← CD 流水线定义
├── chart/
│   └── weknora-0.1.0.tgz                  ← Helm chart（v0.8.0）
├── deploy/
│   ├── values.yaml                        ← 自定义 values（密钥已脱敏为占位符）
│   ├── values.local.yaml.example          ← 本地密钥覆盖文件模板
│   ├── storage.yaml                       ← 3 个 PV + 3 个 PVC（手工强制绑定）
│   └── pull-images.sh                     ← 多镜像站拉取脚本（幂等，可重跑）
├── docs/
│   ├── WeKnora部署完整文档.md              ← 主文档：全流程 + 排障手册 + 踩坑清单
│   ├── WeKnora架构与部署结构图.md           ← 拓扑图 + 请求链路 + RAG 数据流
│   └── GitHub-Actions-SelfHosted-Runner方案.md  ← Runner + CD 方案（含网络实测）
└── runner/
    └── setup-runner.sh                    ← Runner 安装脚本（幂等）
```

> 文件名里如出现 "CKA" / "VMware" 字样属于历史命名，指的就是这个目标集群，不影响内容。

---

## 快速上手

### 只想手动部署一遍

```bash
# 1. 准备密钥（四个值都要重新生成）
cp deploy/values.local.yaml.example deploy/values.local.yaml
openssl rand -hex 16   # → dbPassword
openssl rand -hex 16   # → redisPassword
openssl rand -hex 32   # → jwtSecret
openssl rand -hex 16   # → systemAesKey  ← 必须恰好 32 字节

# 2. 建 PV/PVC（本集群 SC 是空壳，必须手工建）
kubectl create namespace weknora
kubectl apply -f deploy/storage.yaml

# 3. 拉镜像（github.com/Docker Hub 都不通，走镜像站）
bash deploy/pull-images.sh

# 4. 部署
helm upgrade --install weknora ./chart \
  -n weknora \
  -f deploy/values.yaml \
  -f deploy/values.local.yaml
```

### 想跑 CI/CD 流水线

见 [`docs/GitHub-Actions-SelfHosted-Runner方案.md`](docs/GitHub-Actions-SelfHosted-Runner方案.md)，按第二～五节操作。

---

## 环境事实（2026-09-23 实测）

### 集群

| 节点 | IP | 角色 |
|---|---|---|
| base | 172.30.30.21 | worker，**Runner 所在节点**，操作入口 |
| master01 | 172.30.30.11 | control-plane，NFS 服务端 `/nfs/pv01` |
| node02 | 172.30.30.22 | worker |

k8s v1.35.0 / containerd 1.7.28 / Ubuntu 24.04 / helm v3.16.3 / IngressClass `nginx`

### 网络：github.com 完全不可达（重要）

三个节点实测 `github.com:443` **全部超时**，且不是 IP 级封锁 ——
TCP 能连、TLS 能握手，之后收不到任何响应，属于**按 SNI 的 DPI 阻断**。
所以改 hosts、换 IP 都无效。

| 域名 | 可达 | 用途 |
|---|---|---|
| `github.com` | ❌ | 被封 —— 所以 `actions/checkout` 用不了 |
| `api.github.com` | ✅ | Runner 注册、调 API |
| `pipelines.actions.githubusercontent.com` | ✅ | Runner 长轮询拉活 |
| `codeload.github.com` | ✅ | **拉源码 tarball（替代 checkout）** |

连带影响：Docker Hub 也不通，镜像要走镜像站拉完 retag 回 `docker.io/` 规范名。

---

## 部署形态

- **5 个 Pod**：app / frontend / docreader / postgres / redis，全部钉在 base 节点
- **数据落在 master01** 的 NFS `/nfs/pv01/weknora-*`
- **Neo4j 关闭**（省 2Gi 内存 + 10Gi 存储），由 ParadeDB 一个容器承担关系库 + 全文检索 + 向量库
- **访问**：靠一条 port-forward 顶着（ingress-nginx 是 ClusterIP，无 NodePort）
  ```bash
  kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80
  ```
  然后浏览器开 `http://weknora.local:8080`（Windows hosts 需有 `172.30.30.21 weknora.local`）

### 模型配置不在 values.yaml 里

这是最容易踩的坑：WeKnora 的模型配置存在**数据库 `models` 表**。
chart 不挂 `config/builtin_models.yaml`，所以 `LLM_BASE_URL` 之类的 env **写了也完全无效**，
必须通过 Web UI 或 REST API 配置。

| 用途 | 模型 | 供应商 |
|---|---|---|
| 对话 | `deepseek-flash` | DeepSeek 官方 |
| 向量 | `text-embedding-v4`（1024 维） | 阿里云百炼 DashScope |

> DeepSeek **没有** `/v1/embeddings` 接口（实测 404），做 RAG 必须另配一家向量模型。

---

## ⚠️ 密钥与安全

本仓库是**公开**的，已做脱敏处理：

- `deploy/values.yaml` 里四个密钥全部是 `<CHANGE_ME>` 占位符
- 真实密钥走 **GitHub Secrets**（CI 运行时注入）或本地 `deploy/values.local.yaml`（已 gitignore）
- 全仓库不含任何真实密码 / token / API key

两个容易忽略的点：

1. **CI 用的密钥必须与集群现有数据卷一致**。postgres 只在数据卷为空时初始化密码，
   后续 `helm upgrade` 改密码不会改数据库实际密码，只会让应用连不上 → CrashLoopBackOff。
2. **`systemAesKey` 必须恰好 32 字节**（`openssl rand -hex 16`），且迁移已有数据时必须原样保留 ——
   它加密了数据库里的模型 api_key，换了就永久解不开。

---

## 文档怎么读

| 你想干什么 | 看哪份 |
|---|---|
| 从零重跑一遍部署 | `docs/WeKnora部署完整文档.md` 第十四章 |
| 卡住了 / 报错了 | 同上，第十章排障手册 + 第十一章踩坑清单 |
| 搞懂系统长什么样 | `docs/WeKnora架构与部署结构图.md` 全文 |
| 配 CI/CD 流水线 | `docs/GitHub-Actions-SelfHosted-Runner方案.md` 全文 |
| 页面能开但一问三不知 | `docs/WeKnora部署完整文档.md` 第十七章（模型服务配置） |
