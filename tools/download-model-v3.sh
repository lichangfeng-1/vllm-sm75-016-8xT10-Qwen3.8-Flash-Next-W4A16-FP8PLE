#!/bin/bash
# 模型下载器 v3（2026-10-01 三轮隔离审查 W1-W6 ＋第二轮隔离审查 V25-V27，清单见 CHANGELOG.md）
#   V48 宿主分支 runner 选完必须 return（旧版会继续往下掉进 docker 兜底分支＝一次调用下两回），
#       并改用 shell 变量前缀而不是 env 命令（本机实测 Git Bash 的 env 会吞掉继承的 stdin，
#       管道里的下载代码进不了 python；Linux 上两者等价，但少一个外部命令更稳）。
#   V46 --verify-sha：拿站点 API 的 LFS oid（即每片 sha256）逐片比本地文件，回应"分片只查存在性、
#       权重全程零校验"；要重读全量权重故默认不开。V47 REVISION / HF_VERSION：钉仓库修订与
#       huggingface_hub 版本的口子（默认空＝行为同旧版；不内置具体版本号，避免凭记忆造数）。
#   V25 阻断：DL_CODE 是**变量**，而 --bg 只把函数经 declare -f 交给 bash -c，变量不在其中 →
#       子进程里 heredoc 展开成空，三个 runner 都给 python 喂空程序、秒退，日志只有 DOWNLOAD_FAILED，
#       下载从未发生。改成函数 dl_code 产出代码、用管道喂 stdin。
#   V26 probe 失败仍 exit 0（调用方 MODE=dlprobe 无从判成败）。
#   V27 heredoc 一律加引号：python 代码里将来出现 $ 也不会被宿主 shell 抢先展开。
#   W1 两个 docker runner 都没加 -i：heredoc 的 python 代码进不了容器 stdin → 容器里 python 收到空输入，
#      表现为"下载任务立刻退出/无输出"，而调用方以为在下载；
#   W2 镜像 runner 只传了 repo 没传 local_dir → snapshot_download(sys.argv[2]) 直接 IndexError；
#      且宿主机路径在容器里不存在，必须用挂载点 /dst；
#   W3 python:3.11-slim runner 把宿主 $DEST 当容器内路径传 → 权重落进容器可写层，docker --rm 后全丢；
#   W4 DEST 必须是绝对路径（bind 挂载源要求绝对），否则容器起不来且报错绕；
#   W5 开下载前查一次磁盘余量并打印体量（120GiB 级写到只剩 50G 的盘上会中途 ENOSPC）；
#   W6 容器内解释器固定 python3（宿主 PYBIN 可能叫 python，容器里未必有同名软链）。
# v2（2026-10-01 二轮 review）：D1 后台 nohup 接 </dev/null；D2 DEST 不拼进 bash -c 字符串（改环境继承）；
#   D3 resume_download 按签名探测；D4 兜底镜像改候选链（宿主 hf_hub → 包内镜像 → python:3.11-slim）。
# 国内优先：默认 hf-mirror.com；推荐仓非 gated，无需 token。
# 用法：
#   bash download-model-v3.sh              前台下载
#   bash download-model-v3.sh --bg         后台下载：nohup＋pid 文件＋日志，调用方继续干别的
#   bash download-model-v3.sh --probe      只问镜像站元信息（体量/分片数/gated?），不下载
#   bash download-model-v3.sh --verify     只校验已下载目录（分片齐不齐＋总字节）
# 可覆盖：REPO DEST HF_ENDPOINT HF_RUNNER_IMG PYBIN PYIN_IMG REVISION HF_VERSION
# 退出码：0 成功 / 2 参数或路径不合法 / 3 校验没过（缺片）/ 4 站点清单取不到 / 5 清单与本地 index 不一致
# 断点续传：snapshot_download 对 local_dir 内的 incomplete 文件自动续传，重跑同命令即可。
set -u
PKG="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE}"
DEST="${DEST:-$PKG/models/$(basename "$REPO")}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_ENDPOINT   # V48：改成脚本级 export——三个 runner 都要它，而 per-command 前缀要借 env 命令，
                     # 本机实测 Git Bash 的 env 会把管道里的 stdin 吞掉（Linux 正常），少一个外部命令更稳
HF_RUNNER_IMG="${HF_RUNNER_IMG:-}"
PYIN_IMG="${PYIN_IMG:-python3}"
REVISION="${REVISION:-}"        # V47：非空＝snapshot_download(revision=...) 钉到某个仓库修订
HF_VERSION="${HF_VERSION:-}"    # V47：非空＝slim runner 里 pip 装这个版本（不凭记忆内置版本号）
if [ -z "${PYBIN:-}" ]; then
  for C in python3 python; do
    command -v "$C" >/dev/null 2>&1 && "$C" -c 'import sys, json' >/dev/null 2>&1 && { PYBIN=$C; break; }
  done
fi
[ -n "${PYBIN:-}" ] || { echo "!! 缺可用的 python3/python（存在但跑不动的别名不算）"; exit 2; }
MODE="fg"
case "${1:-}" in
  --bg) MODE="bg" ;;
  --probe) MODE="probe" ;;
  --verify) MODE="verify" ;;
  '') ;;
  --verify-sha) MODE="verifys" ;;
  *) echo "!! 未知参数: $1（可用 --bg / --probe / --verify / --verify-sha）"; exit 2 ;;
esac
say(){ printf '%s\n' "$*"; }
die(){ say "!! $*"; exit 2; }

# W4：DEST 绝对性——相对路径在 bind 挂载时会变成容器里看不见的东西（probe 不写盘，不受此限）
if [ "$MODE" != "probe" ]; then
  case "$DEST" in
    /*) ;;
    *) die "DEST 必须是绝对路径（bind 挂载源要求绝对）: $DEST" ;;
  esac
fi

say "repo=$REPO  endpoint=$HF_ENDPOINT  dest=$DEST  mode=$MODE  py=$PYBIN"

# V25：下载代码必须是函数（随 declare -f 进后台子进程），用管道喂 python 的 stdin
# V27：heredoc 加引号 → 代码里的 $ 不会被宿主 shell 展开。argv[1]=repo，argv[2]=local_dir
dl_code(){
  cat <<'PYEOF'
import inspect, sys
from huggingface_hub import snapshot_download
kw = {}
if "resume_download" in inspect.signature(snapshot_download).parameters:
    kw["resume_download"] = True
if len(sys.argv) > 3 and sys.argv[3]:
    kw["revision"] = sys.argv[3]      # V47
p = snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], **kw)
print("SNAPSHOT_DONE", p)
PYEOF
}

probe(){
  curl -s -m 20 -H "Accept: application/json" "$HF_ENDPOINT/api/models/$REPO" | "$PYBIN" -c "
import json,sys
d=json.load(sys.stdin)
sh=[s for s in d.get('siblings',[]) if s['rfilename'].endswith('.safetensors')]
print('gated=',d.get('gated'),' shards=',len(sh))
used=d.get('usedStorage') or sum(s.get('size') or 0 for s in d.get('siblings',[]))
print('size_GiB=%.1f'%(used/1024**3))
" 2>/dev/null || { say "!! probe 失败（镜像站不可达？换 HF_ENDPOINT 或检查网络）"; return 1; }
}
if [ "$MODE" = "probe" ]; then
  probe; rc=$?
  [ "$rc" = "0" ] || say "（probe 非零退出 rc=$rc；不影响其它模式）"
  exit "$rc"
fi

# 只有真要写盘的模式才建目录（verify/probe 不该在包内留空目录）
if [ "$MODE" = "bg" ] || [ "$MODE" = "fg" ]; then
  mkdir -p "$DEST" || die "建不了下载目录 $DEST"
  # W5：磁盘余量——按推荐仓约 120GiB 的 1.2 倍要求（留 incomplete 与解压余量）；探不到就只提示不拦
  FREE_G=$(df -BG --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' G')
  if [ -n "${FREE_G:-}" ]; then
    say "disk_free_G=$FREE_G（本仓约 120GiB；建议 >=140G）"
    [ "${FREE_G:-0}" -ge 140 ] || say "!! 余量偏紧（<140G）：可能中途 ENOSPC；可用 DEST= 换到大盘再重跑"
  else
    say "disk_free_G=? （df 探测失败，不阻断；请自行确认 $DEST 所在盘余量）"
  fi
fi
LOG="$DEST/.download.log"; PIDF="$DEST/.download.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  say "已有下载在跑 pid=$(cat "$PIDF")，日志 $LOG；不重复起"; exit 0
fi

runner(){
  # $1=docker 镜像 $2=仓库修订(可空)；容器内挂载点固定 /dst（W2/W3：不用宿主路径）
  docker run --rm -i -v "$DEST:/dst" -e HF_ENDPOINT="$HF_ENDPOINT" --entrypoint "$PYIN_IMG" "$1" - \
    "$REPO" "/dst" "${2:-}"
}

run_dl(){
  if $PYBIN -c 'import huggingface_hub' 2>/dev/null; then
    say "runner=host $PYBIN + huggingface_hub"
    dl_code | "$PYBIN" - "$REPO" "$DEST" "$REVISION"
    return
  fi
  command -v docker >/dev/null 2>&1 || { say "宿主无 huggingface_hub 且无 docker，下不动"; return 1; }
  IMG=""
  if [ -n "$HF_RUNNER_IMG" ] && docker image inspect "$HF_RUNNER_IMG" >/dev/null 2>&1; then IMG="$HF_RUNNER_IMG"; fi
  if [ -z "$IMG" ]; then
    for C in vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple vllm-sm75-next-ultra-0924:patched-nvapi-awqple; do
      docker image inspect "$C" >/dev/null 2>&1 && { IMG="$C"; break; }
    done
  fi
  if [ -n "$IMG" ]; then
    say "runner=docker $IMG（宿主无 huggingface_hub，用包内已建镜像；容器内 $PYIN_IMG）"
    dl_code | runner "$IMG" "$REVISION"
  else
    say "runner=docker python:3.11-slim 现装 huggingface_hub（需外网；要固定镜像用 HF_RUNNER_IMG 覆盖）"
    PIPARG=huggingface_hub
    [ -z "$HF_VERSION" ] || PIPARG="huggingface_hub==$HF_VERSION"   # V47：默认不钉，不凭记忆造版本号
    dl_code | docker run --rm -i -v "$DEST:/dst" -e HF_ENDPOINT="$HF_ENDPOINT" \
      --entrypoint sh python:3.11-slim -c \
      'pip install -q -U "$1" >/dev/null && exec python3 - "$2" "$3" "$4"' _ \
      "$PIPARG" "$REPO" "/dst" "$REVISION"
  fi
}

verify(){
  $PYBIN - "$DEST" <<'PY'
import json, os, sys
d = sys.argv[1]
idx = os.path.join(d, "model.safetensors.index.json")
if not os.path.exists(idx):
    print("VERIFY_NO_INDEX"); sys.exit(1)
try:
    wm = json.load(open(idx, encoding="utf-8")).get("weight_map", {})
except Exception as e:
    print("VERIFY_BAD_INDEX", e); sys.exit(1)
need = sorted(set(wm.values()))
miss = [f for f in need if not os.path.exists(os.path.join(d, f))]
tot = sum(os.path.getsize(os.path.join(d, f)) for f in need if os.path.exists(os.path.join(d, f)))
print("shards_needed=%d shards_present=%d missing_mapped=%d total_GiB=%.1f"
      % (len(need), len(need) - len(miss), len(miss), tot / 1024**3))
if miss:
    print("MISSING: " + " ".join(miss[:8]) + (" ..." if len(miss) > 8 else ""))
sys.exit(1 if miss else 0)
PY
}

if [ "$MODE" = "bg" ]; then
  # D1/D2：stdin 接 /dev/null 不偷调用方交互；REPO/DEST 走环境继承，不拼进 shell 字符串；
  #        函数体经 declare -f 传给孩子（体内只引用变量名，值在孩子运行时从环境取）
  # V3 配套：孩子 cmdline 里会出现 run_dl 标记，start-here 值守据此认进程
  REPO="$REPO" DEST="$DEST" HF_ENDPOINT="$HF_ENDPOINT" HF_RUNNER_IMG="$HF_RUNNER_IMG" PYBIN="$PYBIN" PYIN_IMG="$PYIN_IMG" \
  REVISION="$REVISION" HF_VERSION="$HF_VERSION" \
    nohup bash -c "$(declare -f say dl_code runner run_dl verify); run_dl && verify && echo DOWNLOAD_ALL_DONE || echo DOWNLOAD_FAILED" \
    < /dev/null > "$LOG" 2>&1 &
  echo $! > "$PIDF"
  say "后台下载已起 pid=$(cat "$PIDF") 日志=$LOG"
  say "查看进度: tail -f $LOG ；完成后日志尾部会有 DOWNLOAD_ALL_DONE"
  exit 0
fi

if [ "$MODE" = "verifys" ]; then
  # V46：站点 API 的 LFS oid 就是每片的 sha256，逐片比本地文件（回应"权重零校验"）
  say "按 $HF_ENDPOINT 的 LFS oid 逐片校验 sha256（要读完 $DEST，120GiB 级需几十分钟）"
  HF_ENDPOINT="$HF_ENDPOINT" $PYBIN - "$DEST" "$REPO" "$REVISION" <<'PY'
import hashlib, json, os, sys, urllib.request
d, repo, rev = sys.argv[1], sys.argv[2], (sys.argv[3] or '')
api = os.environ.get('HF_ENDPOINT', 'https://hf-mirror.com').rstrip('/') + '/api/models/' + repo
if rev:
    api += '/revision/' + rev
try:
    with urllib.request.urlopen(api, timeout=60) as r:
        info = json.load(r)
except Exception as e:
    print('SHA_VERIFY_API_FAIL', e); sys.exit(4)
checked = 0
checked_names = []
bad = 0
for sib in info.get('siblings', []):
    name = sib.get('rfilename', '')
    if not name.endswith('.safetensors'):
        continue
    checked += 1
    checked_names.append(name)
    oid = ((sib.get('lfs') or {}).get('oid') or '').split(':')[-1]
    path = os.path.join(d, name)
    if not oid:
        print('NO_OID', name); bad += 1; continue
    if not os.path.exists(path):
        print('MISSING', name); bad += 1; continue
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 24), b''):
            h.update(blk)
    got = h.hexdigest()
    if got != oid:
        print('SHA_MISMATCH', name, 'local=' + got, 'remote=' + oid); bad += 1
    else:
        print('SHA_OK', name)
# 不许"空洞通过"：站点没给可比清单，或站点清单与本地 index 的分片集合不一致，都算失败
need = set()
lidx = os.path.join(d, 'model.safetensors.index.json')
if os.path.exists(lidx):
    try:
        with open(lidx, encoding='utf-8') as f:
            need = set(json.load(f).get('weight_map', {}).values())
    except Exception:
        need = set()
if not checked:
    print('SHA_VERIFY_NOTHING_CHECKED（站点没返回可比对的 .safetensors 清单）')
    sys.exit(5)
if need and need != set(checked_names):
    print('SHA_VERIFY_SET_MISMATCH 本地 index 要 %d 片，站点清单给了 %d 片' % (len(need), len(checked_names)))
    sys.exit(5)
print('sha_verified=%d SHA_VERIFY_BAD=%d' % (checked, bad))
sys.exit(1 if bad else 0)
PY
  rc=$?
  [ "$rc" = "0" ] && say "SHA_VERIFY_OK" || say "SHA_VERIFY_FAILED rc=$rc（缺片、换源、站点不给 oid、与本地 index 不一致都会走到这里）"
  exit "$rc"
fi

if [ "$MODE" = "verify" ]; then
  verify && say "VERIFY_OK" || { say "VERIFY_FAILED"; exit 3; }
  exit 0
fi

run_dl && verify && say "DOWNLOAD_ALL_DONE" || { say "DOWNLOAD_FAILED（重跑同命令即续传）"; exit 3; }
