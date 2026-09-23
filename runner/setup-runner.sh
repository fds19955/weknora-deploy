#!/usr/bin/env bash
# =============================================================================
# 把本机装成 GitHub Actions Self-hosted Runner（供 weknora 部署流水线使用）
# =============================================================================
#
# 设计要点
#   · 幂等：每一步先检查再执行，重复运行只会补做缺失部分，不删任何已有文件
#   · 无破坏性命令：全程没有 rm / kubectl delete / 覆盖式写入
#   · 出站only：runner 主动向 GitHub 拉活，不在本机开任何监听端口
#
# 为什么不能在本机直接下载 runner 包？
#   本集群对 github.com:443 不可达（实测 5/5 超时），而 runner 包的下载地址
#   https://github.com/actions/runner/releases/download/... 正是 github.com。
#   所以包必须从外部（能上 github.com 的机器）下好，scp 过来，用 --tarball 指定。
#
# 用法
#   1) 外部机器下载好包并传过来：
#        scp actions-runner-linux-x64-2.337.0.tar.gz candidate@<node>:/tmp/
#   2) 在节点上带 token 运行本脚本：
#        export RUNNER_TOKEN=<从 GitHub 拿到的 registration token>
#        bash runner/setup-runner.sh --tarball /tmp/actions-runner-linux-x64-2.337.0.tar.gz
#
# =============================================================================

set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.337.0}"
RUNNER_HOME="${RUNNER_HOME:-$HOME/actions-runner}"
RUNNER_TAG="${RUNNER_TAG:-weknora-local}"
REPO_URL="${REPO_URL:-https://github.com/fds19955/weknora-deploy}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-weknora}"

TARBALL=""
# ---- 解析参数 ----
while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) TARBALL="$2"; shift 2 ;;
    --home)    RUNNER_HOME="$2"; shift 2 ;;
    --tag)     RUNNER_TAG="$2"; shift 2 ;;
    --repo)    REPO_URL="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
skip(){ printf '    \033[1;33m–\033[0m %s（已存在，跳过）\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# =============================================================================
log "第 0 步：前置检查"
# =============================================================================
for bin in git curl tar; do
  command -v "$bin" >/dev/null 2>&1 || die "缺少 $bin，请先安装"
  ok "$bin -> $(command -v "$bin")"
done
# runner 只是把命令转发给 helm/kubectl，这两个必须在 PATH 里
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "缺少 $bin —— 部署流水线无法工作"
  ok "$bin -> $(command -v "$bin")"
done
command -v systemctl >/dev/null 2>&1 || die "没有 systemd，无法做开机自启"
ok "systemd 可用"

# =============================================================================
log "第 1 步：准备 runner 目录与程序包"
# =============================================================================
if [ -x "$RUNNER_HOME/config.sh" ]; then
  skip "runner 程序已解包到 $RUNNER_HOME"
else
  [ -n "$TARBALL" ] || die "runner 未安装且未指定 --tarball。
     本机连不上 github.com，无法自动下载。
     请在能上网的机器上执行：
       curl -LO https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
     再 scp 到本机，然后加 --tarball <路径> 重跑本脚本。"
  [ -f "$TARBALL" ] || die "找不到 tar 包：$TARBALL"

  mkdir -p "$RUNNER_HOME"
  # 只解包，不清理目录里已有内容（幂等的代价是可能残留旧文件，可接受）
  tar -xzf "$TARBALL" -C "$RUNNER_HOME"
  ok "已解包 $TARBALL -> $RUNNER_HOME"
fi

# =============================================================================
log "第 2 步：安装运行依赖（.NET 运行时自带在包里，这里只补系统库）"
# =============================================================================
# --no-install-recommends 少装无关包；-y 免交互；apt 本身幂等
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends libicu-dev >/dev/null
ok "libicu-dev 就绪（runner 依赖 libicu）"

# =============================================================================
log "第 3 步：向 GitHub 注册 runner"
# =============================================================================
# 判断依据：注册成功后会在 RUNNER_HOME 下生成 .runner 文件
if [ -f "$RUNNER_HOME/.runner" ]; then
  skip "runner 已注册（$RUNNER_HOME/.runner 存在）"
  ok "当前标签：$(grep -o '"labels":[^]]*]' "$RUNNER_HOME/.runner" 2>/dev/null || echo '（读不到，可 cat .runner 查看）')"
else
  [ -n "${RUNNER_TOKEN:-}" ] || die "缺少环境变量 RUNNER_TOKEN。
    获取方式：GitHub 仓库页 → Settings → Actions → Runners → New self-hosted runner，
    页面上的 --token 后面那串就是。注意 token 1 小时后就失效，拿到要尽快用。
    （也可以用 PAT 调 API 生成：
      curl -X POST -H \"Authorization: token <PAT>\" \\
        https://api.github.com/repos/fds19955/weknora-deploy/actions/runners/registration-token ）"

  cd "$RUNNER_HOME"
  # --replace：同名 runner 已在线时顶掉旧的，避免 "already exists" 报错（幂等关键）
  # --unattended：全程不交互，适合脚本
  # --no-default-labels：不要默认那堆 label，只用我们自己的，标签语义更干净
  ./config.sh \
    --url "$REPO_URL" \
    --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_TAG" \
    --work "_work" \
    --unattended \
    --replace
  ok "已注册为 runner「$RUNNER_NAME」，标签 [$RUNNER_TAG]"
fi

# =============================================================================
log "第 4 步：装成 systemd 服务（开机自启 + SSH 断开不掉线）"
# =============================================================================
# 服务名固定为 actions.runner.<owner-repo>.<runner-name>.service
SVC_UNIT="actions.runner.fds19955-weknora-deploy.${RUNNER_NAME}.service"

if systemctl is-enabled "$SVC_UNIT" >/dev/null 2>&1; then
  skip "systemd 服务已安装"
else
  cd "$RUNNER_HOME"
  # svc.sh install <user> 把服务配成以该用户身份运行，
  # 这样 HOME=/home/candidate，runner 才读得到 ~/.kube/config
  sudo ./svc.sh install "$(id -un)"
  ok "systemd 服务已安装：$SVC_UNIT"
fi

log "第 5 步：启动服务并设为开机自启"
sudo systemctl enable --now "$SVC_UNIT" >/dev/null 2>&1 || sudo ./svc.sh start
sudo ./svc.sh status 2>&1 | head -20 || true

# =============================================================================
log "第 6 步：自检"
# =============================================================================
if systemctl is-active --quiet "$SVC_UNIT"; then
  ok "服务运行中：$(systemctl is-active "$SVC_UNIT")"
else
  die "服务未运行，看日志：journalctl -u $SVC_UNIT -n 100 --no-pager"
fi

printf '\n'
ok "runner 目录   : $RUNNER_HOME"
ok "标签          : $RUNNER_TAG"
ok "去 GitHub 看  : ${REPO_URL}/settings/actions/runners"
printf '\n提示：查看运行日志\n  sudo journalctl -u %s -f\n' "$SVC_UNIT"
printf '提示：诊断日志（排查网络/注册问题首选）\n  ls -t %s/_diag/*.log | head -1 | xargs tail -50\n\n' "$RUNNER_HOME"
