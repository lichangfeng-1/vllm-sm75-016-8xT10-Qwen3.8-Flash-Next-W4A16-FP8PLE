# SM75 v0.1.6 自包含部署包（README · 2026-10-02 · 入口脚本 v3.5 ＋ 补丁构建 v7，包 v3.6）

**一句话**：把本文件夹拷到一台 8×T10（SM75）服务器的任意目录，跑一条命令，得到一个带 Web 控制台、
能自动识别模型量化类型、并默认开好"模型测试"两个功能的 vLLM 推理服务。

**基线**：SM75 v0.1.6 原始代码线（基座 `vllm/vllm-openai:v0.30.0-cu129`，build commit `ced6857a…`）。
脚本与配置模板里**不含任何机器专属路径**——适配一律走环境变量覆盖，不改脚本；
文档中出现的机器型号与日期是实测证据的出处标注（不是脚本依赖，也不是要你照抄的路径）。

## 先决条件（不满足会在对应步骤停下并告诉你怎么办）
1. **基座镜像（第一步就会撞上，先看清楚）**：补丁层建在 SM75 v0.1.6 **ultra** 基座之上（约 70G，
   **本包不含、也不提供下载点**）。三条路：
   ① 本机已有该镜像或同族标签 → `BASE_IMG=<标签> bash docker/build.sh <cfg>`，或直接
      `IMAGE=<标签>` 让 start-here 用它（给了 `IMAGE` 时脚本**不代编译**，见"可覆盖项"）；
   ② 有基座 tar → `docker load -i <基座>.tar`，再打标签 `vllm-sm75-next-ultra-0924:latest`；
   ③ 用包内 `code/VLLM-SM75-main0.16/` 现建 → `BOOTSTRAP=1 bash docker/build.sh <cfg>`
      （走上游官方链 standard→ultra，需外网、小时级；**本包未实机验证过这条路**）。
   上游版本与构建说明见 `code/VLLM-SM75-main0.16/README.md` 与 `code/VLLM-SM75-main0.16/docs/releases/v0.1.6.md`。
   **层 3/层 4 的额外前提**：这两层动的是基座内的 `vllm/models/qwen4_exp/nvidia/ngram_embedding.py`。
   基座里没有该文件时，层 3 会以 `PLE_AWQ_RESOLVE_FAIL` 停下并打印解释器诊断（v3.6 起，退出码 3）——
   那是基座不对，不是补丁坏了。包内 `code/` 是 321 个文件的 overlay 树、**不含** `qwen4_exp`，
   所以路③能否产出该目录本包未验证；**确定能跑到层 3 的只有路① 和路②**。
2. **硬件验证配置**：总显存 ≥128G 且宿主内存 ≥128G（硬门槛 `REQ_VRAM_G`/`REQ_RAM_G`；
   `env-check.sh` 另有内存 <180G 的 WARN 档——engram cpu_offload 实测占约 96G，128G 能跑但没余量）（G292-Z20 8×T10 16G＋252G 实测跑通；
   engram n-gram 表单独占约 95-96G 宿主内存）。低于会问你是否强制继续。
3. **环境检测三档**：OK/WARN 可继续；INCOMPAT（驱动<570、卡数≠8、sm≠7.5、单卡≠16384MiB、
   缺 nvidia-container-toolkit）停下问 FORCE；硬缺（docker 守护进程/nvidia-smi/curl）直接退。
4. 模型卡上的小卡 offload 标签（rtx-3090/single-gpu/24gb-vram 等）属**另一个推理栈**的宣传，本包不支持也不验证。

## 包里有什么
| 路径 | 内容 |
|---|---|
| `code/VLLM-SM75-main0.16/` | v0.1.6 源码树（含官方 docker/ultra 构建链，供 BOOTSTRAP） |
| `docker/` | 补丁层构建（层1 console-patched → 层2 nvapi → 层3 awqple → 层4 incple，层4 可选）＋层3 的 `patch_ple_awq.py`（构建时对 `ngram_embedding.py` 打补丁）＋层4 的整文件替换件 `ngram_embedding.incple-1938b4aa.py`＋`libnvidia-api.so.1`（sha `4a199f9b…1d8c`，与驱动 580.173.02 配套）＋`NVAPI-获取说明-v1.md`（换驱动/缺件时的重新获取与降级路）；另有 `Dockerfile.monitorfix`（控制台监控开关的一层，默认不建，见 CHANGELOG） |
| `run/start-here.sh` | **现行入口 v3.5**：环境检测 → 1Panel 式交互 → 模型后台下载编排 → 判别 → 后台编译＋并行 P2P → 值守 → 起容器 → 建档启动 → 开测速两功能 → 打印凭据 |
| `run/env-check.sh` | 只读环境检测 v4（参考环境内置、国内优先、三档判定） |
| `run/profiles/*.json` | 三套档模板：auto-round(incple)／compressed-tensors(awq)／无量化(base) |
| `tools/p2p-suite-run-v3.sh` | P2P/NCCL 七件套非交互运行器＋机器可读判读（退出码 0/3/6/7/8/9；判读同时落进日志） |
| `tools/g292z20-nccl-tests/` | 七件套本体（可达矩阵/NCCL allreduce/1GiB 单双向/多流/诊断） |
| `tools/download-model-v3.sh` | 模型下载器（hf-mirror 默认、后台＋续传＋分片自验、`--probe`/`--verify` 单测口） |
| `CHANGELOG.md` | 历代修订清单（v1.1 → v3.5，每轮 review／实机模拟发现的问题与修法） |
| `LICENSE`／`NOTICE` | Apache-2.0；NOTICE 说明随附源码树与 `libnvidia-api.so.1`（NVIDIA 驱动组件，另受其自身条款）的出处 |
| `.gitattributes` | 强制 LF／二进制不转换——Windows 上 clone 后 `sha256sum -c` 才会不飘红 |
| `Dockerfile.monitorfix` | 额外一层：控制台强制 `VLLM_MONITOR=1` 的开关补丁；`build.sh` **不建它**，需要时手动 build（见 CHANGELOG"不在发布范围内的东西"） |
| 历代脚本与过程件 | **不在本仓**：v1/v2 的下载器与 P2P 运行器带实证 bug（v1 还把输入拼进 `bash -c` 字符串），只在工作目录留档。仓里只有当前号，要历史翻 git 提交 |
| `部署文档-v1.md`、`基线与口径说明-v1.md` | 逐步部署/手动等价命令/验收清单/故障表/回滚；基线三要素与口径红线 |
| `SHA256SUMS.txt` | 全包校验（Linux 下 `sha256sum -c` rc=0；`run/*.log` 为运行产物不入清单） |

## 三步上手
```bash
cd <包>/run
bash start-here.sh            # 交互；所有可选项给【默认值】，回车即采用
# 单步：MODE=env|detect|p2p|dlprobe|full（默认 full）
# 免交互（无人值守）：把要用的值都用 env 给出，并把 stdin 关掉，每个问句自动取默认值
#   export MODEL_DIR=/绝对/路径/模型目录     # 免交互必给；不给且没模型时会走"下载"默认值
#   export MMBT=4096 UTIL=0.90 DATA_DIR=/data/vllm-console
#   MODE=full bash start-here.sh < /dev/null
# 结束后按屏幕提示，把 控制台token 与 引擎APIkey 抄走备份（容器内 /console-data/key 与 engine-key.current）
# 跑过的目录含 console-data/（凭据）与 run/*.log：不要整体 git 提交或打包外发（.gitignore 已挡住这些）
```
没有模型时脚本会问"要不要后台下载推荐模型 `albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE`"（约 120GiB、27 分片、
非 gated 无需 token、国内走 hf-mirror.com）；要就 nohup 起下载、前台继续，起引擎前值守下完并重跑分片门禁。

## 模型配置判别（离线单测六例＋控制台 validateProfile 三模板全过）
| `config.json` 的 `quantization_config.quant_method` | 选用 | 镜像 |
|---|---|---|
| `auto-round`（或 `packing_format=auto_round:*`） | incple 档 | `…:patched-nvapi-awqple-incple` |
| `compressed-tensors` / `awq` / `gptq` | awq 档 | `…:patched-nvapi-awqple` |
| 无量化配置 | base 档 | `…:patched-nvapi-awqple` |
| `config.json` 还读不到（正在下载） | **pending**：先按 incple 备镜像，下载完成后重新判别再定档 | 先 `…-incple`，复核后按实际 |
| 其它（如 bitsandbytes） | **停下，人工确认** | — |

分片门禁只拦"index 里有张量映射但盘上缺文件"；**index 零映射的编号空位（如 AutoRound 官方包的
`model-00002-of-00017`）不算缺件，放行**——实测过的上游打包形态。

## 可覆盖项（都不用改脚本）
`MODEL_DIR DATA_DIR CACHE_SRC NAME CONSOLE_PORT ENGINE_PORT IMAGE SERVED_NAME MMBT UTIL REQ_VRAM_G REQ_RAM_G
BIND_HOST PROBE_HOST SHM_SIZE MNT_MODEL SM75_CONSOLE_ROOT PYBIN FORCE`
- 编译侧：`BASE_IMG BOOTSTRAP SKIP_NVAPI MID_TAG OUT_TAG OUT2_TAG OUT3_TAG`
- 下载侧：`REC_REPO REPO DEST HF_ENDPOINT HF_RUNNER_IMG PYIN_IMG REVISION HF_VERSION`
- P2P 侧：`TORCH_IMG SUITE OUT PARSE_ONLY P2P_FLOOR_GBPS NCCL_FLOOR_GBPS NCCL_DEBUG`
- `FORCE=1`：环境判定 INCOMPAT 时免交互强继续（无人值守要用它；问句默认方向是"不继续"）。
- `SKIP_NVAPI=1`：层 2 不装 `libnvidia-api.so.1`（该文件是 NVIDIA 驱动组件），代价是 P-State 电源管理不可用、
  档模板 `power.mode` 必须是 `sleep`。
- `IMAGE=` 只决定"用哪个镜像"，**不决定编译产物叫什么**：产物标签由 `BASE_IMG`/`OUT*_TAG` 控制；
  给了 `IMAGE` 而本机没这个镜像时脚本直接停下，不会替你编一个名字不对的镜像。
- 单跑下载器要显式给目录：`DEST=/绝对/模型目录 bash tools/download-model-v3.sh --verify`。
- `CACHE_SRC` 挂到容器内 `$SM75_CONSOLE_ROOT/cache`（单容器 native 形态下这才是真生效的编译缓存根）。
- `--served-model-name` 在 vLLM 0.30 是多值参数：模板里主名后还带一个 `Flash-Next-AWQ` **别名**，
  `/v1/models` 会列两个名字；不想要别名就删模板 `args` 里那一项。
- 档内其余参数建好后在控制台改（运行中改档会被拒，先停止）。

## 校验与运行环境
```bash
cd <包> && sha256sum -c SHA256SUMS.txt            # 应全 OK、rc=0
bash tools/download-model-v3.sh --verify-sha      # 可选：按站点 LFS oid 逐片比权重 sha256（要读完 120GiB）
```
- **脚本只能在 Linux 宿主上跑**（依赖 `/proc/meminfo`、`df --output`、`hostname -I`、docker/nvidia-smi）；
  Windows 的 Git Bash / WSL 只适合做静态检查，不要在那里跑 `start-here.sh`。
- LF 的保证只对 `git clone` 有效（`.gitattributes`）；用 zip/网盘分发时收方先 `sha256sum -c SHA256SUMS.txt`，
  飘红说明被换行改过，改用 git 取回或先 `dos2unix`。
- **没有密码学校验的三处**：可变镜像 tag、`docker load` 进来的基座 tar（本包不带也无从给哈希）、
  slim runner 里的 `pip install -U huggingface_hub`（不钉版本、不锁 index）。要可复现就用
  digest 形式传给 `TORCH_IMG=` / `HF_RUNNER_IMG=` / `BASE_IMG=`，下载可用 `REVISION=` 钉仓库修订、
  `HF_VERSION=` 钉依赖版本。本包不内置任何 digest/版本号（未核实的数字不写进默认值）。

## 红线与已知边界（详情见 部署文档-v1.md）
- 选择题／loglikelihood 类评测（prompt_logprobs）**会打死引擎**，本包路线只用 humaneval＋gsm8k。
- 吞吐数字带工况：功耗窗与 persistence 状态每次开测前先查 `nvidia-smi -q -d POWER`。
- LiveCodeBench 在"思考常开×固定小 max_tokens"端点**不可比**；公开卡片分数只作外部参考值。
- incple 档模板 `--max-num-batched-tokens=2048` 已在 AutoRound 权重上验证可用（2026-10-01 全流程跑通）；
  实测口径（用户 2026-10-01）：2048 预填充峰值吞吐约 3000 t/s；**4096 也已验证**（前一晚数小时长程任务稳定，峰值 3200+ t/s）；
  再大（如 8192）有 OOM 风险。默认保持 2048 止血基线，追求 prefill 速度可放心用 4096。
- 从控制台镜像派生的新镜像**继承 node entrypoint**：要直接 `docker run <镜像> vllm serve …` 必须加
  `--entrypoint /usr/local/bin/vllm`，否则起的是第二个控制台。
- 本脚本**不删除任何容器**：同名在跑或同名已停都会停下让你自行 stop/rename。
