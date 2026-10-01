#!/bin/bash
# P2P/NCCL 套件运行器 v3（2026-10-01 三轮隔离审查 H1-H3 ＋第二轮 H4，清单见 CHANGELOG.md）
#   H4 套件目录改只读挂载（脚本内无任何写文件操作，grep 证实）：容器以 root 跑，
#      可写挂载等于让一次体检有能力改宿主脚本。
#   H1 镜像变量名与调用方冲突：v2 用 IMAGE，而 start-here 的 IMAGE= 是"控制台镜像覆盖"的公开口子，
#      使用者一设 IMAGE=…incple 就把 torch 镜像换掉 → 套件"镜像不在"跳过（跳过≠通过，容易被误读成已过）；
#      v3 主读 TORCH_IMG（与 env-check、start-here 同名），IMAGE 仅作兼容别名；
#   H2 判读行没落进日志：调用方 grep '^P2P_' 的是 $OUT，而 MIN/BIDIR/busbw 只 echo 到 stdout，
#      日志里没有 → 留档/复核看不到结论，rc=9（无判读行）也可能被误判；v3 全部同时写 $OUT；
#   H3 tee 之前的 P2P_SKIP 早退行没进日志（跳过证据丢失）；v3 早退也落盘。
# v2（2026-10-01 二轮 review）：G1 SRC 指错目录；G2 带宽行右对齐使正则永不命中（MIN/BIDIR 恒 0.00）；
#   G3 busbw 抓到 p2p 扫描行而非 NCCL 四列行；改法＝进子目录＋按段落标记切段＋awk 按列数与首列形态解析。
# 退出码：0=全连通 3=跳过未跑 6=部分连通 7=全不可达 8=低于你设的下限 9=无判读行 其它=运行出错。
# 阈值不内置机型经验值（不凭记忆造数）：要卡下限用 env P2P_FLOOR_GBPS / NCCL_FLOOR_GBPS，默认 0=只报不卡。
set -u
SUITE="${SUITE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/g292z20-nccl-tests" && pwd)}"
TORCH_IMG="${TORCH_IMG:-}"
[ -n "$TORCH_IMG" ] || TORCH_IMG="${IMAGE:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
IMAGE="$TORCH_IMG"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
OUT="${OUT:-$(dirname "$SUITE")/p2p-suite-$(date +%Y%m%d-%H%M%S).log}"
P2P_FLOOR_GBPS="${P2P_FLOOR_GBPS:-0}"
NCCL_FLOOR_GBPS="${NCCL_FLOOR_GBPS:-0}"
# H2/H3：判读与早退"屏上＋日志"各一份；V41：PARSE_ONLY 只读不写，
#      离线单测不再把上一轮结论回灌进被测日志
emit(){
  printf '%s\n' "$*"
  [ "${PARSE_ONLY:-0}" = "1" ] || printf '%s\n' "$*" >> "$OUT"
}
if [ "${PARSE_ONLY:-0}" = "1" ]; then
  # 离线单测路径：只读已有日志做解析，绝不截断它
  [ -f "$OUT" ] || { echo "PARSE_ONLY 需要已存在的日志文件: $OUT"; exit 2; }
else
  mkdir -p "$(dirname "$OUT")" 2>/dev/null || { echo "!! 建不了日志目录 $(dirname "$OUT")"; exit 2; }
  : > "$OUT" || { echo "!! 写不了日志 $OUT"; exit 2; }
  if [ ! -f "$SUITE/p2p_check.py" ]; then
    emit "P2P_SKIP 套件目录缺 p2p_check.py: $SUITE"; exit 3
  fi
fi

# PARSE_ONLY=1 OUT=<日志> 时只跑解析段（离线单测用，不碰 GPU/docker）
if [ "${PARSE_ONLY:-0}" != "1" ]; then
  if [ -n "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | head -1)" ]; then
    emit "P2P_SKIP GPU 上有其它进程在跑（不抢卡）"; exit 3
  fi
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    emit "P2P_SKIP torch 镜像不在: $IMAGE（可 TORCH_IMG= 指定已在本机的 torch，或先 docker pull）"; exit 3; }

  emit "P2P_LOG=$OUT"
  emit "P2P_SUITE_DIR=$SUITE"
  emit "P2P_TORCH_IMG=$IMAGE"
  docker run --rm --gpus all --ipc=host \
    --ulimit memlock=-1 --ulimit stack=67108864 \
    -e NCCL_DEBUG="$NCCL_DEBUG" \
    -v "$SUITE:/tests:ro" -w /tests \
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
    ' 2>&1 | tee -a "$OUT"
  RC=${PIPESTATUS[0]}
fi # PARSE_ONLY
RC=${RC:-0}
STAGEFAILS=$(grep -ac '^STAGE_FAIL' "$OUT" 2>/dev/null)
STAGEFAILS=${STAGEFAILS:-0}
emit "P2P_STAGE_FAILS=$STAGEFAILS"
[ "$RC" = "0" ] || emit "P2P_RUN_FAILED rc=$RC（看 $OUT 尾部；判读行若已产出仍会照常解析）"

LINKS=$(grep -a '摘要:' "$OUT" | grep -av '^P2P_' | tail -1)
VERDICT=$(grep -a '判读:' "$OUT" | grep -av '^P2P_' | head -1)
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
emit "P2P_LINKS=${LINKS:-<无>}"
emit "P2P_VERDICT=${VERDICT:-<无判读行>}"
emit "P2P_MIN_SINGLE_DIR_GBPS=${MINBW:-NA}  P2P_MIN_BIDIR_GBPS=${BIDIR:-NA}  NCCL_MAX_BUSBW_GBPS=${BUS:-NA}"
FAIL=0
if [ -n "$MINBW" ]; then
  awk -v v="$MINBW" -v f="$P2P_FLOOR_GBPS" 'BEGIN{exit !(v+0<f+0)}' && { emit "P2P_FLOOR_FAIL min=$MINBW < floor=$P2P_FLOOR_GBPS"; FAIL=1; }
fi
if [ -n "$BUS" ]; then
  awk -v v="$BUS" -v f="$NCCL_FLOOR_GBPS" 'BEGIN{exit !(v+0<f+0)}' && { emit "NCCL_FLOOR_FAIL busbw=$BUS < floor=$NCCL_FLOOR_GBPS"; FAIL=1; }
fi
if [ "$FAIL" = "1" ]; then emit "P2P_RESULT=FAIL_FLOOR（低于下限：吞吐不达，别当作通过）"; exit 8; fi
case "$VERDICT" in
  *全连通*) emit "P2P_RESULT=PASS"; exit 0 ;;
  *部分连通*) emit "P2P_RESULT=WARN_PARTIAL（不可达对会回退 CPU 中转，BIOS 关 ACS 后重测）"; exit 6 ;;
  *全不可达*) emit "P2P_RESULT=FAIL_NOP2P（必须 BIOS 关 ACS/IOMMU）"; exit 7 ;;
  *) emit "P2P_RESULT=UNKNOWN（日志里没有判读行）"; exit 9 ;;
esac
