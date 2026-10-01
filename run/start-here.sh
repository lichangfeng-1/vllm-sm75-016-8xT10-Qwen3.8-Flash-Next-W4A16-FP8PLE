#!/bin/bash
# 自包含部署 启动脚本 v3.5（2026-10-01 两轮共六条线隔离审查修订 V1-V42，清单见 CHANGELOG.md）
#   V1/V2/V3 下载值守：pid 已亡先看完成标记（下载先于值守结束是常态，旧版把"已下完"当故障杀）；
#       后台 cmdline 是 bash -c "...run_dl..."，旧版 grep download-model 永假；加 12h 上限不死等；
#   V6 挂载改数组＋docker 参数加引号（路径含空格不再碎成残参）；V7/V23 MODE=p2p/dlprobe 不再问模型目录；
#   V8/V10 值域与路径校验对 env 传入值同样生效（旧版只查交互输入）＋DATA/CROOT 绝对性与系统目录门禁；
#   V13 yn 大小写/前缀容错；V15 ask 去首尾全角与半角空格；V18 临时文件全 mktemp 077＋token 字符集校验；
#   V4 pending 编译档映射 incple；V5 shard_gate 认 index 解析失败；V9 P2P rc=8 视为不通过；
#   V11 编译 6h 上限；V12 CACHE_SRC 先建目录；V14 TORCH_IMG 显式传给 P2P 套件；
#   V16 镜像名与 IMAGE 覆盖语义不变；V17 docker run 失败给三因排查；V19-V22 文案与常用命令自含登录步骤；
#   V23 二轮脚本迁 v3；V24 dlprobe 最前早退、env 给定有效 MODEL_DIR 不再多问；
#   V28-V42 第二轮三条线隔离审查修订：V29 值守完成标记优先、V30 下载问句只属 MODE=full 与 served 名优先级、
#   V31 四处 API 看 HTTP 码、V32 Ctrl-C 真退出、V33 指定 IMAGE 不代编译、V34 拒 IPv6 绑定、
#   V35 MODE=p2p 免硬件门槛、V36 容器内凭据路径加引号、V37 MODEL_DIR 绝对性、V38 去死代码、
#   V39 FORCE=1 免交互强继续、V40 体量/时长口径、V42 MODE 取值校验。
# v3.4（2026-10-01 交互习惯修订 U1-U4，见 CHANGELOG.md）
# 自包含部署 启动脚本 v3.3（2026-10-01 服务器模拟实证修订 F14-F15，清单见 CHANGELOG.md）
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
# v1.1/v2 保留作 lineage。修订清单见 CHANGELOG.md。
# MODE: env / detect / p2p / dlprobe / full（默认 full）
set -u
SH_VER="v3.5"
PKG="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${MODE:-full}"
case "$MODE" in env|detect|p2p|dlprobe|full) ;; *)
  printf "!! MODE 只认 env/detect/p2p/dlprobe/full（收到: %s）" "$MODE"; echo; exit 2 ;; esac
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
FWSP=$'　'   # 全角空格（V15：ask 去首尾空格用；写成 $'' 形式免得依赖外部变量）
say(){ printf '%s\n' "$*"; }
die(){ say "!! $*"; exit 2; }
cleanup(){ rm -f "${JAR:-}" "${TOKF:-}" "${PROFF:-}" "${EXTF:-}" "${APITMP:-}" 2>/dev/null; }
api_post(){ # api_post <save|use> <url> [json文件]
  #   成功(2xx)返回 0；响应体在 API_BODY、状态码在 API_HTTP
  #   V31：旧版只 grep '"error"'，curl 连不上/被吞成 404 时响应体为空会被当成功一路跑到健康等待
  local __mode=$1 __u=$2 __f=${3:-} __extra
  [ -n "${APITMP:-}" ] || APITMP=$(mktemp /tmp/sm75-resp.XXXXXX) || return 1
  if [ "$__mode" = save ]; then __extra=(-c "$JAR"); else __extra=(-b "$JAR"); fi
  : > "$APITMP"
  if [ -n "$__f" ]; then
    API_HTTP=$(curl -s "${__extra[@]}" -m 60 -o "$APITMP" -w '%{http_code}' -X POST "$__u" \
      -H 'Content-Type: application/json' --data @"$__f" 2>/dev/null)
  else
    API_HTTP=$(curl -s "${__extra[@]}" -m 60 -o "$APITMP" -w '%{http_code}' -X POST "$__u" 2>/dev/null)
  fi
  API_BODY=$(cat "$APITMP" 2>/dev/null)
  case "$API_HTTP" in 2??) return 0 ;; *) return 1 ;; esac
}
ask(){ # ask 变量名 "提示" 默认值 —— 回车即默认
  # F10：不用 eval，默认值/输入含空格或 $ 都安全
  # V15：去首尾全角/半角空格（输入法常带全角空格），
  #      留着会给 docker 挂载与路径判断埋雷
  local __n=$1 __p=$2 __d=$3 __v __o
  printf '%s【%s】: ' "$__p" "$__d"; read -r __v
  __v="${__v:-$__d}"
  while :; do
    __o=$__v
    __v="${__v#"$FWSP"}"; __v="${__v# }"
    __v="${__v%"$FWSP"}"; __v="${__v% }"
    [ "$__v" = "$__o" ] && break
  done
  # 去结尾斜杠（保留单独的 /）
  while [ "$__v" != "/" ] && [ "${__v%/}" != "$__v" ]; do
    __v="${__v%/}"
  done
  printf -v "$__n" '%s' "$__v"
}
yn(){ # yn "提示" 默认Y/N；返回0=是
  local __p=$1 __d=$2 __v
  printf '%s【%s】: ' "$__p" "$__d"; read -r __v
  __v=${__v:-$__d}
  # U1/V13：中文习惯＋大小写容错（先转小写再匹配，Yes/NO/OK 都能认）；识别不了才回落到默认方向
  __v=$(printf '%s' "$__v" | tr 'A-Z' 'a-z')
  # V13 前缀容错：先判否、再判是，"不用了""好的"按字面方向走；
  #   两条都对不上才回落到默认方向
  case "$__v" in n|no|否*|不*|2) return 1 ;; esac
  case "$__v" in y|yes|是*|好*|确认*|s|ok*) return 0 ;; esac
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

# ---------- 0a) MODE=dlprobe：只问镜像站元信息，与本机硬件/模型都无关，最先早退 ----------
if [ "$MODE" = "dlprobe" ]; then
  REPO="$REC_REPO" bash "$PKG/tools/download-model-v3.sh" --probe; exit $?
fi

# ---------- 0) 环境检测（国内优先；只读） ----------
if [ "$MODE" != "detect" ]; then
  ENVLOG="$PKG/run/env-$TS.log"
  bash "$PKG/run/env-check.sh" | tee "$ENVLOG"
  ERC=${PIPESTATUS[0]}
  if [ "$ERC" = "5" ]; then
    if [ "${FORCE:-0}" = "1" ]; then
      say "!! FORCE=1 免交互强继续；不兼容项留档 $ENVLOG"
    elif yn "环境与参考环境（8xT10 SM75 / Ubuntu 24.04 / 驱动>=570）差异过大。仍要强制继续吗（后果自负）" N; then
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
fi
# V10：值域校验对"交互输入"和"env 传入"一视同仁（旧版只查交互，MMBT=999 或 UTIL=0.99 会一路带到 vLLM 才炸）
case "$MMBT" in 2048|4096|8192) ;; *) die "MMBT 只接受 2048/4096/8192（实测 2048 与 4096 均长程验证过；8192 未验证、有 OOM 风险）收到: $MMBT" ;; esac
$PYBIN -c "import sys;u=float(sys.argv[1]);sys.exit(0 if 0.5<=u<=0.95 else 1)" "$UTIL" 2>/dev/null || die "util 需在 0.50-0.95（收到: $UTIL）"
for P in "$CONSOLE_PORT" "$ENGINE_PORT"; do
  case "$P" in ''|*[!0-9]*) die "端口必须是数字: $P" ;; esac
  [ "$P" -ge 1 ] && [ "$P" -le 65535 ] || die "端口越界: $P"
done
[ "$CONSOLE_PORT" != "$ENGINE_PORT" ] || die "控制台端口与引擎端口不能相同"
case "$BIND_HOST" in
  0.0.0.0) ;;
  *[!0-9.]*|"") die "BIND_HOST 只支持 0.0.0.0 或具体 IPv4（收到: $BIND_HOST；IPv6 未验证且 --publish 形态不同）" ;;
esac
if [ "$BIND_HOST" = "0.0.0.0" ]; then
  say "!! 注意：端口发布到所有网卡（局域网可达；控制台能起引擎≈宿主权限）。请确保只在可信网段使用。"
fi
# V8/V44：DATA 会以 rw 挂进容器（容器内 root 可写），所以
#   ① 先 readlink -f 再判前缀——否则 /tmp/l -> /home/x/xxx 这类软链直接绕过门禁；
#   ② 路径里不许有逗号或等号——docker 的 --mount type=bind,source=X,target=Y 是逗号分隔键值串，
#      实测过带逗号的路径能把额外键（如 bind-propagation）注进去。
badpath(){ # badpath <名字> <值>
  case "$2" in /*) ;; *) die "$1 必须是绝对路径: $2" ;; esac
  case "$2" in *,*) die "$1 不能含逗号（会破坏 --mount 的键值串）: $2" ;; esac
  case "$2" in *=*) die "$1 不能含等号（会被 --mount 解析成额外键）: $2" ;; esac
  return 0
}
case "$DATA" in
  /|/bin|/sbin|/etc|/usr|/var|/boot|/dev|/proc|/sys|/home|/root|"${HOME:-/nonexistent}")
    die "DATA 不能是系统目录或家目录（会以 rw 挂进容器）: $DATA" ;;
esac
badpath DATA "$DATA"
DATA_REAL="$DATA"
if command -v readlink >/dev/null 2>&1; then
  DATA_REAL="$(readlink -f "$DATA" 2>/dev/null)" || DATA_REAL="$DATA"
  [ "$DATA_REAL" = "$DATA" ] || say "DATA 经符号链接解析为 $DATA_REAL（门禁按解析后的判）"
fi
case "$DATA_REAL" in
  /home/*|/root/*|/usr/*|/etc/*|/var/*|/bin/*|/sbin/*|/boot/*|/dev/*|/proc/*|/sys/*)
    die "DATA 解析后落在系统目录/家目录树下，拒绝: $DATA_REAL" ;;
esac
if [ -n "$CACHE_SRC" ]; then
  badpath CACHE_SRC "$CACHE_SRC"
  CS_REAL="$CACHE_SRC"
  if command -v readlink >/dev/null 2>&1; then
    CS_REAL="$(readlink -f "$CACHE_SRC" 2>/dev/null)" || CS_REAL="$CACHE_SRC"
  fi
  case "$CS_REAL" in
    /|/bin|/sbin|/etc|/usr|/var|/boot|/dev|/proc|/sys|/home|/root|"${HOME:-/nonexistent}"|/home/*|/root/*|/usr/*|/etc/*|/var/*)
      die "CACHE_SRC 也会以 rw 挂进容器，拒绝系统目录/家目录树: $CS_REAL" ;;
  esac
fi
badpath CROOT "$CROOT"          # 它是 --mount …,target=$CROOT 的后半，同样禁逗号/等号
badpath MNT_MODEL "$MNT_MODEL"  # 同理：--mount …,target=$MNT_MODEL
say "采用配置: 控制台=$CONSOLE_PORT 引擎=$ENGINE_PORT 数据目录=$DATA MMBT=$MMBT util=$UTIL served=${SERVED:-<模型目录名>}"

# ---------- 1) 模型：有就用，没有就问要不要后台下载 ----------
# V7/V23：p2p 只测卡间连通，旧版在这个模式也要答模型目录，答错直接 die 或偷起 120GiB 下载
#（MODE=dlprobe 已在 0a 早退）
DEF_DEST="$PKG/models/$(basename "$REC_REPO")"
if [ "$MODE" = "p2p" ]; then
  MODEL_DIR="${MODEL_DIR:-$DEF_DEST}"
  say "MODE=p2p：只测卡间连通，不需要模型（跳过目录询问）"
elif [ ! -d "${MODEL_DIR:-}" ] && [ -n "${MODEL_DIR:-}" ]; then
  die "MODEL_DIR 指了不存在的目录: $MODEL_DIR"
elif [ -f "${MODEL_DIR:-}/config.json" ]; then
  # V24：env 已给定且确实是模型目录就不再问（免交互路径少一问，见 README 的 </dev/null 用法）
  say "模型目录（env 给定，已含 config.json）: $MODEL_DIR"
else
  ask MODEL_DIR "模型目录（含 config.json 与 safetensors）" "${MODEL_DIR:-$DEF_DEST}"
fi
badpath MODEL_DIR "$MODEL_DIR"   # V44：直通 --mount source=，同样禁逗号/等号
case "$MODEL_DIR" in /*) ;; *) die "MODEL_DIR 必须是绝对路径（bind 挂载源要求绝对）: $MODEL_DIR" ;; esac
if [ ! -f "$MODEL_DIR/config.json" ] && [ "$MODE" != "p2p" ]; then
  [ "$MODE" = "full" ] || die "该目录没有可用模型；MODE=$MODE 不代下载（要下载用默认 MODE=full；只想知道仓在不在用 MODE=dlprobe）"
  say "该目录还没有模型（或不是模型目录）。"
  say "推荐模型: $REC_REPO （HuggingFace 独家、非 gated；约 120GiB、27 分片；国内走 hf-mirror.com）"
  if yn "是否现在后台下载推荐模型到 $MODEL_DIR （前台继续部署，起引擎前会等它下完并校验）" Y; then
    REPO="$REC_REPO" DEST="$MODEL_DIR" bash "$PKG/tools/download-model-v3.sh" --bg || die "下载任务起不来"
    DLPID="$(cat "$MODEL_DIR/.download.pid" 2>/dev/null)"
    DLLOG="$MODEL_DIR/.download.log"
    say "下载已后台启动 pid=${DLPID:-?} 日志=$DLLOG（tail -f 可看进度；重跑同命令可续传）"
  else
    ask MODEL_DIR "那请给一个已有模型的目录" "$MODEL_DIR"
    [ -f "$MODEL_DIR/config.json" ] || die "仍没有可用模型目录，退出（只想测连通用 MODE=p2p）"
  fi
fi
# ---------- 1b) 分片门禁（下载中的目录此刻可能不全，起引擎前还会再验一次） ----------
shard_gate(){
  local IDX="$1/model.safetensors.index.json" MISS
  [ -f "$1/config.json" ] || { say "SHARD_GATE_NO_CONFIG"; return 1; }
  [ -f "$IDX" ] && {
    MISS=$($PYBIN - "$IDX" "$1" <<'PY' 2>/dev/null
import json,os,sys
wm=json.load(open(sys.argv[1])).get('weight_map',{})
print(' '.join(f for f in sorted(set(wm.values())) if not os.path.exists(os.path.join(sys.argv[2],f))))
PY
) || { say "SHARD_GATE_BAD_INDEX（model.safetensors.index.json 解析失败/损坏）"; return 1; }
    [ -n "$MISS" ] && { say "SHARD_GATE_MISSING: $MISS"; return 1; }
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
# F4/V9：判别输出必须是五态之一（incple/awq/base/pending/unknown）；python 崩溃/输出为空时在这里停下，而不是带着空 IMG 走到 set -u 崩
case "$CFG" in
  incple|awq|base|pending) ;;
  unknown) die "未识别的量化方法 method='${METHOD:-?}'（$REASON）——停下来人工确认，不猜" ;;
  *) die "判别输出异常 CFG='${CFG:-<空>}'（config.json 不可解析或 python 崩溃）；人工检查 $MODEL_DIR/config.json" ;;
esac
if [ "$CFG" != "pending" ]; then
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
# V35：硬件门槛是给"部署"定的；MODE=p2p 只测卡间连通，低配机也该能测
# V51：探测不到显存/内存时按"不达标"处理（旧写法 [ "" -lt N ] 会报错并判假，等于门禁静默放行）
for V in "$VRAM_G" "$MEMG"; do
  case "$V" in ''|*[!0-9]*) say "!! 探不到显存/内存数值（nvidia-smi 或 /proc/meminfo 不可用），按低于验证配置处理"; V=$V; break ;; esac
done
HWLOW=0
case "$VRAM_G" in ''|*[!0-9]*) HWLOW=1 ;; *) [ "$VRAM_G" -lt "$REQ_VRAM_G" ] && HWLOW=1 ;; esac
case "$MEMG"   in ''|*[!0-9]*) HWLOW=1 ;; *) [ "$MEMG"   -lt "$REQ_RAM_G" ] && HWLOW=1 ;; esac
if [ "$MODE" != "p2p" ] && [ "$HWLOW" = "1" ]; then
  say "!! 低于本包验证配置。模型卡上的小卡 offload 路线本包未验证（缺对应 offload 参数）。"
  if [ "${FORCE:-0}" = "1" ]; then
    say "!! FORCE=1 免交互强继续（硬件低于验证配置）"
  else
    yn "仍要强制继续吗（可能加载失败或 OOM，后果自负）" N || die "使用者选择不强制继续（无人值守可给 FORCE=1）"
  fi
  say "!! FORCE 继续：硬件低于验证配置（显存 ${VRAM_G}G / 内存 ${MEMG}G）"
fi

# ---------- 3) 后台编译镜像 ＋ 并行 P2P 套件 ----------
BUILDLOG="$PKG/run/build-$TS.log"; BPID=""
if [ "$MODE" = "p2p" ]; then
  say "MODE=p2p：只跑 P2P 套件，不起编译不部署（F13：旧版在此模式也会偷起一个无人值守的 70G 编译）"
elif [ -n "${IMAGE:-}" ] && ! docker image inspect "$IMG" >/dev/null 2>&1; then
  die "IMAGE=$IMG 是你指定的，本脚本不代编译这个名字（build.sh 只产内置标签；要让补丁层产这名请用 BASE_IMG/OUT_TAG/OUT2_TAG/OUT3_TAG，或先把镜像准备出来）"
elif ! docker image inspect "$IMG" >/dev/null 2>&1; then
  say "镜像不在: $IMG → 后台编译，日志 $BUILDLOG"
  BUILD_CFG="$CFG"; [ "$BUILD_CFG" = "pending" ] && BUILD_CFG=incple
  nohup bash "$PKG/docker/build.sh" "$BUILD_CFG" > "$BUILDLOG" 2>&1 &
  BPID=$!
  say "build_pid=$BPID"
fi
P2PLOG="$PKG/run/p2p-suite-$TS.log"
OUT="$P2PLOG" TORCH_IMG="$TORCH_IMG" bash "$PKG/tools/p2p-suite-run-v3.sh" || P2PRC=$?
P2PRC=${P2PRC:-0}
grep -a '^P2P_' "$P2PLOG" 2>/dev/null | sed 's/^/  /'
say "P2P 套件退出码=$P2PRC（0 全连通 / 3 跳过未跑 / 6 部分连通 / 7 全不可达 / 8 低于你设的下限 / 9 无判读行）；全文 $P2PLOG"
case "$P2PRC" in
  3) say "!! P2P 本次未跑（GPU 被占或 torch 镜像不在）：跳过≠通过，结论里不得写 P2P 已过" ;;
  7) die "P2P 全不可达：先 BIOS 关 ACS/IOMMU 再部署，否则 NCCL 全走 CPU" ;;
  8) die "P2P 带宽低于你设的下限（P2P_FLOOR_GBPS/NCCL_FLOOR_GBPS），不通过，见 $P2PLOG" ;;
  9) say "!! P2P 日志缺判读行：套件可能中途崩溃，人工看 $P2PLOG" ;;
esac
# F14：p2p 模式到此为止（v3.2 丢了这句早退，P2P 跑完会继续起容器走全流程）
[ "$MODE" = "p2p" ] && { say "MODE=p2p 完成"; exit "$P2PRC"; }

# ---------- 3b) 值守编译 ----------
if [ -n "$BPID" ]; then
  say "值守镜像编译…"
  T0=$(date +%s)
  BCAP=0
  while kill -0 "$BPID" 2>/dev/null; do
    BCAP=$((BCAP+1)); [ "$BCAP" -gt 1440 ] && { say "!! 编译超 6 小时上限，停下人工看 $BUILDLOG（不再死等）"; exit 5; }
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
  # V29：完成标记优先——pid 可能早已退出并被复用（编译值守数小时后是常态），
  #      先认 DOWNLOAD_ALL_DONE 才不会把已成功的下载当故障杀
  if grep -aq 'DOWNLOAD_ALL_DONE' "$DLLOG" 2>/dev/null; then
    say "下载已完成（日志里有 DOWNLOAD_ALL_DONE），直接进入校验"
  elif ! kill -0 "$DLPID" 2>/dev/null; then
    say "!! 下载 pid=$DLPID 已不存在，日志里也没有 DOWNLOAD_ALL_DONE（下载中断过）；人工看 $DLLOG，重跑同命令可续传"; exit 5
  else
    # V3：后台是 bash -c "...run_dl..."（declare -f 展开，命令行里没有脚本名）；旧版 grep download-model 永假→必误杀
    if [ -r "/proc/$DLPID/cmdline" ] && ! tr '\0' ' ' < "/proc/$DLPID/cmdline" 2>/dev/null | grep -aqE 'run_dl|snapshot_download'; then
      say "!! pid=$DLPID 的命令行不像下载任务（pid 复用？）：$(tr '\0' ' ' < "/proc/$DLPID/cmdline" 2>/dev/null | cut -c1-80)"; exit 5
    fi
    say "值守模型下载 pid=$DLPID…（Ctrl-C 不中断后台下载；进度：tail -f $DLLOG）"
    DCAP=0
    while kill -0 "$DLPID" 2>/dev/null; do
      DCAP=$((DCAP+1)); [ "$DCAP" -gt 1440 ] && { say "!! 下载超 12 小时上限，停下人工看 $DLLOG（不再死等）"; exit 5; }
      sleep 30
      say "  …已下载 $(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)（日志尾: $(tail -1 "$DLLOG" 2>/dev/null | cut -c1-60)）"
    done
  fi
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
  case "$CFG" in incple|awq|base) ;; *) die "下载完成后判别仍异常 CFG='${CFG:-<空>}' method='${METHOD:-?}'（未识别的量化方法请人工确认，不猜）" ;; esac
  case "$CFG" in
    incple) IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"; PROF=profile-autoround-incple.json ;;
    awq)    IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-awq-int4.json ;;
    base)   IMG="${IMAGE:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}";        PROF=profile-fp8-base.json ;;
  esac
  say "下载后复核: 配置=$CFG 镜像=$IMG"
  if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    [ -z "${IMAGE:-}" ] || die "IMAGE=$IMG 由你指定且本机不在，本脚本不代编译这个名字"
    say "镜像不在，补编译…"
    bash "$PKG/docker/build.sh" "$CFG" || die "补编译失败"
    docker image inspect "$IMG" >/dev/null 2>&1 || die "补编译结束但镜像仍不在: $IMG"
  fi
fi

# ---------- 4) 起控制台容器（不 rm 任何既有容器） ----------
# F5：在跑与"已停止但同名"分开报，后者 docker run 会因重名失败，提示用 rename 而不是删
[ -z "$(docker ps -q -f name="^$NAME$")" ] || die "已有同名容器在跑: $NAME（先自行 stop/rename，本脚本不删容器）"
[ -z "$(docker ps -aq -f name="^$NAME$")" ] || die "存在同名但已停止的容器: $NAME（docker run 会因重名失败；请自行 docker rename $NAME ${NAME}-old-保留，本脚本不删不改任何容器）"
mkdir -p "$DATA" || die "建不了数据目录 $DATA"
# 这个目录里落 key/token/引擎日志：显式 0700（旧版建目录时 umask 还是 022，凭据目录以 0755 出生）
chmod 700 "$DATA" 2>/dev/null || say "!! chmod 700 $DATA 未成功（目录属主不是你？），凭据文件权限会偏松"
[ -z "$CACHE_SRC" ] || { mkdir -p "$CACHE_SRC" || die "建不了缓存目录 $CACHE_SRC"; }
# F3/F11：容器内根与编译缓存目标都跟 CROOT 走（旧版写死 /console-data，SM75_CONSOLE_ROOT 一改就读不到 token）；
#        CACHE_SRC 挂到真实 cacheRoot（$CROOT/cache，见 console store.mjs 默认值），旧版挂 /cache/fp8 在单容器形态下不生效
# V6：数组传参——路径含空格不再被词拆分（旧版字符串拼接会把一个挂载碎成两个残参，docker 报莫名其妙的错）
MOUNTS=(--mount "type=bind,source=$DATA,target=$CROOT")
[ -z "$CACHE_SRC" ] || MOUNTS+=(--mount "type=bind,source=$CACHE_SRC,target=$CROOT/cache")
say "起容器 $NAME（镜像 $IMG）…"
docker run --detach --name "$NAME" \
  --gpus all --network bridge --ipc private --restart unless-stopped \
  --shm-size "$SHM_SIZE" --ulimit memlock=-1:-1 --ulimit nofile=1048576:1048576 \
  "${MOUNTS[@]}" \
  --mount "type=bind,source=$MODEL_DIR,target=$MNT_MODEL,readonly" \
  --publish "$BIND_HOST:$CONSOLE_PORT:1615" \
  --publish "$BIND_HOST:$ENGINE_PORT:8000" \
  --env TZ=Asia/Shanghai --env "SM75_CONSOLE_ROOT=$CROOT" --env SM75_CONSOLE_HOST=0.0.0.0 \
  --env SM75_CONSOLE_PORT=1615 --env SM75_SINGLE_CONTAINER=1 --env VLLM_SM75_QWEN38_HC_GEMV=1 \
  --env SM75_FA2_SMALLQ_GRAPH=1 --env SM75_GDN_B1_METADATA=1 \
  --env VLLM_FLASHINFER_WORKSPACE_BUFFER_SIZE=134217728 --env OMP_NUM_THREADS=1 \
  --env VLLM_USE_MODELSCOPE=true --env MODELSCOPE_CACHE=/root/.cache/modelscope/hub \
  "$IMG" >/dev/null || {
    say "!! docker run 失败。常见三因：端口被占（ss -lntp | grep -E ':$CONSOLE_PORT|:$ENGINE_PORT'）、挂载源不存在、没有 nvidia 运行时（docker info | grep -i nvidia）"
    die "起容器失败（按上一行排查；本脚本不删任何既有容器）"; }
for i in $(seq 1 60); do
  sleep 2
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$PROBE_HOST:$CONSOLE_PORT/" 2>/dev/null)" = "200" ] && break
done
[ "$(curl -s -o /dev/null -w '%{http_code}' -m 4 "http://$PROBE_HOST:$CONSOLE_PORT/" 2>/dev/null)" = "200" ] || die "控制台 120 秒内没起来（探针 http://$PROBE_HOST:$CONSOLE_PORT/），看 docker logs $NAME"

# ---------- 5) 登录（token）＋建档＋启动 ----------
TOKFILE=$CROOT/key
for i in $(seq 1 30); do [ -n "$(docker exec "$NAME" cat "$TOKFILE" 2>/dev/null)" ] && break; sleep 2; done
TOKEN="$(docker exec "$NAME" cat "$TOKFILE" 2>/dev/null | tr -d '\r\n')"
[ -n "$TOKEN" ] || die "读不到控制台登录 token（$TOKFILE）"
# V18：全走 mktemp（可预测的 /tmp/sm75-*-$$ 在多用户宿主上可被抢建/被读，cookie 与 token 都是凭据）
umask 077
trap 'cleanup; exit 130' INT    # V53：trap 先装再建文件，中途 die 也不会把带 token 的临时文件留下
trap 'cleanup; exit 143' TERM
trap cleanup EXIT
JAR=$(mktemp /tmp/sm75-cookie.XXXXXX) || { cleanup; die "mktemp 失败"; }
PROFF=$(mktemp /tmp/sm75-profile.XXXXXX) || { cleanup; die "mktemp 失败"; }
TOKF=$(mktemp /tmp/sm75-login.XXXXXX) || { cleanup; die "mktemp 失败"; }
case "$TOKEN" in *[!A-Za-z0-9_-]*) die "token 含异常字符（应为 base64url），拒绝拼进 JSON" ;; esac
printf '{"token":"%s"}' "$TOKEN" > "$TOKF"
umask 022
api_post save "http://$PROBE_HOST:$CONSOLE_PORT/console-api/login" "$TOKF"; LRC=$?
rm -f "$TOKF"   # V43：先登录后删（旧版把删文件放在前面，等于拿不存在的 --data 文件再发一次 POST）
if [ "$LRC" != "0" ]; then
  die "控制台登录失败（HTTP ${API_HTTP:-?}；token 被拒或主服务未就绪？看 docker logs $NAME）：${API_BODY:-<空响应>}"
fi
PID=sm75-deploy
export MMBT UTIL
SERVED="${SERVED:-$(basename "$MODEL_DIR")}"   # SERVED 初值已含 SERVED_NAME，交互输入优先
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
# F12：服务端拒绝原因回显（如"先停止候选模型再修改配置"），旧版只说"建档失败"没法排障
api_post use "http://$PROBE_HOST:$CONSOLE_PORT/console-api/profiles" "$PROFF"; PRC=$?
rm -f "$PROFF"
if [ "$PRC" != "0" ]; then
  die "建档失败（HTTP ${API_HTTP:-?}，服务端原因见下）：${API_BODY:-<空响应>}"
fi
say "启动引擎档 $PID（百 G 级权重：FP8PLE≈120G／AutoRound≈169G，要几分钟，耐心等）…"
if ! api_post use "http://$PROBE_HOST:$CONSOLE_PORT/console-api/profiles/$PID/start"; then
  die "启动档失败（HTTP ${API_HTTP:-?}）：${API_BODY:-<空响应>}"
fi

# ---------- 6) 模型测试的两个功能默认开启（测速 speedtest ＋ SQL 题） ----------
EXTF=$(mktemp /tmp/sm75-ext.XXXXXX) || die "mktemp 失败"
printf '{"enabled":true}' > "$EXTF"
for T in speedtest sql; do
  if api_post use "http://$PROBE_HOST:$CONSOLE_PORT/console-api/benchmarks/extension?type=$T" "$EXTF"; then
    say "已开启模型测试功能: $T"
  else
    say "!! 开启模型测试功能 $T 失败（HTTP ${API_HTTP:-?}）: ${API_BODY:-<空响应>}（不阻断启动；稍后可在控制台手动开）"
  fi
done

# ---------- 7) 等引擎健康 ----------
OK=0
say "等引擎健康（百 G 级权重约需 5-10 分钟，每 30 秒报一次进度，不是卡死）…"
for i in $(seq 1 90); do
  sleep 10
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$PROBE_HOST:$ENGINE_PORT/health" 2>/dev/null)" = "200" ] && { OK=1; break; }
  [ $((i % 3)) = 0 ] && say "  …已等 $((i*10))s（引擎日志：docker logs --tail 20 $NAME）"
done
[ "$OK" = "1" ] || { say "!! 引擎 15 分钟没健康；最后 30 行日志："; docker logs --tail 30 "$NAME" 2>&1 | tail -30; exit 3; }

# ---------- 8) 打印访问信息并提醒备份 ----------
APIKEY="$(docker exec "$NAME" cat "$CROOT/engine-key.current" 2>/dev/null | tr -d '\r\n')"
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
say "  常用命令（控制台的 API 要先登录拿 cookie，网页里点不用）："
say "    停/起引擎: 控制台网页（token 登录）里点最省事，不必碰 curl 与 cookie"
say "    要走 curl: token 用 docker exec 从容器里取出来，写进一个 600 权限的 JSON 文件，再用 --data @该文件"
say "              （别把 token 直接写进 curl 命令行——ps 和 shell 历史都会留下它；逐步命令见 部署文档-v1.md 第 4 节）"
say "    看日志:    docker logs --tail 50 $NAME   或容器内 $CROOT/$PID.log（跨次追加，取最后一段）"
say "  安全提醒: 跑过后本目录含 console-data/（token 与 API key）和 run/*.log——不要把本目录整体 git 提交或打包外发；"
say "            给别人的话重新 clone 仓库，或用 SHA256SUMS.txt 校验后的干净副本"
say "=============================================================="
say "START_HERE_DONE"
