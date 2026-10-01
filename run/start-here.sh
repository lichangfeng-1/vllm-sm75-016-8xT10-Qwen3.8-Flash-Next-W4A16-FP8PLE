#!/bin/bash
# 自包含部署 启动脚本 v3.4（2026-10-01 交互习惯修订 U1-U4，见 审查记录 §6.7）
# 自包含部署 启动脚本 v3.3（2026-10-01 服务器模拟实证修订 F14-F15，清单见 内部/审查记录-自包含部署包-v1.md §v3.3）
#   F14 v3.2 重构时丢了 MODE=p2p 的早退：P2P 跑完继续走全流程（模拟中 03:19 那轮因此误起了容器）；恢复早退；
#   F15 本镜像代（harness 0.1.7 集成后）主服务把 /api/* 全委派给 bridge，未登录一律 401/503：
#       登录与建档/启动/扩展改走 /console-api/* 前缀（活容器实证：/api/login=401、/console-api/login=ok:true、
#       /api/profiles=Harness 503、/console-api/profiles=[]）。
# v3.2 要点：修建档 python 的 os 未导入（F1，实证 NameError）；探针地址随 BIND_HOST（F2）；
#   CROOT 真正接进容器 env 与挂载目标（F3）；判别空值防护（F4）；同名已停容器给可操作提示（F5）；
#   P2P 跳过≠通过（F6）；编译错误 grep 收紧（F7）；下载 pid 新鲜度校验（F8）；模板字段缺失给可操作报错（F9）；
#   ask 去 eval（F10）；CACHE_SRC 挂到真实 cacheRoot（F11）；建档失败回显服务端原因（F12）；MODE=p2p 不再偷起编译（F13）。
# v3 原题：v2 全流程 ＋ 三件新东西：
#   ① 1Panel 式交互：所有可选项给【默认值】，回车即采用，想改就输入；另有"自定义配置"总开关；
#   ② 模型下载编排：没有模型时问一句"要不要后台下载推荐模型"，要就 nohup 起下载、前台继续部署，
#      起引擎前值守下载完成并重跑分片门禁（推荐模型＝hf 上的 FP8PLE 仓，国内走 hf-mirror，非 gated 无需 token）；
#   ③ P2P 换成七件套套件（tools/g292z20-nccl-tests）非交互运行＋机器可读判读，作为环境检测的一部分。
# 决策权保留：环境检测给推荐配置，但端口/数据目录/MMBT/util/served 名都可改；下载与否是问句不是默认动作之外的偷跑。
# v1.1/v2 保留作 lineage。修订清单见 审查记录-自包含部署包-v1.md §v3。
# MODE: env / detect / p2p / dlprobe / full（默认 full）
set -u
SH_VER="v3.4"
PKG="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${MODE:-full}"
TORCH_IMG="${TORCH_IMG:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
REC_REPO="${REC_REPO:-albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE}"
NAME="${NAME:-vllm-sm75-console}"
CONSOLE_PORT="${CONSOLE_PORT:-1615}"
ENGINE_PORT="${ENGINE_PORT:-18001}"
DATA="${DATA_DIR:-$PKG/console-data}"
CACHE_SRC="${CACHE_SRC:-}"
CROOT="${SM75_CONSOLE_ROOT:-/console-data}"
MNT_MODEL="${MNT_MODEL:-/models-ro}"
BIND_HOST="${BIND_HOST:-0.0.0.0}"
# F2：探针地址随 BIND_HOST 走（绑到具体网卡 IP 时 127.0.0.1 上没有监听，旧版会误报"没起来"）
if [ -z "${PROBE_HOST:-}" ]; then
  if [ "$BIND_HOST" = "0.0.0.0" ] || [ "$BIND_HOST" = "::" ]; then PROBE_HOST=127.0.0.1; else PROBE_HOST=$BIND_HOST; fi
fi
SHM_SIZE="${SHM_SIZE:-68719476736}"
MMBT="${MMBT:-2048}"
UTIL="${UTIL:-0.90}"
SERVED="${SERVED_NAME:-}"
JAR=""; TOKF=""; PROFF=""; DLPID=""; DLLOG=""
TS=$(date +%Y%m%d-%H%M%S)
say(){ printf '%s\n' "$*"; }
die(){ say "!! $*"; exit 2; }
ask(){ # ask 变量名 "提示" 默认值   —— 回车采用默认（F10：不用 eval，默认值/输入含空格或 $ 也安全）
  local __n=$1 __p=$2 __d=$3 __v
  printf '%s【%s】: ' "$__p" "$__d"; read -r __v
  __v="${__v:-$__d}"
  __v="${__v%$'　'}"   # U2：去掉全角空格/尾斜杠（输入法习惯），不给 docker 挂载留坑
  __v="${__v%% }"; while [ -n "$__v" ] && [ "${__v%/}" != "$__v" ] && [ "$__v" != "/" ]; do __v="${__v%/}"; done
  printf -v "$__n" '%s' "$__v"
}
yn(){ # yn "提示" 默认Y/N；返回0=是
  local __p=$1 __d=$2 __v
  printf '%s【%s】: ' "$__p" "$__d"; read -r __v
  __v=${__v:-$__d}
  # U1：中文习惯——"是/好/y/s"都算 yes，"否/n"算 no，其余按默认值方向
  case "$__v" in y|Y|yes|YES|是|好|确认|s|S) return 0 ;; n|N|no|NO|否|不|2) return 1 ;; esac
  [ "$__d" = "Y" ] && return 0 || return 1
}
command -v docker >/dev/null || die "缺 docker"
command -v curl >/dev/null || die "缺 curl"
# PYBIN：存在≠可用（Windows 商店别名 python3 存在但 rc=49 无输出，本机实测）；逐个真跑一次才认
PYBIN="${PYBIN:-}"
if [ -z "$PYBIN" ]; then
  for C in python3 python; do
    command -v "$C" >/dev/null 2>&1 && "$C" -c 'import sys, json' >/dev/null 2>&1 && { PYBIN=$C; break; }
  done
fi
[ -n "$PYBIN" ] || die "缺可用的 python3/python（存在但跑不动的别名不算）"

say "=============================================================="
say " SM75 v0.1.6 自包含部署 · start-here $SH_VER · $TS"
say " 包位置: $PKG"
say "=============================================================="

# ---------- 0) 环境检测（国内优先；只读） ----------
if [ "$MODE" != "detect" ]; then
  ENVLOG="$PKG/run/env-$TS.log"
  bash "$PKG/run/env-check.sh" | tee "$ENVLOG"
  ERC=${PIPESTATUS[0]}
  if [ "$ERC" = "5" ]; then
    if yn "环境与参考环境（8xT10 SM75 / Ubuntu 24.04 / 驱动>=570）差异过大。仍要强制继续吗（后果自负）" N; then
      say "!! FORCE 继续；不兼容项留档 $ENVLOG"
    else
      die "使用者选择不强制继续；差异项见 $ENVLOG"
    fi
  elif [ "$ERC" != "0" ]; then
    die "环境检测未通过 rc=$ERC（见 $ENVLOG）"
  fi
  [ "$MODE" = "env" ] && { say "MODE=env 完成，日志 $ENVLOG"; exit 0; }
fi
NGPU=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
MEMG=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)
say ""
say "检测到的环境：GPU $NGPU 张｜宿主内存 ${MEMG}G"
say "推荐配置（回车采用）：TP8＋EP、MMBT $MMBT、util $UTIL、KV 1.75GiB、ctx 262144、engram cpu_offload 开、关 MTP"
if yn "是否自定义部署配置（控制台端口/引擎端口/数据目录/MMBT/util/served 名）" N; then
  ask CONSOLE_PORT "控制台端口" "$CONSOLE_PORT"
  ask ENGINE_PORT  "引擎宿主端口" "$ENGINE_PORT"
  ask DATA         "控制台数据目录" "$DATA"
  ask MMBT         "max-num-batched-tokens（止血基线 2048；压测可 4096）" "$MMBT"
  ask UTIL         "gpu-memory-utilization（0.50-0.95）" "$UTIL"
  printf 'served-model-name（回车＝用模型目录名）【%s】: ' "${SERVED:-<模型目录名>}"; read -r __s
  [ -n "$__s" ] && SERVED="$__s"
  case "$MMBT" in 2048|4096|8192) ;; *) die "MMBT 只接受 2048/4096/8192（模板验证过这三档）" ;; esac
  $PYBIN -c "import sys;u=float(sys.argv[1]);sys.exit(0 if 0.5<=u<=0.95 else 1)" "$UTIL" || die "util 需在 0.50-0.95"
  for P in "$CONSOLE_PORT" "$ENGINE_PORT"; do
    case "$P" in ''|*[!0-9]*) die "端口必须是数字: $P" ;; esac
    [ "$P" -ge 1 ] && [ "$P" -le 65535 ] || die "端口越界: $P"
  done
  [ "$CONSOLE_PORT" != "$ENGINE_PORT" ] || die "控制台端口与引擎端口不能相同"
fi
say "采用配置: 控制台=$CONSOLE_PORT 引擎=$ENGINE_PORT 数据目录=$DATA MMBT=$MMBT util=$UTIL served=${SERVED:-<模型目录名>}"

# ---------- 1) 模型：有就用，没有就问要不要后台下载 ----------
DEF_DEST="$PKG/models/$(basename "$REC_REPO")"
ask MODEL_DIR "模型目录（含 config.json 与 safetensors）" "${MODEL_DIR:-$DEF_DEST}"
if [ ! -f "$MODEL_DIR/config.json" ]; then
  say "该目录还没有模型（或不是模型目录）。"
  say "推荐模型: $REC_REPO （HuggingFace 独家、非 gated；约 116GiB、25 分片；国内走 hf-mirror.com）"
  if yn "是否现在后台下载推荐模型到 $MODEL_DIR （前台继续部署，起引擎前会等它下完并校验）" Y; then
    REPO="$REC_REPO" DEST="$MODEL_DIR" bash "$PKG/tools/download-model-v2.sh" --bg || die "下载任务起不来"
    DLPID="$(cat "$MODEL_DIR/.download.pid" 2>/dev/null)"
    DLLOG="$MODEL_DIR/.download.log"
    say "下载已后台启动 pid=${DLPID:-?} 日志=$DLLOG（tail -f 可看进度；重跑同命令可续传）"
  else
    ask MODEL_DIR "那请给一个已有模型的目录" "$MODEL_DIR"
    [ -f "$MODEL_DIR/config.json" ] || die "仍没有可用模型目录，退出"
  fi
fi
[ "$MODE" = "dlprobe" ] && { REPO="$REC_REPO" bash "$PKG/tools/download-model-v2.sh" --probe; exit 0; }

# ---------- 1b) 分片门禁（下载中的目录此刻可能不全，起引擎前还会再验一次） ----------
shard_gate(){
  local IDX="$1/model.safetensors.index.json" MISS
  [ -f "$1/config.json" ] || { say "SHARD_GATE_NO_CONFIG"; return 1; }
  [ -f "$IDX" ] && {
    MISS=$($PYBIN - "$IDX" "$1" <<'PY'
import json,os,sys
wm=json.load(open(sys.argv[1])).get('weight_map',{})
print(' '.join(f for f in sorted(set(wm.values())) if not os.path.exists(os.path.join(sys.argv[2],f))))
PY
)
    [ -z "$MISS" ] || { say "SHARD_GATE_MISSING: $MISS"; return 1; }
  }
  say "SHARD_GATE_OK"
  return 0
}
shard_gate "$MODEL_DIR" || say "提示：分片暂不全（可能正在下载），起引擎前会再验"

# ---------- 2) 判别模型配置 ----------
DETECT=$($PYBIN - "$MODEL_DIR" 2>/dev/null <<'PY'
import json,sys
try:
    c=json.load(open(sys.argv[1].rstrip('/')+'/config.json'))
except Exception:
    print('pending', '-', 'config.json 还不可读（下载中？）；起引擎前会重新判别')
    raise SystemExit(0)
q=(c.get('quantization_config') or {})
m=str(q.get('quant_method') or ''); pack=str(q.get('packing_format') or '')
if m=='auto-round' or pack.startswith('auto_round'):
    print('incple', m or pack, 'AutoRound/INC：PLE 表未量化、Linear 带 auto_gptq 包，需 incple 镜像')
elif m in ('compressed-tensors','awq','gptq') or 'awq' in m:
    print('awq', m, 'compressed-tensors/AWQ 系：PLE 走未量化分支，用 awqple 镜像')
elif not m:
    print('base', 'none', '无量化配置：按 fp8/BF16 原始权重走 awqple 镜像')
else:
    print('unknown', m, '未识别的量化方法，停下来人工确认，不要猜')
PY
)
read -r CFG METHOD REASON <<<"$DETECT"
# F4：判别输出必须是四态之一；python 崩溃/输出为空时在这里停下，而不是带着空 IMG 走到 set -u 崩
case "$CFG" in incple|awq|base|pending) ;; *) die "判别输出异常 CFG='${CFG:-<空>}'（config.json 不可解析或 python 崩溃）；人工检查 $MODEL_DIR/config.json" ;; esac
if [ "$CFG" != "pending" ]; then
  [ "$CFG" = "unknown" ] && die "未识别的量化方法 method=$METHOD；请人工确认后再跑"
  say "判别结果: 配置=$CFG  quant_method=$METHOD"
  say "依据: $REASON"
fi
case "$CFG" in
  incple) IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"; PROF=profile-autoround-incple.json ;;
  awq)    IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-awq-int4.json ;;
  base)   IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-fp8-base.json ;;
  pending) IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"; PROF=profile-autoround-incple.json
           say "判别推迟到下载完成后（推荐模型是 auto-round，先按 incple 准备镜像）" ;;
esac
[ "$MODE" = "detect" ] && { say "MODE=detect 完成 cfg=$CFG img=$IMG profile=$PROF"; exit 0; }

# ---------- 2b) 硬件门槛：本包验证配置＝总显存>=128G 且宿主内存>=128G ----------
# 出处：本包在 G292-Z20（8xT10 16G=128G 显存、252G 内存）实测跑通；engram n-gram 表单独占约 95-96G 宿主内存。
# 模型卡 tags 自列消费级路线（rtx-3090/single-gpu/dual-gpu/24gb-vram/64gb-ram/cpu-offload），那是**另一个推理栈**（外部专用框架＋专家卸载）的宣传标签，不是本包 vLLM 路线的要求；本包不支持也不验证该路线。
REQ_VRAM_G="${REQ_VRAM_G:-128}"
REQ_RAM_G="${REQ_RAM_G:-128}"
VRAM_G=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s/1024}')
say "硬件门槛: 总显存 ${VRAM_G}G / 要求 >=${REQ_VRAM_G}G；宿主内存 ${MEMG}G / 要求 >=${REQ_RAM_G}G"
if [ "${VRAM_G:-0}" -lt "$REQ_VRAM_G" ] || [ "${MEMG:-0}" -lt "$REQ_RAM_G" ]; then
  say "!! 低于本包验证配置。模型卡上的小卡 offload 路线本包未验证（缺对应 offload 参数）。"
  yn "仍要强制继续吗（可能加载失败或 OOM，后果自负）" N || die "使用者选择不强制继续"
  say "!! FORCE 继续：硬件低于验证配置（显存 ${VRAM_G}G / 内存 ${MEMG}G）"
fi

# ---------- 3) 后台编译镜像 ＋ 并行 P2P 套件 ----------
BUILDLOG="$PKG/run/build-$TS.log"; BPID=""
if [ "$MODE" = "p2p" ]; then
  say "MODE=p2p：只跑 P2P 套件，不起编译不部署（F13：旧版在此模式也会偷起一个无人值守的 70G 编译）"
elif ! docker image inspect "$IMG" >/dev/null 2>&1; then
  say "镜像不在: $IMG → 后台编译，日志 $BUILDLOG"
  nohup bash "$PKG/docker/build.sh" "${CFG:-incple}" > "$BUILDLOG" 2>&1 &
  BPID=$!
  say "build_pid=$BPID"
fi
P2PLOG="$PKG/run/p2p-suite-$TS.log"
OUT="$P2PLOG" bash "$PKG/tools/p2p-suite-run-v2.sh" || P2PRC=$?
P2PRC=${P2PRC:-0}
grep -a '^P2P_' "$P2PLOG" 2>/dev/null | sed 's/^/  /'
say "P2P 套件退出码=$P2PRC（0 全连通 / 3 跳过未跑 / 6 部分连通 / 7 全不可达 / 8 低于你设的下限 / 9 无判读行）；全文 $P2PLOG"
case "$P2PRC" in
  3) say "!! P2P 本次未跑（GPU 被占或 torch 镜像不在）：跳过≠通过，结论里不得写 P2P 已过" ;;
  7) die "P2P 全不可达：先 BIOS 关 ACS/IOMMU 再部署，否则 NCCL 全走 CPU" ;;
  9) say "!! P2P 日志缺判读行：套件可能中途崩溃，人工看 $P2PLOG" ;;
esac
# F14：p2p 模式到此为止（v3.2 丢了这句早退，P2P 跑完会继续起容器走全流程）
[ "$MODE" = "p2p" ] && { say "MODE=p2p 完成"; exit "$P2PRC"; }

# ---------- 3b) 值守编译 ----------
if [ -n "$BPID" ]; then
  say "值守镜像编译…"
  T0=$(date +%s)
  while kill -0 "$BPID" 2>/dev/null; do
    sleep 15
    grep -aqE '^ERROR|failed to solve|returned a non-zero|no space left|ERROR: failed to' "$BUILDLOG" 2>/dev/null && {
      say "!! 编译出错，尾 25 行："; tail -25 "$BUILDLOG"; exit 5; }
    say "  …编译中 $(( $(date +%s) - T0 ))s"
  done
  wait "$BPID"; BRC=$?
  [ "$BRC" = "4" ] && { say "!! 基座镜像缺失：按 build.sh 打印的两条路（docker load 基座 tar 或 BOOTSTRAP=1）处理后再跑"; exit 4; }
  [ "$BRC" = "0" ] || { say "!! 编译退出码 $BRC"; tail -30 "$BUILDLOG"; exit 5; }
  grep -aq 'BUILD_DONE' "$BUILDLOG" || { say "!! 缺 BUILD_DONE 标记"; tail -20 "$BUILDLOG"; exit 5; }
  docker image inspect "$IMG" >/dev/null 2>&1 || die "编译结束但镜像不在: $IMG"
  say "镜像编译完成（$(( $(date +%s) - T0 ))s）"
fi

# ---------- 3c) 值守模型下载（若起了）；完成后重跑分片门禁与判别 ----------
if [ -n "$DLPID" ]; then
  # F8：pid 新鲜度校验，防上一次运行残留/复用的 pid 把值守循环带进死等
  if ! kill -0 "$DLPID" 2>/dev/null; then
    say "!! 下载 pid=$DLPID 已不存在且日志无完成标记；人工看 $DLLOG"; exit 5
  fi
  if [ -r "/proc/$DLPID/cmdline" ] && ! tr '\0' ' ' < "/proc/$DLPID/cmdline" 2>/dev/null | grep -aq 'download-model'; then
    say "!! pid=$DLPID 的命令行不像下载任务（pid 复用？）：$(tr '\0' ' ' < "/proc/$DLPID/cmdline" 2>/dev/null | cut -c1-80)"; exit 5
  fi
  say "值守模型下载 pid=$DLPID…"
  while kill -0 "$DLPID" 2>/dev/null; do
    sleep 30
    say "  …已下载 $(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)（日志尾: $(tail -1 "$DLLOG" 2>/dev/null | cut -c1-60)）"
  done
  grep -aq 'DOWNLOAD_ALL_DONE' "$DLLOG" || { say "!! 下载未成功完成，尾 20 行："; tail -20 "$DLLOG"; exit 5; }
  shard_gate "$MODEL_DIR" || die "下载完成但分片门禁不过"
  DETECT=$($PYBIN - "$MODEL_DIR" <<'PY'
import json,sys
c=json.load(open(sys.argv[1].rstrip('/')+'/config.json'))
q=(c.get('quantization_config') or {})
m=str(q.get('quant_method') or ''); pack=str(q.get('packing_format') or '')
if m=='auto-round' or pack.startswith('auto_round'): print('incple', m, 'AutoRound/INC')
elif m in ('compressed-tensors','awq','gptq') or 'awq' in m: print('awq', m, 'compressed-tensors/AWQ 系')
elif not m: print('base', 'none', '无量化')
else: print('unknown', m, '未识别')
PY
)
  read -r CFG METHOD REASON <<<"$DETECT"
  case "$CFG" in incple|awq|base) ;; *) die "下载完成后判别仍异常 CFG='${CFG:-<空>}' method='${METHOD:-?}'" ;; esac
  [ "$CFG" = "unknown" ] && die "下载完仍判别失败 method=$METHOD"
  case "$CFG" in
    incple) IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"; PROF=profile-autoround-incple.json ;;
    awq)    IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-awq-int4.json ;;
    base)   IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-fp8-base.json ;;
  esac
  say "下载后复核: 配置=$CFG 镜像=$IMG"
  docker image inspect "$IMG" >/dev/null 2>&1 || { say "镜像不在，补编译…"; bash "$PKG/docker/build.sh" "$CFG" || die "补编译失败"; }
fi

# ---------- 4) 起控制台容器（不 rm 任何既有容器） ----------
# F5：在跑与"已停止但同名"分开报，后者 docker run 会因重名失败，提示用 rename 而不是删
[ -z "$(docker ps -q -f name="^$NAME$")" ] || die "已有同名容器在跑: $NAME（先自行 stop/rename，本脚本不删容器）"
[ -z "$(docker ps -aq -f name="^$NAME$")" ] || die "存在同名但已停止的容器: $NAME（docker run 会因重名失败；请自行 docker rename $NAME ${NAME}-old-保留，本脚本不删不改任何容器）"
mkdir -p "$DATA" || die "建不了数据目录 $DATA"
# F3/F11：容器内根与编译缓存目标都跟 CROOT 走（旧版写死 /console-data，SM75_CONSOLE_ROOT 一改就读不到 token）；
#        CACHE_SRC 挂到真实 cacheRoot（$CROOT/cache，见 console store.mjs 默认值），旧版挂 /cache/fp8 在单容器形态下不生效
MOUNTS="--mount type=bind,source=$DATA,target=$CROOT"
[ -n "$CACHE_SRC" ] && MOUNTS="$MOUNTS --mount type=bind,source=$CACHE_SRC,target=$CROOT/cache"
say "起容器 $NAME（镜像 $IMG）…"
docker run --detach --name "$NAME" \
  --gpus all --network bridge --ipc private --restart unless-stopped \
  --shm-size $SHM_SIZE --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
  $MOUNTS \
  --mount type=bind,source="$MODEL_DIR",target=$MNT_MODEL,readonly \
  --publish $BIND_HOST:"$CONSOLE_PORT":1615 \
  --publish $BIND_HOST:"$ENGINE_PORT":8000 \
  --env TZ=Asia/Shanghai --env SM75_CONSOLE_ROOT=$CROOT --env SM75_CONSOLE_HOST=0.0.0.0 \
  --env SM75_CONSOLE_PORT=1615 --env SM75_SINGLE_CONTAINER=1 --env VLLM_SM75_QWEN38_HC_GEMV=1 \
  --env SM75_FA2_SMALLQ_GRAPH=1 --env SM75_GDN_B1_METADATA=1 \
  --env VLLM_FLASHINFER_WORKSPACE_BUFFER_SIZE=134217728 --env OMP_NUM_THREADS=1 \
  --env VLLM_USE_MODELSCOPE=true --env MODELSCOPE_CACHE=/root/.cache/modelscope/hub \
  "$IMG" >/dev/null || die "docker run 失败"
for i in $(seq 1 60); do
  sleep 2
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$PROBE_HOST:$CONSOLE_PORT/" 2>/dev/null)" = "200" ] && break
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$PROBE_HOST:$CONSOLE_PORT/" 2>/dev/null)" = "200" ] || die "控制台 60 秒内没起来（探针 http://$PROBE_HOST:$CONSOLE_PORT/），看 docker logs $NAME"

# ---------- 5) 登录（token）＋建档＋启动 ----------
TOKFILE=$CROOT/key
for i in $(seq 1 30); do [ -n "$(docker exec "$NAME" cat $TOKFILE 2>/dev/null)" ] && break; sleep 2; done
TOKEN="$(docker exec "$NAME" cat $TOKFILE 2>/dev/null | tr -d '\r\n')"
[ -n "$TOKEN" ] || die "读不到控制台登录 token（$TOKFILE）"
JAR=/tmp/sm75-cookie-$$
PROFF=/tmp/sm75-profile-$$
TOKF=/tmp/sm75-login-$$
trap 'rm -f "$JAR" "$TOKF" "$PROFF"' EXIT INT TERM
umask 077
printf '{"token":"%s"}' "$TOKEN" > "$TOKF"
umask 022
LOGINR=$(curl -s -c "$JAR" -X POST "http://$PROBE_HOST:$CONSOLE_PORT/console-api/login" -H 'Content-Type: application/json' \
  --data @"$TOKF")
rm -f "$TOKF"
printf '%s' "$LOGINR" | grep -q '"error"' && die "控制台登录失败（token 被拒？看 docker logs $NAME）：$LOGINR"
PID=sm75-deploy
export MMBT UTIL
SERVED="${SERVED_NAME:-${SERVED:-$(basename "$MODEL_DIR")}}"
CROOT="$CROOT" MNT_MODEL="$MNT_MODEL" MMBT="$MMBT" UTIL="$UTIL" $PYBIN - "$PKG/run/profiles/$PROF" "$SERVED" "$PID" > "$PROFF" <<'PY'
import json, os, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
p['id'] = sys.argv[3]
if not p['args']:
    sys.exit("模板 args 为空: " + sys.argv[1])
p['args'][0] = os.environ.get('MNT_MODEL', '/models-ro')
if '__SERVED__' not in p['args']:
    sys.exit("模板缺 __SERVED__ 占位符，无法填 served-model-name: " + sys.argv[1])
p['args'][p['args'].index('__SERVED__')] = sys.argv[2]
p['cacheRoot'] = os.environ.get('CROOT', '/console-data') + '/cache'
mb = os.environ.get('MMBT'); ut = os.environ.get('UTIL')
for flag, val in (('--max-num-batched-tokens', mb), ('--gpu-memory-utilization', ut)):
    if val and flag in p['args']:
        p['args'][p['args'].index(flag) + 1] = val
    elif val:
        sys.exit("模板缺 %s，无法按你的输入覆盖（改模板或去掉该输入）" % flag)
sys.stdout.write(json.dumps(p, ensure_ascii=False))
PY
[ -s "$PROFF" ] || die "建档 JSON 生成失败（模板 $PROF 不合规），见上"
PROFR=$(curl -s -b "$JAR" -X POST "http://$PROBE_HOST:$CONSOLE_PORT/console-api/profiles" -H 'Content-Type: application/json' \
  --data @"$PROFF")
rm -f "$PROFF"
# F12：服务端拒绝原因回显（如"先停止候选模型再修改配置"），旧版只说"建档失败"没法排障
printf '%s' "$PROFR" | grep -q '"error"' && die "建档失败：$PROFR"
say "启动引擎档 $PID（169G 级权重要几分钟，耐心等）…"
STARTR=$(curl -s -b "$JAR" -X POST "http://$PROBE_HOST:$CONSOLE_PORT/console-api/profiles/$PID/start")
printf '%s' "$STARTR" | grep -q '"error"' && die "启动档失败：$STARTR"

# ---------- 6) 模型测试的两个功能默认开启（测速 speedtest ＋ SQL 题） ----------
for T in speedtest sql; do
  R=$(curl -s -b "$JAR" -X POST "http://$PROBE_HOST:$CONSOLE_PORT/console-api/benchmarks/extension?type=$T" \
    -H 'Content-Type: application/json' -d '{"enabled":true}')
  if printf '%s' "$R" | grep -q '"error"'; then
    say "!! 开启模型测试功能 $T 失败: $R（不阻断启动；稍后可在控制台手动开）"
  else
    say "已开启模型测试功能: $T"
  fi
done

# ---------- 7) 等引擎健康 ----------
OK=0
say "等引擎健康（169G 级权重约需 5-10 分钟，每 30 秒报一次进度，不是卡死）…"
for i in $(seq 1 90); do
  sleep 10
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PROBE_HOST:$ENGINE_PORT/health" 2>/dev/null)" = "200" ] && { OK=1; break; }
  [ $((i % 3)) = 0 ] && say "  …已等 $((i*10))s（引擎日志：docker logs --tail 20 $NAME）"
done
[ "$OK" = "1" ] || { say "!! 引擎 15 分钟没健康；最后 30 行日志："; docker logs --tail 30 "$NAME" 2>&1 | tail -30; exit 3; }

# ---------- 8) 打印访问信息并提醒备份 ----------
APIKEY="$(docker exec "$NAME" cat $CROOT/engine-key.current 2>/dev/null | tr -d '\r\n')"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP=127.0.0.1
say ""
say "=============================================================="
say " 启动成功。请立刻把下面凭据抄走/备份（丢了只能重置）："
say "  控制台:   http://$IP:$CONSOLE_PORT   （本机 http://127.0.0.1:$CONSOLE_PORT）"
say "  登录方式: token 登录（无用户名）；token＝下面这串，也存在容器内 $TOKFILE"
say "  控制台token: $TOKEN"
say "  引擎:     http://$IP:$ENGINE_PORT/v1   （OpenAI 兼容）"
say "  引擎APIkey: $APIKEY   （容器内 $CROOT/engine-key.current）"
say "  备份建议: 把这两个文件 cp 到包外安全位置并 chmod 600；本屏幕输出请自行留存或清屏"
say "  模型测试: speedtest 与 sql 两个功能已请求默认开启（控制台里可见）"
say "  常用命令:  停引擎  curl -b <cookie> -X POST http://$PROBE_HOST:$CONSOLE_PORT/console-api/profiles/$PID/stop"
say "             起引擎  同上把 stop 换成 start；或直接进控制台网页操作"
say "             看日志  docker logs --tail 50 $NAME   或容器内 $CROOT/$PID.log（取最后一段）"
say "=============================================================="
say "START_HERE_DONE"
