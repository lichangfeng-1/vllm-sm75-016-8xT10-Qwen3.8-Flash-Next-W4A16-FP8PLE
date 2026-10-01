# SM75 v0.1.6 自包含部署包（README · 2026-10-01 · 入口脚本 v3.2）

**一句话**：把本文件夹拷到一台 8×T10（SM75）服务器的任意目录，跑一条命令，得到一个带 Web 控制台、
能自动识别模型量化类型、并默认开好"模型测试"两个功能的 vLLM 推理服务。

**基线**：SM75 v0.1.6 原始代码线（基座 `vllm/vllm-openai:v0.30.0-cu129`，build commit `ced6857a…`）。
包内**不含任何机器专属路径**；适配一律走环境变量覆盖，不改脚本。

## 先决条件（不满足会在对应步骤停下并告诉你怎么办）
1. **基座镜像**：四层补丁建在 SM75 v0.1.6 ultra 基座之上（约 70G，不随包）。
   有 tar 就 `docker load` 后打标签 `vllm-sm75-next-ultra-0924:latest`；没有就 `BOOTSTRAP=1` 用包内 `code/`
   走官方链现建（需外网、小时级，**该路径未在本包验证**）。
2. **硬件验证配置**：总显存 ≥128G 且宿主内存 ≥128G（G292-Z20 8×T10 16G＋252G 实测跑通；
   engram n-gram 表单独占约 95-96G 宿主内存）。低于会问你是否强制继续。
3. **环境检测三档**：OK/WARN 可继续；INCOMPAT（驱动<570、卡数≠8、sm≠7.5、单卡≠16384MiB、
   缺 nvidia-container-toolkit）停下问 FORCE；硬缺（docker 守护进程/nvidia-smi/curl）直接退。
4. 模型卡上的小卡 offload 标签（rtx-3090/single-gpu/24gb-vram 等）属**另一个推理栈**的宣传，本包不支持也不验证。

## 包里有什么
| 路径 | 内容 |
|---|---|
| `code/VLLM-SM75-main0.16/` | v0.1.6 源码树（含官方 docker/ultra 构建链，供 BOOTSTRAP） |
| `docker/` | 四层镜像构建（console-patched → nvapi → awqple → incple）＋两版 PLE 补丁＋控制台超时补丁＋`libnvidia-api.so.1`（sha `4a199f9b…1d8c`，与驱动 580.173.02 配套）＋`NVAPI-获取说明-v1.md`（换驱动/缺件时的重新获取与降级路） |
| `run/start-here.sh` | **现行入口 v3.2**：环境检测 → 1Panel 式交互 → 模型后台下载编排 → 判别 → 后台编译＋并行 P2P → 值守 → 起容器 → 建档启动 → 开测速两功能 → 打印凭据 |
| `run/env-check.sh` | 只读环境检测 v3（参考环境内置、国内优先、三档判定） |
| `run/profiles/*.json` | 三套档模板：auto-round(incple)／compressed-tensors(awq)／无量化(base) |
| `tools/p2p-suite-run-v2.sh` | P2P/NCCL 七件套非交互运行器＋机器可读判读（退出码 0/3/6/7/8/9） |
| `tools/g292z20-nccl-tests/` | 七件套本体（可达矩阵/NCCL allreduce/1GiB 单双向/多流/诊断） |
| `tools/download-model-v2.sh` | 模型下载器（hf-mirror 默认、后台＋续传＋分片自验、`--verify` 单测口） |
| `lineage/` | 历代入口与检测脚本留档（仅工作目录有，发版件不含） |
| `tools/*-v1.sh`（若随包） | **留档勿用**：v1 运行器/下载器有实证 bug（清单见发版说明），现行一律 v2 |
| `部署文档-v1.md`、`基线与口径说明-v1.md` | 逐步部署/手动等价命令/验收清单/故障表/回滚；基线三要素与口径红线 |
| `SHA256SUMS.txt` | 全包校验（Linux 下 `sha256sum -c` rc=0；`run/*.log` 为运行产物不入清单） |

## 三步上手
```bash
cd <包>/run
bash start-here.sh            # 交互；所有可选项给【默认值】，回车即采用
# 免交互/单步：export MODEL_DIR=/绝对/路径；MODE=env|detect|p2p|dlprobe|full
# 结束后按屏幕提示，把 控制台token 与 引擎APIkey 抄走备份（容器内 /console-data/key 与 engine-key.current）
```
没有模型时脚本会问"要不要后台下载推荐模型 `albucino/Qwen3.8-Flash-Next-W4A16-FP8PLE`"（约 116GiB、25 分片、
非 gated 无需 token、国内走 hf-mirror.com）；要就 nohup 起下载、前台继续，起引擎前值守下完并重跑分片门禁。

## 模型配置判别（离线单测六例＋控制台 validateProfile 三模板全过）
| `config.json` 的 `quantization_config.quant_method` | 选用 | 镜像 |
|---|---|---|
| `auto-round`（或 `packing_format=auto_round:*`） | incple 档 | `…:patched-nvapi-awqple-incple` |
| `compressed-tensors` / `awq` / `gptq` | awq 档 | `…:patched-nvapi-awqple` |
| 无量化配置 | base 档 | `…:patched-nvapi-awqple` |
| 其它（如 bitsandbytes） | **停下，人工确认** | — |

分片门禁只拦"index 里有张量映射但盘上缺文件"；**index 零映射的编号空位（如 AutoRound 官方包的
`model-00002-of-00017`）不算缺件，放行**——实测过的上游打包形态。

## 可覆盖项（都不用改脚本）
`MODEL_DIR DATA_DIR CACHE_SRC NAME CONSOLE_PORT ENGINE_PORT IMAGE SERVED_NAME MMBT UTIL
REQ_VRAM_G REQ_RAM_G BIND_HOST PROBE_HOST SHM_SIZE MNT_MODEL SM75_CONSOLE_ROOT BASE_IMG BOOTSTRAP
REC_REPO HF_ENDPOINT HF_RUNNER_IMG TORCH_IMG P2P_FLOOR_GBPS NCCL_FLOOR_GBPS NCCL_DEBUG PYBIN`
- `CACHE_SRC` 挂到容器内 `$SM75_CONSOLE_ROOT/cache`（单容器 native 形态下这才是真生效的编译缓存根）。
- `--served-model-name` 在 vLLM 0.30 是多值参数：模板里主名后还带一个 `Flash-Next-AWQ` **别名**，
  `/v1/models` 会列两个名字；不想要别名就删模板 `args` 里那一项。
- 档内其余参数建好后在控制台改（运行中改档会被拒，先停止）。

## 校验
```bash
cd <包> && sha256sum -c SHA256SUMS.txt     # 应全 OK、rc=0
```

## 红线与已知边界（详情见 部署文档-v1.md）
- 选择题／loglikelihood 类评测（prompt_logprobs）**会打死引擎**，本包路线只用 humaneval＋gsm8k。
- 吞吐数字带工况：功耗窗与 persistence 状态每次开测前先查 `nvidia-smi -q -d POWER`。
- LiveCodeBench 在"思考常开×固定小 max_tokens"端点**不可比**；公开卡片分数只作外部参考值。
- incple 档模板 `--max-num-batched-tokens=2048` 已在 AutoRound 权重上验证可用（2026-10-01 全流程跑通）；
  实测口径（用户 2026-10-01）：2048 时预填充峰值吞吐约 3000 t/s，改 4096 升到 3200+ t/s，
  但更大的预填充批次有出问题的风险——默认保持 2048 安全基线，追求 prefill 速度可 MMBT=4096。
- 从控制台镜像派生的新镜像**继承 node entrypoint**：要直接 `docker run <镜像> vllm serve …` 必须加
  `--entrypoint /usr/local/bin/vllm`，否则起的是第二个控制台。
- 本脚本**不删除任何容器**：同名在跑或同名已停都会停下让你自行 stop/rename。
