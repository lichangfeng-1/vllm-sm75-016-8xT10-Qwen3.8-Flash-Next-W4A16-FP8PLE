#!/bin/bash
# 环境检测 v3（2026-10-01 二轮 review 修订 E1-E3，清单见 内部/审查记录-自包含部署包-v1.md §v3.2）
#   E1 daemon.json 解析写死 python3（坏别名/仅 python 的机器会静默报 none）→ 与 start-here 同款"真能跑才认"探测；
#   E2 可达性循环 `curl ... || echo 000` 在 curl 失败时会双行输出（-w 已先打印 000）→ 去掉兜底 echo；
#   E3 缺 nvidia-container-toolkit 时 --gpus all 必失败但旧版不查 → 新增 INCOMPAT 项（docker runtimes/ nvidia-ctk 两路探测）。
# 在 v1 的"只读体检"之上加两件事：
#   ① 内置**参考环境**（G292-Z20 实测值，逐条标注来源日期），优先推荐使用者同款硬件/系统；
#   ② 兼容性判定三档：OK / WARN（可继续）/ INCOMPAT（exit 5，由调用方问使用者是否 FORCE 强制继续）。
# 只读：不改任何系统配置（mirror/daemon.json 只报告不代改）。国内网络优先体现在顺序与内置 env。
# 退出码：0=OK 或 WARN；4=硬缺（docker/驱动）；5=INCOMPAT（等调用方决定 FORCE）。
set -u
say(){ printf '%s\n' "$*"; }
WARN=0; INCOMPAT=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYBIN=""
for C in python3 python; do
  command -v "$C" >/dev/null 2>&1 && "$C" -c 'import sys, json' >/dev/null 2>&1 && { PYBIN=$C; break; }
done
command -v curl >/dev/null 2>&1 || { say "CHK curl = HARD_FAIL（未安装，可达性与下载都靠它）"; exit 4; }

say "=== 参考环境（优先推荐同款；实测 2026-10-01 @ G292-Z20） ==="
say "ref_os=Ubuntu 24.04.x LTS | ref_kernel=6.8.x | ref_docker=29.8.0 | ref_driver=580.173.02"
say "ref_gpu=Tesla T10 16384MiB x8 | ref_sm=7.5 | ref_cuda_rt=12.9.1 | ref_mem=252G | ref_glibc=2.39"
say "（差异过大不强行执行：INCOMPAT 项会停下问你是否 FORCE；WARN 只提醒）"
say ""

say "=== 系统与内核 ==="
. /etc/os-release 2>/dev/null || PRETTY_NAME="unknown"
say "os=$PRETTY_NAME"
case "$PRETTY_NAME" in
  *Ubuntu\ 24.04*|*Ubuntu\ 22.04*) say "CHK os = OK（与参考同族）" ;;
  *) say "CHK os = WARN（非 Ubuntu 22.04/24.04；控制台与驱动安装路径可能有差异）"; WARN=1 ;;
esac
say "kernel=$(uname -r) glibc=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo unknown)"

say "=== docker 工具链 ==="
if command -v docker >/dev/null 2>&1; then
  DV=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  if [ -z "$DV" ]; then say "CHK docker = HARD_FAIL（守护进程连不上）"; exit 4; fi
  DMAJ=${DV%%.*}
  say "docker_server=$DV cli=$(docker version --format '{{.Client.Version}}' 2>/dev/null)"
  [ "${DMAJ:-0}" -ge 24 ] 2>/dev/null || { say "CHK docker_version = WARN（<24，未在本包验证过）"; WARN=1; }
  say "buildx=$(docker buildx version 2>/dev/null | head -1 || echo absent)"
  RT=$(docker info --format '{{json .Runtimes}}' 2>/dev/null)
  if printf '%s' "$RT" | grep -aq 'nvidia'; then
    say "gpu_runtime=found（docker runtimes 含 nvidia）"
  elif command -v nvidia-ctk >/dev/null 2>&1 || command -v nvidia-container-runtime >/dev/null 2>&1; then
    say "gpu_runtime=toolkit 在 PATH（docker runtimes 未列 nvidia，CDI/旧配置形态，起容器时自验）"
  else
    INCOMPAT="$INCOMPAT nvidia-container-toolkit 缺失(--gpus all 会失败) "
    say "CHK gpu_runtime = INCOMPAT（docker runtimes 无 nvidia 且无 nvidia-ctk；装 nvidia-container-toolkit 后再跑）"
  fi
  MIR=$($PYBIN -c "import json;print(','.join(json.load(open('/etc/docker/daemon.json')).get('registry-mirrors',[])))" 2>/dev/null)
  say "registry_mirrors=${MIR:-none}（none 时国内拉 docker.io 慢；本包不代改系统配置，可自行加 mirror）"
else
  say "CHK docker = HARD_FAIL（未安装）"; exit 4
fi

say "=== 驱动与 GPU（与参考逐项比） ==="
if ! command -v nvidia-smi >/dev/null 2>&1; then say "CHK driver = HARD_FAIL（无 nvidia-smi）"; exit 4; fi
DR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
NG=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)
GN=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
GM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
SM=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
say "driver=$DR gpus=$NG name=$GN mem=${GM}MiB sm=$SM"
DM=${DR%%.*}
[ "${DM:-0}" -ge 570 ] 2>/dev/null || INCOMPAT="$INCOMPAT driver<$DR:570(CUDA12.9 下限) "
[ "$NG" = "8" ] || INCOMPAT="$INCOMPAT gpu_count=$NG(模板 TP8 需 8) "
[ "$SM" = "7.5" ] || INCOMPAT="$INCOMPAT sm=$SM(本栈为 SM75 优化:flashqla_sm75 等) "
[ "$GM" = "16384" ] || INCOMPAT="$INCOMPAT gpu_mem=${GM}MiB(参考 16384,util0.90 的显存账按它算) "
case "$GN" in *T10*) say "CHK gpu = OK（与参考同款 Tesla T10）" ;; *) say "CHK gpu = 见上（非 T10，差异项已列入判定）" ;; esac
BUSY=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
say "gpu_busy_procs=$BUSY（>0 时 P2P 与起引擎都会避让/等待）"

say "=== 内存与磁盘 ==="
MT=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)
say "mem_total_G=$MT（参考 252；engram cpu_offload 需约 96G 宿主 RAM）"
[ "${MT:-0}" -ge 180 ] || { say "CHK mem = WARN（<180G，engram offload 可能挤爆）"; WARN=1; }
DF=$(df -BG --output=avail "$HERE" 2>/dev/null | tail -1 | tr -d ' G')
say "disk_free_G_at_pkg=$DF（参考机 / 445G、/data 479G；镜像约 70G＋权重 120-170G）"
[ "${DF:-0}" -ge 200 ] || { say "CHK disk = WARN（<200G）"; WARN=1; }

say "=== 网络可达性（国内优先） ==="
for U in https://hf-mirror.com https://www.modelscope.cn https://nvcr.io https://registry-1.docker.io/v2/; do
  C=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$U" 2>/dev/null)
  say "reach $U -> ${C:-000}"
done
say "内置：HF_ENDPOINT=https://hf-mirror.com、VLLM_USE_MODELSCOPE=true（国内优先，无需你配）"

say "=== P2P 用 torch 镜像 ==="
TI="${TORCH_IMG:-pytorch/pytorch:2.4.1-cuda12.4-cudnn9-runtime}"
docker image inspect "$TI" >/dev/null 2>&1 && say "torch_image=local" || say "torch_image=absent（P2P 阶段尝试拉取，失败则跳过 P2P 不阻断）"

say "=== 结论 ==="
if [ -n "$INCOMPAT" ]; then
  say "ENV_VERDICT=INCOMPAT：$INCOMPAT"
  say "（调用方会问你是否 FORCE 强制继续；FORCE 意味着自行承担起不来/性能异常的风险）"
  exit 5
fi
if [ "$WARN" = "1" ]; then say "ENV_VERDICT=WARN（可继续，先看上面 WARN 行）"; exit 0; fi
say "ENV_VERDICT=OK"
exit 0
