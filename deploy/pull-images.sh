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
