#!/bin/bash
# 模型下载器 v1（国内优先：默认走 hf-mirror.com；非 gated 仓库无需 token）
# 用法：
#   bash download-model-v1.sh                     前台下载（默认仓库 albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE）
#   bash download-model-v1.sh --bg                后台下载：nohup＋pid 文件＋日志，调用方继续干别的
#   bash download-model-v1.sh --probe             只问镜像站仓库元信息（大小/分片数/gated?），不下载
# 可覆盖：REPO DEST HF_ENDPOINT RUNNER_IMG
# 断点续传：huggingface_hub 的 snapshot_download 对 local_dir 内的 incomplete 文件自动续传，重跑同命令即可。
# 结束自验：分片数与 index 映射一致、"有映射但缺文件"为 0、总字节数打印留档。
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE}"
DEST="${DEST:-$PKG/models/$(basename "$REPO")}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
RUNNER_IMG="${RUNNER_IMG:-nvcr.io/nvidia/eval-factory/lm-evaluation-harness:latest}"
MODE=fg
[ "${1:-}" = "--bg" ] && MODE=bg
[ "${1:-}" = "--probe" ] && MODE=probe
say(){ printf '%s\n' "$*"; }

say "repo=$REPO  endpoint=$HF_ENDPOINT  dest=$DEST  mode=$MODE"

probe(){
  curl -s -m 20 -H "Accept: application/json" "$HF_ENDPOINT/api/models/$REPO" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sh=[s for s in d.get('siblings',[]) if s['rfilename'].endswith('.safetensors')]
print('gated=',d.get('gated'),' shards=',len(sh))
used=d.get('usedStorage') or sum(s.get('size') or 0 for s in d.get('siblings',[]))
print('size_GiB=%.1f'%(used/1024**3))
" 2>/dev/null || say "probe 失败（镜像站不可达？换 HF_ENDPOINT 或检查网络）"
}
[ "$MODE" = "probe" ] && { probe; exit 0; }

mkdir -p "$DEST" || exit 2
LOG="$DEST/.download.log"; PIDF="$DEST/.download.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  say "已有下载在跑 pid=$(cat "$PIDF")，日志 $LOG；不重复起"; exit 0
fi

run_dl(){
  if python3 -c 'import huggingface_hub' 2>/dev/null; then
    say "runner=host python3 + huggingface_hub"
    HF_ENDPOINT="$HF_ENDPOINT" python3 - "$REPO" "$DEST" <<'PY'
import sys, os
from huggingface_hub import snapshot_download
p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], resume_download=True)
print("SNAPSHOT_DONE", p)
PY
  else
    say "runner=docker $RUNNER_IMG（宿主无 huggingface_hub）"
    docker run --rm -v "$DEST:/dst" -e HF_ENDPOINT="$HF_ENDPOINT" --entrypoint python3 "$RUNNER_IMG" - "$REPO" <<'PY'
import sys
from huggingface_hub import snapshot_download
p = snapshot_download(repo_id=sys.argv[1], local_dir="/dst", resume_download=True)
print("SNAPSHOT_DONE", p)
PY
  fi
}

verify(){
  python3 - "$DEST" <<'PY'
import json, os, sys
d = sys.argv[1]
idx = os.path.join(d, "model.safetensors.index.json")
if not os.path.exists(idx):
    print("VERIFY_NO_INDEX"); sys.exit(1)
wm = json.load(open(idx)).get("weight_map", {})
need = sorted(set(wm.values()))
miss = [f for f in need if not os.path.exists(os.path.join(d, f))]
tot = sum(os.path.getsize(os.path.join(d, f)) for f in need if os.path.exists(os.path.join(d, f)))
print("shards_needed=%d shards_present=%d missing_mapped=%d total_GiB=%.1f"
      % (len(need), len(need) - len(miss), len(miss), tot / 1024**3))
sys.exit(1 if miss else 0)
PY
}

if [ "$MODE" = "bg" ]; then
  nohup bash -c "$(declare -f say run_dl verify); REPO='$REPO' DEST='$DEST' HF_ENDPOINT='$HF_ENDPOINT' RUNNER_IMG='$RUNNER_IMG'; run_dl && verify && echo DOWNLOAD_ALL_DONE || echo DOWNLOAD_FAILED" \
    > "$LOG" 2>&1 &
  echo $! > "$PIDF"
  say "后台下载已起 pid=$(cat "$PIDF") 日志=$LOG"
  say "查看进度: tail -f $LOG ；完成后日志尾部会有 DOWNLOAD_ALL_DONE"
  exit 0
fi

run_dl && verify && say "DOWNLOAD_ALL_DONE" || { say "DOWNLOAD_FAILED（重跑同命令即续传）"; exit 3; }
