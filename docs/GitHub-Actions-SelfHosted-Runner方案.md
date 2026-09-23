# GitHub Actions Self-hosted Runner 部署方案（零入站端口）

> 目标：`git push` → GitHub Actions → `helm upgrade` 到目标 3 节点集群的 `weknora` namespace
> 约束：不开放任何入站端口、不用内网穿透（frp / ngrok / Tailscale 一律不采用）、命令幂等且无破坏性操作
> 实测日期：2026-09-23

---

## 零、先说一个和你前提不符的实测结论

你的描述是「集群内部可以访问外网 GitHub（但 github.com 偶尔不稳定）」。实测下来比这个严重：

**从集群全部 3 个节点看，`github.com:443` 是完全不可达的，不是"偶尔不稳定"。**

| 域名 | base<br>172.30.30.21 | master01<br>172.30.30.11 | node02<br>172.30.30.22 | 结论 |
|---|---|---|---|---|
| `github.com` | ✗ 超时 | ✗ 超时 | ✗ 超时 | **完全不可达** |
| `api.github.com` | ✓ 200 | ✓ 200 | ✓ 200 | 通 |
| `pipelines.actions.githubusercontent.com` | ✓ 404* | — | — | 通（runner 拉活靠它） |
| `codeload.github.com` | ✓ 200 | — | — | 通，可真下载 |
| `raw.githubusercontent.com` | ✓ 301 | — | — | 通 |
| `objects.githubusercontent.com` | ✓ 404* | — | — | 通 |

\* 返回 404 是根路径的正常响应，**说明服务端有回应**，即链路是通的。

### 这不是"IP 被封"，是 DPI 层阻断

一开始疑似 DNS 解析到了坏 IP（`github.com` → `20.205.243.166`）。但换了 5 个 GitHub 官方 IP 逐个测：

```
20.205.243.166    000  (8s 超时)
140.82.112.3      000   conn=0.27s tls=0.54s  ← TCP 通了、TLS 握手也完成了，然后卡死
140.82.113.4      000
140.82.114.3      000
140.82.121.3      000
```

`140.82.112.3` 那行是关键证据：**连接建立、TLS 握手成功、然后收不到任何 HTTP 响应**。
如果是 IP 级封锁，TCP 就握不上手；能握手但拿不到数据，说明是防火墙按 SNI/域名做的阻断。
结论：**改 hosts 文件、换 IP 都没用，别在这上面浪费时间。**

`git clone` 的直接证据：
```
$ git clone --depth 1 https://github.com/Tencent/WeKnora.git
fatal: unable to access '...': Failed to connect to github.com port 443 after 21086 ms
```

### 这对方案带来两个硬性影响

1. **`actions/checkout@v4` 用不了** —— 它本质就是 `git clone https://github.com/...`。
   解决方案：改用 `codeload.github.com` 拉 tarball（下面 deploy.yml 里已实现）。
2. **runner 安装包不能在本机下载** —— 下载地址 `github.com/actions/runner/releases/download/...`
   正是被阻断的域名。解决方案：从能上网的机器下好再 scp 过去（第二步）。

好消息是：**runner 注册和拉活都不需要 github.com**（走 `api.github.com` 和
`pipelines.actions.githubusercontent.com`，都通）。所以整体方案完全可行。

---

## 一、为什么 Self-hosted Runner 天然满足零信任

这是这个方案最值得讲清楚的一点 —— 不是"配置出来的安全"，而是**协议方向决定的**。

```
   你的集群内网（无公网 IP、无入站端口）
   ┌──────────────────────────────────────┐
   │  base 节点                            │
   │  ┌────────────────────────────────┐  │
   │  │ GitHub Actions Runner 进程      │  │
   │  │  (不监听任何端口)               │  │
   │  └───┬────────────────────────────┘  │
   └──────┼───────────────────────────────┘
          │  ① 长轮询 GET（出站 HTTPS 443）
          │     "有没有派给我的活？"
          ▼
   pipelines.actions.githubusercontent.com
          │  ② 有活 → 返回 job + 一次性 token
          ▼
   Runner 在本地执行 helm upgrade，结果 ③ 出站回报
```

关键在于 **① 是出站长轮询（long-poll）**：runner 主动每隔几秒向 GitHub 发一个"有活吗"的请求，
GitHub 把这个请求**挂起 50 秒**等；一旦有 job 就立刻返回。所以：

- 内网**不需要开任何端口**，NAT 后面也能用
- 不需要公网 IP，不需要内网穿透
- 不需要 VPN / 跳板机

对比一下另外两种常见做法，就知道为什么这个最合适：

| 方案 | 入站端口 | 公网暴露 | 放弃原因 |
|---|---|---|---|
| Webhook 触发 | 需开 443 入站 | 需要 | 直接违反红线 |
| frp / ngrok / Tailscale | 不需要 | 靠第三方中转 | 红线明确禁止 |
| **Self-hosted Runner** | **不需要** | **不需要** | ✅ 采用 |

代价（要认）：**GitHub 侧能看到你的 runner 在线状态，且 job 里的不可信代码是在你内网机器上跑的。**
所以仓库必须是私有的，或者至少别让不信任的人能改 workflow 文件。这一点在本方案里靠
「Public 仓库 + 只跑自己写的 workflow」平衡 —— 见第七节的风险提示。

---

## 二、第一步：拿 Runner 注册 Token

### 网页操作路径

```
仓库页 → Settings → 左侧 Actions → Runners → 右上角 "New self-hosted runner"
→ 选择 Linux / x64 → 页面上 "Configure" 小节里的 --token 后面那串
```

页面会直接给你一条 `./config.sh --url ... --token XXXX` 命令，**复制 token 即可**。

### 更省事的替代：用 PAT 调 API 生成

如果你有 PAT（本方案用的是 `fds19955` 账号的 PAT），不用点网页：

```bash
curl -sS -X POST \
  -H "Authorization: token <你的PAT>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/fds19955/weknora-deploy/actions/runners/registration-token
```

返回 JSON 里的 `"token"` 字段就是。**注意 `api.github.com` 时必须用这个域名**，
别用 `github.com/api/v3`（那个域名不通）。

### Token 的两个坑

1. **只有 1 小时有效期**。拿到了就要立刻用，放着等会儿配置就报 `Token expired`。
   重新生成即可，不影响。
2. **这和 PAT 是两码事**。注册 token 只能用来注册 runner，不能访问代码。
   别把 PAT 塞进 `config.sh`。

---

## 三、第二步：在 base 节点下载并配置 Runner

### 为什么不能直接在节点上下载

再强调一次，因为这是最容易踩的坑：

```bash
# ❌ 在 base 节点上执行 —— 必然卡死 20 秒然后失败
curl -LO https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
# curl: (28) Failed to connect to github.com port 443
```

### 正确做法：外部下载 → scp 过去

**在能上 github.com 的机器上（你的 Windows 工作机）：**

```bash
# 版本号去 https://github.com/actions/runner/releases 看最新的；实测用的是 v2.337.0
curl -LO https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz

# 传过去
scp actions-runner-linux-x64-2.337.0.tar.gz candidate@172.30.30.21:/tmp/
```

**在 base 节点上（172.30.30.21）：**

```bash
cd ~
mkdir -p actions-runner && tar -xzf /tmp/actions-runner-linux-x64-2.337.0.tar.gz -C actions-runner
cd actions-runner

./config.sh \
  --url https://github.com/fds19955/weknora-deploy \
  --token <第一步拿到的 token> \
  --name "$(hostname)-weknora" \
  --labels weknora-local \
  --work _work \
  --unattended \
  --replace
```

逐个参数解释：

| 参数 | 作用 | 为什么这么设 |
|---|---|---|
| `--url` | runner 归属的仓库 | **仓库级** runner（只这个仓库能用）。若用组织级，改成组织 URL |
| `--token` | 注册凭证 | 见第一步 |
| `--name` | runner 显示名 | 带 `$(hostname)` 前缀，将来多节点时一眼看出是谁 |
| `--labels` | **自定义标签** | 关键。workflow 里 `runs-on: [self-hosted, weknora-local]` 靠它匹配。见下方说明 |
| `--work _work` | 工作目录 | 每个 job 在这里拉代码、跑命令 |
| `--unattended` | 全自动不交互 | 脚本化必需，否则会停下来问你一堆问题 |
| `--replace` | 同名顶掉旧的 | **幂等的关键**：重跑脚本时不会因为"runner 已存在"报错 |

### 关于标签（labels）

不写 `--labels` 的话，runner 默认带 `self-hosted` / `Linux` / `X64` 这些自动标签。
但如果你将来在这套集群里挂了多个 runner（比如一个跑部署、一个跑测试），
只靠自动标签就无法区分，workflow 会随机落到任意一台。

所以显式打一个业务标签 `weknora-local`，workflow 用：

```yaml
runs-on: [self-hosted, weknora-local]   # 数组是 AND 关系，三个条件都要满足
```

> ⚠️ 注意 `--labels` 会**替换**默认标签集。如果希望自动标签也保留，
> 写成 `--labels weknora-local,self-hosted,Linux,X64`。

### 网络超时的兜底方案

如果连**外部机器**下 github.com 也不稳（据你之前记录，Windows 侧 github.com 也会间歇抽风），
按顺序试：

1. **加重试参数**（首选，成本最低）
   ```bash
   curl -L --retry 8 --retry-all-errors --retry-delay 5 --connect-timeout 20 -O \
     https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
   ```
   `--retry-all-errors` 是关键 —— curl 默认对连接重置/中途断流这类错误**不重试**。

2. **走 GitHub 镜像加速站**（第三方中转，能用但别传敏感东西）
   ```bash
   curl -L -o actions-runner.tar.gz \
     https://ghproxy.net/https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
   ```
   同类还有 `gh-proxy.com`、`ghfast.top` 等，哪个通用哪个。

3. **从别的已装 runner 的机器上偷包**（最可靠）
   如果任何一台内网机器已经解包过 runner，直接把整个目录打包拷过来：
   ```bash
   # 在源机器
   tar -czf /tmp/runner-bundle.tgz -C ~ actions-runner
   # 拷到目标机器后
   cd ~ && tar -xzf /tmp/runner-bundle.tgz
   ```
   **注意**：拷贝过来的 `.runner` / `.credentials` 文件带着原机器的身份，到新机器上必须删掉这两个
   （或直接用 `--replace` 重新 `config.sh`），否则会出现两台机器抢同一个 runner 身份。

4. **校验完整性**（别跳过）
   GitHub 会公布每个 release 包的 SHA256：
   ```bash
   sha256sum actions-runner-linux-x64-2.337.0.tar.gz
   ```
   对不上就是下载被中间设备篡改了，重下。

---

## 四、第三步：装成 systemd 服务（开机自启）

**为什么必须做这一步**：`./run.sh` 是前台进程，SSH 一断 runner 就掉线，
GitHub 上显示 offline，job 全部卡在 queued 没人接。

```bash
cd ~/actions-runner

# 安装服务，指定以 candidate 用户身份运行
sudo ./svc.sh install candidate

# 启用并立刻启动（enable 保证开机自启，--now 保证现在就跑）
sudo systemctl enable --now actions.runner.fds19955-weknora-deploy.$(hostname)-weknora.service

# 或者更简单，svc.sh 封装好了：
sudo ./svc.sh start
```

### 为什么是 `candidate` 用户而不是 root

两个原因：

1. **kubeconfig 在 `~/.kube/config`**。runner 以 candidate 身份运行，
   `$HOME` 就是 `/home/candidate`，kubectl 能直接读到配置。
   如果跑成 root，`$HOME=/root`，kubectl 会报
   `The connection to the server localhost:8080 was refused` —— 因为找不到配置。
2. **最小权限**。CI 里跑的 job 不应该有 root 权限。helm/kubectl 操作
   `weknora` namespace 用 candidate 的权限就够了（该用户本身已是集群管理员级别）。

### 服务名怎么拼

```
actions.runner.<owner>-<repo>.<runner-name>.service
                └─ fds19955-weknora-deploy
```

`<owner>-<repo>` 里的 `/` 被替换成 `-`。查实际名字：

```bash
systemctl list-units 'actions.runner.*' --all
```

### 确认起来了的三个检查

```bash
# 1. 服务是 active (running)
systemctl status actions.runner.fds19955-weknora-deploy.*.service --no-pager

# 2. 日志里出现 "Listening for Jobs"
sudo journalctl -u 'actions.runner.*' -n 30 --no-pager

# 3. GitHub 网页上 runner 变绿
#    Settings → Actions → Runners，状态应为 Idle（空闲）
```

看到 `Listening for Jobs` 就说明它已经注册成功、开始长轮询拉活了。

---

## 五、第四步：Workflow YAML

文件在 `.github/workflows/deploy.yml`。下面只讲设计决策，完整内容看文件。

### 5.1 触发条件

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'deploy/**'
      - 'chart/**'
      - '.github/workflows/deploy.yml'
  workflow_dispatch:
    inputs:
      dry_run:
        type: boolean
```

- `paths` 过滤：**改 README 不该触发一次 helm upgrade**。只有真正影响部署的文件
  （values、chart、workflow 自己）变动才部署。
- `workflow_dispatch` + `dry_run` 布尔入参：让你能在网页点一下、只渲染不部署，
  验证模板改动是否合法。这比"直接部署然后看崩没崩"安全得多。

### 5.2 并发控制

```yaml
concurrency:
  group: weknora-cd
  cancel-in-progress: false
```

**这个不能省。** 连续 push 两次会触发两个 job，两个 `helm upgrade` 同时改同一个
release 会互相踩，helm 那边会报 `another operation (install/upgrade/rollback) is in progress`。
`group` 把同一个 release 的部署串成队列；`cancel-in-progress: false` 表示
**排队而不是取消** —— 部署跑到一半被取消比等待更危险。

### 5.3 绕开 actions/checkout

```yaml
- name: 拉取源码（走 codeload，绕开被墙的 github.com）
  run: |
    URL="https://codeload.github.com/${GITHUB_REPOSITORY}/tar.gz/${GITHUB_SHA}"
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$RUNNER_TEMP/src.tgz" "$URL"
    mkdir -p "$GITHUB_WORKSPACE/src"
    tar -xzf "$RUNNER_TEMP/src.tgz" --strip-components=1 -C "$GITHUB_WORKSPACE/src"
```

要点：

- `codeload.github.com/{owner}/{repo}/tar.gz/{sha}` 直接返回该 commit 的快照 tarball，
  **本集群实测可达**。
- **锁 `${GITHUB_SHA}` 而不是 `main`**：workflow 跑的是"这一次 push 的代码"，
  不能用分支名（分支可能在 curl 期间又被 push 了）。
- `--strip-components=1` 去掉 tarball 里自动多出来的 `repo-sha/` 顶层目录。
- 公有仓库不需要认证。**若改成私有仓库**，要加 token 头：
  ```bash
  -H "Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}"
  ```

### 5.4 密钥注入：为什么不用 `--set`

```yaml
- name: 写密钥 values（落到 runner 临时目录，job 结束自动清理）
  env:
    IN_DB_PASSWORD: ${{ secrets.WEKNORA_DB_PASSWORD }}
    ...
  run: |
    umask 077
    cat > "$RUNNER_TEMP/secrets.yaml" <<EOF
    secrets:
      dbPassword: "${IN_DB_PASSWORD}"
    ...
```

两种做法对比：

| 做法 | 问题 |
|---|---|
| `helm --set secrets.dbPassword=xxx` | 值**短暂出现在进程列表**（`ps aux` 能看到），且 helm 原样记进 release 历史（`helm get values` 能回显） |
| **写临时 values 文件**（采用） | 文件权限 0600，只有 runner 自己可读；不进程泄漏 |

`$RUNNER_TEMP` 是 runner 为每个 job 分配的临时目录，**job 结束自动清空**。
所以这里刻意**不写 `rm` 清理** —— 少一条删除命令，就少一份误删风险（也是你的红线要求）。

### 5.5 密钥防呆校验

脚本里有一段检查：

```bash
for v in IN_DB_PASSWORD IN_REDIS_PASSWORD IN_JWT_SECRET IN_SYSTEM_AES_KEY; do
  if [ -z "${!v}" ]; then
    echo "::error::GitHub Secrets 里缺少 $v"; exit 1
  fi
done
```

**为什么这个必须加**：如果 Secret 没配，helm 会收到空密码并把 k8s Secret 改成空的，
postgres 随即因为"数据卷里是旧密码"而认证失败 → CrashLoopBackOff。
这是**不可逆的**（要清 PVC 和 NFS 目录才能恢复，会丢全部数据）。
在 CI 里花 3 行成本拦下来，比事后救火便宜太多。

### 5.6 存储资源：只 apply，绝不 delete

```yaml
- name: 幂等应用存储（PV/PVC）
  run: |
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$GITHUB_WORKSPACE/src/deploy/storage.yaml"
```

`--dry-run=client -o yaml | kubectl apply -f -` 是"不存在则创建、存在则不动"的标准写法，
比 `kubectl create` 幂等（后者第二次会报 AlreadyExists 而失败）。

**红线遵守**：全流程没有 `kubectl delete`。PVC 删掉 = NFS 上数据没了，
所以存储资源只允许 apply。

### 5.7 关于 `--atomic`：故意不用

```yaml
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" -f ... -f ... \
  --wait --timeout 10m $DRY
```

`--atomic` 会在失败时自动 `helm rollback`。看起来更"安全"，实际上有两个问题：

1. **首次 install 的 rollback 等价于 uninstall** —— 会把刚起来的 Deployment/Service 全拆掉，
   出问题时你连现场都没得看。
2. 对练习/自建集群，**保留失败现场**（自己能 `kubectl logs` / `describe`）比自动回滚更有价值。

所以用 `--wait --timeout 10m`：等所有 Pod 就绪，超时则 job 失败但**环境保持原样**。

> 如果是生产环境，结论会反过来 —— 那时 `--atomic` 值得用，因为"服务可用性"优先于"排查便利"。

---

## 六、第五步：安全的测试方法

### 6.1 推荐路径：先 dry-run，再真部署

**测试 A —— 只渲染不下发（零风险）**

GitHub 仓库页 → Actions → 左侧选 `Deploy WeKnora` → 右上 `Run workflow`
→ 勾上 `dry_run` → Run。

这会在集群上跑 `helm --dry-run`，验证模板语法和 values 合并是否正确，
**不碰任何运行中的资源**。渲染结果在 job 日志里。

**测试 B —— 改一个不痛不痒的值，看真实生效**

最安全的验证目标是 **副本数** 或 **资源 limits**，改坏了也不影响功能：

```bash
# 在本地仓库里
vim deploy/values.yaml
# 把 app.resources.limits.memory 从 1Gi 改成 1Gi（先别改，或者改注释）
```

其实更好的做法是改 **frontend 的副本数**（但 chart 里可能写死了）。
最稳的做法：改 `global.maxFileSizeMB`，从 50 改成 60 —— 这是个纯配置项，
改了会触发 `helm upgrade`，Pod 会滚动重启，但没有功能风险。

```bash
git add deploy/values.yaml
git commit -m "chore: 触发一次部署验证 maxFileSizeMB=60"
git push origin main
```

### 6.2 观察触发的三个位置

**① GitHub 网页**

`Actions` 标签页 → 会出现一条新的 workflow run，点进去看实时日志。
每一步展开都能看到。runner 名称会显示成 `base-weknora`（我们起的名字），
证明是自建 runner 接的活而非 GitHub 托管 runner。

**② 节点上看 runner 实时日志**

```bash
ssh candidate@172.30.30.21
sudo journalctl -u 'actions.runner.*' -f
```
会看到 `Running job: ...` / 每个 step 的输出 / `Job ... completed with result: Succeeded`。

**③ 集群里看真实变化**

```bash
# helm revision 应该 +1
helm history weknora -n weknora

# Pod 应该是新 AGE（滚动重启过）
kubectl get pods -n weknora -o wide

# 确认配置真的变了
helm get values weknora -n weknora
```

**revision 从 1 变 2，是"CI 真的把变更打到集群上了"的最硬证据。**

### 6.3 验证端到端功能没坏

部署完别忘了确认应用还能用（CI 绿了不代表业务没坏）：

```bash
# port-forward 顶着（本集群 ingress-nginx 是 ClusterIP，没 NodePort）
kubectl port-forward --address 0.0.0.0 -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

然后浏览器 `http://weknora.local:8080` 登录，**问一次知识库问题**，
确认 RAG 链路仍然通（模型配置在数据库里，重启 Pod 不该丢）。

---

## 七、风险与注意事项

### 7.1 Public 仓库的固有风险（必须知道）

仓库是 public 的，意味着：

- **任何人都能 fork 并发起 PR**。PR 里的 workflow 文件改动**在 fork 场景下不会**自动拿到
  Secrets（GitHub 默认对来自 fork 的 PR 不注入 secrets），所以拿不到密钥。这是 GitHub 的默认保护。
- **但 `push` 触发用的是你自己的 commit**。只要你不把别人的代码 merge 进 main，就是安全的。
- **建议**：Settings → Actions → General → 勾选
  `Require approval for all outside collaborators`，把外部贡献者的 workflow 卡在人工审批。

### 7.2 Secrets 里存的是"当前集群正在用的真实密钥"

这一点很反直觉但很重要：**CI 用的密钥必须和集群里 postgres 数据卷的初始化密码完全一致。**

因为 postgres 只在**数据卷为空**时用 `POSTGRES_PASSWORD` 初始化一次；
之后 helm upgrade 改密码**不会**改数据库里的实际密码，只会让应用连不上 →
`password authentication failed` → CrashLoopBackOff。

所以不能"顺手换成新密钥"，必须用当前真实值：

```bash
# 从集群读出权威值
kubectl get secret -n weknora weknora-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
```

同理 `systemAesKey` 更严格 —— 它加密了数据库里存的模型 api_key，
换了之后**历史密文永久解不开**（模型要重新配）。

### 7.3 Runner 的维护

```bash
# 升级 runner（版本太旧 GitHub 会拒绝接活）
# 到 release 页面看最新版，重复第三节的下载+scp+config 流程，
# --replace 会让新版本顶掉旧的

# 临时停/起
sudo ./svc.sh stop
sudo ./svc.sh start

# 彻底移除（从 GitHub 注销）
./config.sh remove --token <新的 registration token>
sudo ./svc.sh uninstall
```

### 7.4 磁盘

runner 的 `_work` 目录会累积每次 job 的检出内容。
本集群根分区 48G、已用 24G（53%）。当前 job 只拉一个几十 KB 的 tarball，
**短期不用担心**；但如果将来 job 变大，记得 `du -sh ~/actions-runner/_work` 看一眼。

---

## 八、排障速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `Failed to connect to github.com port 443` | **本次已确认的域名级阻断** | 别改 hosts、别换 IP。走 codeload（拉代码）/ scp（拉 runner 包） |
| Job 一直 `queued`，不动 | 没有匹配 label 的 runner 在线 | 查 `runs-on` 的 label 和 `config.sh --labels` 是否一致；`systemctl status 'actions.runner.*'` |
| 网页上 runner 是 offline | 服务没起 / 掉了 | `sudo ./svc.sh start`；看 `journalctl -u 'actions.runner.*' -n 100` |
| `Token expired` | 注册 token 超过 1 小时 | 重新生成 registration token |
| `A runner with the name ... already exists` | 同名没注销就重装 | 加 `--replace`（脚本里已有） |
| `The connection to the server localhost:8080 was refused` | runner 以 root 跑，读不到 `~/.kube/config` | 确认服务 `User=candidate`；或在 workflow 里显式设 `KUBECONFIG` |
| `another operation is in progress` | 两个 helm upgrade 并发 | 确认 `concurrency` 段存在 |
| `password authentication failed` | CI 的 dbPassword 与数据卷里的不一致 | 把 Secret 改回**当前集群真实值**（不要重装） |
| `SYSTEM_AES_KEY must be 32 bytes` | systemAesKey 长度不对 | `openssl rand -hex 16` 重新生成（注意会作废历史密文） |
| `helm: command not found` | 服务 PATH 里没有 | 本集群 helm 在 `/usr/local/bin`，属于 systemd 默认 PATH，正常不会出现；若出现则在 workflow 里显式设 PATH |

### runner 自己的诊断日志（排查首选）

```bash
ls -t ~/actions-runner/_diag/*.log | head -1 | xargs tail -50
```

里面有完整的注册流程、网络请求、job 分配过程，比 systemd 日志更详细。

---

## 附：本方案与本集群的对应关系

| 项 | 值 |
|---|---|
| Runner 节点 | base（172.30.30.21） |
| Runner 标签 | `weknora-local` |
| Runner 目录 | `~/actions-runner`（/home/candidate/actions-runner） |
| 服务名 | `actions.runner.fds19955-weknora-deploy.<hostname>-weknora.service` |
| Helm release / namespace | `weknora` / `weknora` |
| Chart | `chart/weknora-0.1.0.tgz`（v0.8.0） |
| 部署方式 | `helm upgrade --install`（幂等，重复跑不会重建） |
