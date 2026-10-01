#!/bin/bash
# 模型下载器 v2（2026-10-01 二轮 review 修订，v1 留档同目录；国内优先：默认 hf-mirror.com，非 gated 仓无需 token）
# v1 的实证/静态问题（见 内部/审查记录-自包含部署包-v1.md §v3.2 D1-D4）：
#   D1 后台 nohup 没接 </dev/null，会偷走调用方交互提示的 stdin（本机踩过的同类坑）；
#   D2 使用者输入的 DEST 被拼进 bash -c "..." 字符串，含单引号即断、且属注入面；改为环境变量继承；
#   D3 resume_download= 在 huggingface_hub 新版已移除/弃用，硬传会 TypeError；改为按签名探测后才传；
#   D4 兜底镜像默认 nvcr.io 的评测镜像，从未验证可匿名拉取；改为候选链：宿主 hf_hub → 自建镜像 → python:3.11-slim 现装。
# 用法：
#   bash download-model-v2.sh                 前台下载（默认仓库 albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE）
#   bash download-model-v2.sh --bg            后台下载：nohup＋pid 文件＋日志，调用方继续干别的
#   bash download-model-v2.sh --probe         只问镜像站仓库元信息（大小/分片数/gated?），不下载
# 可覆盖：REPO DEST HF_ENDPOINT HF_RUNNER_IMG PYBIN
# 断点续传：snapshot_download 对 local_dir 内的 incomplete 文件自动续传，重跑同命令即可。
# 结束自验：分片数与 index 映射一致、"有映射但缺文件"为 0、总字节数打印留档。
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE}"
DEST="${DEST:-$PKG/models/$(basename "$REPO")}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_RUNNER_IMG="${HF_RUNNER_IMG:-}"
if [ -z "${PYBIN:-}" ]; then
  for C in python3 python; do
    command -v "$C" >/dev/null 2>&1 && "$C" -c 'import sys, json' >/dev/null 2>&1 && { PYBIN=$C; break; }
  done
fi
[ -n "${PYBIN:-}" ] || { echo "!! 缺可用的 python3/python（存在但跑不动的别名不算）"; exit 2; }
MODE="fg"
[ "${1:-}" = "--bg" ] && MODE="bg"
[ "${1:-}" = "--probe" ] && MODE="probe"
[ "${1:-}" = "--verify" ] && MODE="verify"
say(){ printf '%s\n' "$*"; }

say "repo=$REPO  endpoint=$HF_ENDPOINT  dest=$DEST  mode=$MODE  py=$PYBIN"

probe(){
  curl -s -m 20 -H "Accept: application/json" "$HF_ENDPOINT/api/models/$REPO" | $PYBIN -c "
import json,sys
d=json.load(sys.stdin)
sh=[s for s in d.get('siblings',[]) if s['rfilename'].endswith('.safetensors')]
print('gated=',d.get('gated'),' shards=',len(sh))
used=d.get('usedStorage') or sum(s.get('size') or 0 for s in d.get('siblings',[]))
print('size_GiB=%.1f'%(used/1024**3))
" 2>/dev/null || say "probe 失败（镜像站不可达？换 HF_ENDPOINT 或检查网络）"
}
[ "$MODE" = "probe" ] && { probe; exit 0; }

# 只有真要写盘的模式才建目录（verify/probe 不该在包内留空目录）
if [ "$MODE" = "bg" ] || [ "$MODE" = "fg" ]; then mkdir -p "$DEST" || exit 2; fi
LOG="$DEST/.download.log"; PIDF="$DEST/.download.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  say "已有下载在跑 pid=$(cat "$PIDF")，日志 $LOG；不重复起"; exit 0
fi

# D3：resume_download 只在当前 huggingface_hub 签名里存在时才传（三处 heredoc 内联同一逻辑）
run_dl(){
  if $PYBIN -c 'import huggingface_hub' 2>/dev/null; then
    say "runner=host $PYBIN + huggingface_hub"
    HF_ENDPOINT="$HF_ENDPOINT" $PYBIN - "$REPO" "$DEST" <<'PY'
import inspect, sys
from huggingface_hub import snapshot_download
kw = {}
if "resume_download" in inspect.signature(snapshot_download).parameters:
    kw["resume_download"] = True
p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], **kw)
print("SNAPSHOT_DONE", p)
PY
  else
    IMG=""
    if [ -n "$HF_RUNNER_IMG" ] && docker image inspect "$HF_RUNNER_IMG" >/dev/null 2>&1; then IMG="$HF_RUNNER_IMG"; fi
    if [ -z "$IMG" ]; then
      for C in vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple vllm-sm75-next-ultra-0924:patched-nvapi-awqple; do
        docker image inspect "$C" >/dev/null 2>&1 && { IMG="$C"; break; }
      done
    fi
    if [ -n "$IMG" ]; then
      say "runner=docker $IMG（宿主无 huggingface_hub，用包内已建镜像）"
      docker run --rm -v "$DEST:/dst" -e HF_ENDPOINT="$HF_ENDPOINT" --entrypoint "$PYBIN" "$IMG" - "$REPO" <<'PY'
import inspect, sys
from huggingface_hub import snapshot_download
kw = {}
if "resume_download" in inspect.signature(snapshot_download).parameters:
    kw["resume_download"] = True
p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], **kw)
print("SNAPSHOT_DONE", p)
PY
    else
      say "runner=docker python:3.11-slim 现装 huggingface_hub（需外网；要固定镜像用 HF_RUNNER_IMG 覆盖）"
      docker run --rm -v "$DEST:/dst" -e HF_ENDPOINT="$HF_ENDPOINT" --entrypoint sh python:3.11-slim -c \
        'pip install -q -U huggingface_hub && python3 - "$1" "$2"' _ "$REPO" "$DEST" <<'PY'
import inspect, sys
from huggingface_hub import snapshot_download
kw = {}
if "resume_download" in inspect.signature(snapshot_download).parameters:
    kw["resume_download"] = True
p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], **kw)
print("SNAPSHOT_DONE", p)
PY
    fi
  fi
}

verify(){
  $PYBIN - "$DEST" <<'PY'
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
  # D1/D2：stdin 接 /dev/null 不偷交互输入；REPO/DEST 走环境继承，不拼进 shell 字符串；
  #        函数体经 declare -f 传给孩子（体内只引用变量名，值在孩子运行时从环境取）
  REPO="$REPO" DEST="$DEST" HF_ENDPOINT="$HF_ENDPOINT" HF_RUNNER_IMG="$HF_RUNNER_IMG" PYBIN="$PYBIN" \
    nohup bash -c "$(declare -f say run_dl verify); run_dl && verify && echo DOWNLOAD_ALL_DONE || echo DOWNLOAD_FAILED" \
    < /dev/null > "$LOG" 2>&1 &
  echo $! > "$PIDF"
  say "后台下载已起 pid=$(cat "$PIDF") 日志=$LOG"
  say "查看进度: tail -f $LOG ；完成后日志尾部会有 DOWNLOAD_ALL_DONE"
  exit 0
fi

if [ "$MODE" = "verify" ]; then
  verify && say "VERIFY_OK" || { say "VERIFY_FAILED"; exit 3; }
  exit 0
fi

run_dl && verify && say "DOWNLOAD_ALL_DONE" || { say "DOWNLOAD_FAILED（重跑同命令即续传）"; exit 3; }
