#!/bin/bash
# P2P/NCCL 套件运行器 v1 —— 把 g292z20-nccl-tests 七件套以**非交互**方式跑起来并给出机器可读判读。
# 相对原 run_all.sh 的修改（为进包/进自动化）：
#   1) 去掉 -t（自动化无 tty）；2) NCCL_DEBUG 默认 WARN（原 INFO 太吵，仍可 env 覆盖）；
#   3) 全程 tee 到日志文件；4) 跑完从日志里抽判读行，打印 P2P_VERDICT/P2P_LINKS/P2P_MIN_BW/NCCL_BUSBW；
#   5) 退出码：0=全连通 6=部分连通(警告) 7=全不可达(硬失败，BIOS ACS/IOMMU) 其它=运行出错。
# 阈值不内置机型经验值（不凭记忆造数）：要卡下限用 env P2P_FLOOR_GBPS / NCCL_FLOOR_GBPS，默认 0=只报不卡。
set -u
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
OUT="${OUT:-$SRC/p2p-suite-$(date +%Y%m%d-%H%M%S).log}"
P2P_FLOOR_GBPS="${P2P_FLOOR_GBPS:-0}"
NCCL_FLOOR_GBPS="${NCCL_FLOOR_GBPS:-0}"

[ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | head -1)" ] && {
  echo "P2P_SKIP GPU 上有其它进程在跑（不抢卡）"; exit 0; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "P2P_SKIP torch 镜像不在: $IMAGE"; exit 0; }

echo "P2P_LOG=$OUT"
docker run --rm --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -e NCCL_DEBUG="$NCCL_DEBUG" \
  -v "$SRC:/tests" -w /tests \
  "$IMAGE" bash -c '
    set -e
    echo "===== TORCH / GPU SANITY ====="
    python - <<PY
import torch
print("torch        ", torch.__version__)
print("cuda available", torch.cuda.is_available())
print("device count  ", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    print(f"  GPU{i}: {p.name}  {p.total_memory/2**30:.1f} GiB")
PY
    echo; echo "===== GPU TOPOLOGY (nvidia-smi topo -m) ====="; nvidia-smi topo -m
    echo; echo "===== P2P ACCESS MATRIX ====="; python p2p_check.py
    echo; echo "===== NCCL BANDWIDTH (all_reduce, all GPUs) ====="
    torchrun --nproc_per_node=$(nvidia-smi -L | wc -l) nccl_bandwidth.py
    echo; echo "===== P2P BANDWIDTH (1 GiB, both directions + bidirectional) ====="; python p2p_bandwidth.py
    echo; echo "===== MULTI-STREAM CONCURRENT P2P ====="; python multistream_p2p.py
    echo; echo "===== P2P DIAGNOSTICS ====="; python diag_p2p.py
  ' 2>&1 | tee "$OUT"
RC=${PIPESTATUS[0]}
[ "$RC" = "0" ] || { echo "P2P_RUN_FAILED rc=$RC（看 $OUT 尾部）"; exit "$RC"; }

LINKS=$(grep -a '摘要:' "$OUT" | tail -1)
VERDICT=$(grep -a '判读:' "$OUT" | tail -1)
MINBW=$(grep -aE '^[0-9]+->[0-9]+ *\|' "$OUT" | awk -F'|' '{a=$2+0;b=$3+0;m=(a<b?a:b); if(NR==1||m<min)min=m} END{printf "%.2f", min}')
BIDIR=$(grep -aE '^[0-9]+->[0-9]+ *\|' "$OUT" | awk -F'|' '{if(NR==1||$4+0<min)min=$4+0} END{printf "%.2f", min}')
BUS=$(grep -aE 'MiB *\|' "$OUT" | tail -1 | awk -F'|' '{print $4+0}')
echo "P2P_LINKS=$LINKS"
echo "P2P_VERDICT=$VERDICT"
echo "P2P_MIN_SINGLE_DIR_GBPS=$MINBW  P2P_MIN_BIDIR_GBPS=$BIDIR  NCCL_MAX_BUSBW_GBPS=$BUS"
FAIL=0
awk -v v="$MINBW" -v f="$P2P_FLOOR_GBPS" 'BEGIN{exit !(v<f)}' && { echo "P2P_FLOOR_FAIL min=$MINBW < floor=$P2P_FLOOR_GBPS"; FAIL=1; }
awk -v v="$BUS" -v f="$NCCL_FLOOR_GBPS" 'BEGIN{exit !(v<f)}' && { echo "NCCL_FLOOR_FAIL busbw=$BUS < floor=$NCCL_FLOOR_GBPS"; FAIL=1; }
[ "$FAIL" = "1" ] && exit 8
case "$VERDICT" in
  *全连通*) echo "P2P_RESULT=PASS"; exit 0 ;;
  *部分连通*) echo "P2P_RESULT=WARN_PARTIAL（不可达对会回退 CPU 中转，BIOS 关 ACS 后重测）"; exit 6 ;;
  *全不可达*) echo "P2P_RESULT=FAIL_NOP2P（必须 BIOS 关 ACS/IOMMU）"; exit 7 ;;
  *) echo "P2P_RESULT=UNKNOWN（日志里没有判读行）"; exit 9 ;;
esac
