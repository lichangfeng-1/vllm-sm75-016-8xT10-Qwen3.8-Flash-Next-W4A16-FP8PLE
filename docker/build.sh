#!/usr/bin/env bash
# BUILD v6（2026-10-01 第二轮隔离审查修订 S5：SKIP_NVAPI=1 才让"不带 NVIDIA 专有库也能建"真的可执行
#   （v5 里层 2 是硬必需，NOTICE 却写着"删掉它也行"——承诺与代码不一致）；跳过时层 2 不建、
#   $OUT 直接指向层 1 产物，层 3/4 照常，档模板须把 power.mode 改 sleep）
# BUILD v5（2026-10-01 三轮隔离审查修订 S1-S4，清单见 CHANGELOG.md）
#   S1 BOOTSTRAP 块在基座预检之后 → 基座不在时先 exit 4，BOOTSTRAP=1 那条路永远走不到（文档却写着可用）；
#      现在 BOOTSTRAP 判定提前，只有"非 bootstrap 且基座不在"才停；
#   S2 层 4 的 INCConfig 校验只是跑一条 grep，结果没人看（set -e 下 rc≠0 会中断，但 0 命中与文件不存在都只表现为
#      构建失败，报错不指向根因）；v5 显式取计数并断言 >=1，失败时打印实际文件路径；
#   S3 NVAPI 缺失的提示文案过期：libnvidia-api.so.1 现在**随仓附在 docker/**，不再"公开仓不附文件"；
#   S4 产物打印补层 4 标签，且 BUILD_DONE 移到全部产物之后（调用方 grep BUILD_DONE 当完成标记，别在它之前 exit）。
# v4（2026-10-01：层2 缺 libnvidia-api.so.1 时预检并打印获取方法，退出码 4）
# v3（2026-10-01 二轮 review 修订 B1-B2）
#   B1 旧版层1 写死 FROM vllm-sm75-next-ultra-0924:latest —— 那是某台机器上的本地标签，新服务器上不存在；
#      现改 ARG BASE 并在开建前预检；
#   B2 基座缺失时给两条明路：docker load 基座 tar（包外自带），或 BOOTSTRAP=1 用包内 code/ 源码
#      走官方链（standard → ultra）现建基座；bootstrap 路径**未在本包验证**（本机基座是既有镜像），只作可选。
# 补丁层：1 控制台超时 → 2 NVAPI 库 → 3 PLE/AWQ →（可选）4 PLE 的 auto-round/INC 分支
# 另有 docker/Dockerfile.monitorfix（控制台 VLLM_MONITOR 强制开启的一层），本脚本不建，按需手动建。
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd -- "$HERE/.." && pwd)"
CODE="$PKG/code/VLLM-SM75-main0.16"
BASE_IMG="${BASE_IMG:-vllm-sm75-next-ultra-0924:latest}"
MID="${MID_TAG:-vllm-sm75-next-ultra-0924:console-patched}"
OUT="${OUT_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi}"
OUT2="${OUT2_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple}"
OUT3="${OUT3_TAG:-vllm-sm75-next-ultra-0924:patched-nvapi-awqple-incple}"
CFG="${1:-all}"
NGRAM=/usr/local/lib/python3.12/dist-packages/vllm/models/qwen4_exp/nvidia/ngram_embedding.py
NVAPI_SHA=4a199f9b259a1098ab9c01d31c67f882a2531a0fbb9c3595ad3d016c7d131d8c

# S1：先决定基座从哪来，再预检
if [ "${BOOTSTRAP:-0}" = "1" ]; then
  echo "=== 基座 bootstrap：官方源码链（standard → ultra），耗时以小时计（本路径未在本包验证过） ==="
  [ -d "$CODE/docker" ] || { echo "!! 缺源码树 $CODE/docker（BOOTSTRAP=1 需要包内 code/ 完整）"; exit 4; }
  ( cd "$CODE" && bash docker/build.sh )
  ( cd "$CODE" && EDITION=ultra bash docker/build.sh )
  V="$(tr -d ' \r\n' < "$CODE/docker/VERSION")"
  BASE_IMG="vllm-sm75:v${V}-ultra"
  echo "BOOTSTRAP_DONE base=$BASE_IMG"
fi

if ! docker image inspect "$BASE_IMG" >/dev/null 2>&1; then
  echo "!! 基座镜像不在: $BASE_IMG（build.sh 退出码 4 也可能是缺 NVAPI 库或缺 code/ 源码树）"
  echo "   本包的补丁层都建在 SM75 v0.1.6 ultra 基座之上，基座不随包（约 70G，无法内置）。两条路："
  echo "   1) 有基座 tar：docker load -i <基座>.tar 后把它的标签改成 $BASE_IMG（或 BASE_IMG=<你的标签> 重跑）"
  echo "   2) 从源码现建：BOOTSTRAP=1 bash build.sh $CFG  （走 code/ 官方链 standard→ultra，需外网与数小时）"
  exit 4
fi
echo "BASE_IMG=$BASE_IMG  CFG=$CFG"

if [ "${SKIP_NVAPI:-0}" = "1" ]; then
  echo "!! SKIP_NVAPI=1：跳过层 2（不把 libnvidia-api.so.1 装进镜像）"
  echo "   后果：控制台的 P-State 电源管理不可用——三套档模板 run/profiles/*.json 的 power.mode 都写死"
  echo "         pstate，请改成 sleep（或建档后在控制台里改），否则点启动会被控制台侧的 P-State 校验拦下；"
  echo "         推理本身与其余补丁层不受影响。$OUT 由层 1 产物打标签得来，层 3 直接建在它上面。"
elif [ ! -f "$HERE/libnvidia-api.so.1" ]; then
  echo "!! 缺 docker/libnvidia-api.so.1（层 2 与 P-State 电源管理必需）"
  echo "   不想带这个文件也可以：SKIP_NVAPI=1 bash build.sh $CFG（降级语义见 docker/NVAPI-获取说明-v1.md）"
  echo "   该文件随仓附在 docker/ 里：重新 clone 或按 SHA256SUMS.txt 校验后取回即可（sha256 须＝$NVAPI_SHA）"
  echo "   拿不到仓内文件时的替代路见 docker/NVAPI-获取说明-v1.md（从同族镜像提取一条命令）"
  echo "   降级路：档模板 power.mode 改 sleep（等价不管电源），层 2 需自行注释掉"
  exit 4
fi

echo "=== 层 1：控制台超时补丁 ==="
docker build --build-arg BASE="$BASE_IMG" -f "$HERE/Dockerfile.console-patched" -t "$MID" "$HERE"
if [ "${SKIP_NVAPI:-0}" = "1" ]; then
  echo "=== 层 2：跳过（SKIP_NVAPI=1）——$OUT 指向层 1 产物 ==="
  docker tag "$MID" "$OUT"
  echo "NVAPI_SKIPPED out=$OUT"
else
  echo "=== 层 2：NVAPI 库（Dockerfile 内有 sha256sum -c 门禁） ==="
  docker build --build-arg BASE="$MID" -f "$HERE/Dockerfile.nvapi" -t "$OUT" "$HERE"
fi
echo "=== 层 3：PLE/AWQ 补丁（patch_ple_awq.py） ==="
docker build --build-arg BASE="$OUT" -f "$HERE/Dockerfile.awqple" -t "$OUT2" "$HERE"

if [ "$CFG" = "all" ] || [ "$CFG" = "incple" ]; then
  echo "=== 层 4：PLE 的 auto-round/INC 分支 —— Intel AutoRound W4A16 权重必需 ==="
  docker build --build-arg BASE="$OUT2" -f "$HERE/Dockerfile.incple" -t "$OUT3" "$HERE"
  # S2：显式断言补丁真的进了镜像（计数>=1），不再让一条没人看结果的 grep 充当校验
  CNT="$(docker run --rm --entrypoint grep "$OUT3" -c INCConfig "$NGRAM" || true)"
  case "${CNT:-0}" in
    ''|0) echo "!! 层 4 校验失败：$NGRAM 里没有 INCConfig（cnt='${CNT:-0}'）——补丁没进镜像，别当构建成功"
          docker run --rm --entrypoint ls "$OUT3" -l "$NGRAM" || true
          exit 6 ;;
  esac
  echo "INCPLE_ASSERT_OK cnt=$CNT image=$OUT3"
fi

echo "=== 产物 ==="
docker image inspect "$MID"  --format "MID={{.Id}}"
docker image inspect "$OUT"  --format "OUT={{.Id}}"
docker image inspect "$OUT2" --format "OUT2={{.Id}}"
if [ "$CFG" = "all" ] || [ "$CFG" = "incple" ]; then
  docker image inspect "$OUT3" --format "OUT3={{.Id}}"
fi
echo "BUILD_DONE base=$BASE_IMG cfg=$CFG"
