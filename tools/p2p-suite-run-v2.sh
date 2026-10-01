#!/bin/bash
# P2P/NCCL 套件运行器 v2（2026-10-01 二轮 review 修订，v1 留档同目录）
# v1 的三个实证 bug（见 内部/审查记录-自包含部署包-v1.md §v3.2 G1-G3）：
#   G1 SRC 指向 tools/ 而不是 tools/g292z20-nccl-tests/，容器里找不到 p2p_check.py，套件必失败；
#   G2 带宽行是右对齐带前导空格（p2p_bandwidth.py 的 :>7），正则 ^[0-9]+-> 永不命中 → MIN/BIDIR 恒 0.00，
#      一旦设了 P2P_FLOOR_GBPS 就恒报 8（假失败）；
#   G3 busbw 用 grep 'MiB *|' tail -1，抓到的是 p2p 尺寸扫描行（两列）而不是 NCCL 四列行 → NCCL 值恒 0.00。
# v2 改法：SRC 进套件子目录；按段落标记（===== XXX =====）切段后用 awk 按列数/首列形态解析；
#   容器内各阶段单独容错（某阶段崩不再吞掉后面的判读行）；跳过（GPU 被占/镜像不在）用退出码 3，与"通过"0 严格区分。
# 退出码：0=全连通 3=跳过未跑 6=部分连通 7=全不可达 8=低于你设的下限 9=无判读行 其它=运行出错。
# 阈值不内置机型经验值（不凭记忆造数）：要卡下限用 env P2P_FLOOR_GBPS / NCCL_FLOOR_GBPS，默认 0=只报不卡。
set -u
SUITE="${SUITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/g292z20-nccl-tests" && pwd)}"
IMAGE="${IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
OUT="${OUT:-$(dirname "$SUITE")/p2p-suite-$(date +%Y%m%d-%H%M%S).log}"
P2P_FLOOR_GBPS="${P2P_FLOOR_GBPS:-0}"
NCCL_FLOOR_GBPS="${NCCL_FLOOR_GBPS:-0}"
[ -f "$SUITE/p2p_check.py" ] || { echo "P2P_SKIP 套件目录缺 p2p_check.py: $SUITE"; exit 3; }

# PARSE_ONLY=1 OUT=<日志> 时只跑解析段（离线单测用，不碰 GPU/docker）
if [ "${PARSE_ONLY:-0}" != "1" ]; then
[ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | head -1)" ] && {
  echo "P2P_SKIP GPU 上有其它进程在跑（不抢卡）"; exit 3; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "P2P_SKIP torch 镜像不在: $IMAGE"; exit 3; }

echo "P2P_LOG=$OUT"
echo "P2P_SUITE_DIR=$SUITE"
docker run --rm --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -e NCCL_DEBUG="$NCCL_DEBUG" \
  -v "$SUITE:/tests" -w /tests \
  "$IMAGE" bash -c '
    echo "===== TORCH / GPU SANITY ====="
    python - <<PY || echo "STAGE_FAIL sanity"
import torch
print("torch        ", torch.__version__)
print("cuda available", torch.cuda.is_available())
print("device count  ", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"  GPU{i}: {p.name}  {p.total_memory/2**30:.1f} GiB")
PY
    echo; echo "===== GPU TOPOLOGY (nvidia-smi topo -m) ====="; nvidia-smi topo -m || echo "STAGE_FAIL topo"
    echo; echo "===== P2P ACCESS MATRIX ====="; python p2p_check.py || echo "STAGE_FAIL p2p_check"
    echo; echo "===== NCCL BANDWIDTH (all_reduce, all GPUs) ====="
    torchrun --nproc_per_node=$(nvidia-smi -L | wc -l) nccl_bandwidth.py || echo "STAGE_FAIL nccl"
    echo; echo "===== P2P BANDWIDTH (1 GiB, both directions + bidirectional) ====="
    python p2p_bandwidth.py || echo "STAGE_FAIL p2p_bw"
    echo; echo "===== MULTI-STREAM CONCURRENT P2P ====="
    python multistream_p2p.py || echo "STAGE_FAIL multistream"
    echo; echo "===== P2P DIAGNOSTICS ====="
    python diag_p2p.py || echo "STAGE_FAIL diag"
  ' 2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
fi # PARSE_ONLY
RC=${RC:-0}
STAGEFAILS=$(grep -ac '^STAGE_FAIL' "$OUT" 2>/dev/null)
STAGEFAILS=${STAGEFAILS:-0}
echo "P2P_STAGE_FAILS=$STAGEFAILS"
[ "$RC" = "0" ] || echo "P2P_RUN_FAILED rc=$RC（看 $OUT 尾部；判读行若已产出仍会照常解析）"

LINKS=$(grep -a '摘要:' "$OUT" | tail -1)
VERDICT=$(grep -a '判读:' "$OUT" | head -1)
# G2/G3：按段解析，-F'|' 切列（行里的竖线是独立字段，默认分词会得到 NF=7）。
# pair 行＝P2P BANDWIDTH 段内、首列形如 0->1 的四列行；busbw＝NCCL 段内首列为尺寸标签的四列行取最大。
MINBW=$(awk -F'|' '/^===== NCCL BANDWIDTH/{s="nccl"} /^===== P2P BANDWIDTH/{s="p2p"} /^===== MULTI-STREAM/{s="ms"}
  s=="p2p" && NF==4 && $1 ~ /^[ \t]*[0-9]+->[0-9]+[ \t]*$/ {a=$2+0;b=$3+0;m=(a<b?a:b); if(min==""||m<min)min=m}
  END{printf "%s", (min==""?"":sprintf("%.2f",min))}' "$OUT")
BIDIR=$(awk -F'|' '/^===== P2P BANDWIDTH/{s="p2p"} /^===== MULTI-STREAM/{s="ms"}
  s=="p2p" && NF==4 && $1 ~ /^[ \t]*[0-9]+->[0-9]+[ \t]*$/ {if(min==""||$4+0<min)min=$4+0}
  END{printf "%s", (min==""?"":sprintf("%.2f",min))}' "$OUT")
BUS=$(awk -F'|' '/^===== NCCL BANDWIDTH/{s="nccl"} /^===== P2P BANDWIDTH/{s="p2p"}
  s=="nccl" && NF==4 && $1 ~ /^[ \t]*[0-9.]+(KiB|MiB|GiB)[ \t]*$/ {if($4+0>m)m=$4+0}
  END{printf "%s", (m==""?"":sprintf("%.2f",m))}' "$OUT")
echo "P2P_LINKS=${LINKS:-<无>}"
echo "P2P_VERDICT=${VERDICT:-<无判读行>}"
echo "P2P_MIN_SINGLE_DIR_GBPS=${MINBW:-NA}  P2P_MIN_BIDIR_GBPS=${BIDIR:-NA}  NCCL_MAX_BUSBW_GBPS=${BUS:-NA}"
FAIL=0
if [ -n "$MINBW" ]; then
  awk -v v="$MINBW" -v f="$P2P_FLOOR_GBPS" 'BEGIN{exit !(v<f)}' && { echo "P2P_FLOOR_FAIL min=$MINBW < floor=$P2P_FLOOR_GBPS"; FAIL=1; }
fi
if [ -n "$BUS" ]; then
  awk -v v="$BUS" -v f="$NCCL_FLOOR_GBPS" 'BEGIN{exit !(v<f)}' && { echo "NCCL_FLOOR_FAIL busbw=$BUS < floor=$NCCL_FLOOR_GBPS"; FAIL=1; }
fi
[ "$FAIL" = "1" ] && exit 8
case "$VERDICT" in
  *全连通*) echo "P2P_RESULT=PASS"; exit 0 ;;
  *部分连通*) echo "P2P_RESULT=WARN_PARTIAL（不可达对会回退 CPU 中转，BIOS 关 ACS 后重测）"; exit 6 ;;
  *全不可达*) echo "P2P_RESULT=FAIL_NOP2P（必须 BIOS 关 ACS/IOMMU）"; exit 7 ;;
  *) echo "P2P_RESULT=UNKNOWN（日志里没有判读行）"; exit 9 ;;
esac
