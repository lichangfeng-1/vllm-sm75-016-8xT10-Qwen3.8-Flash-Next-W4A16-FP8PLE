# 修订记录（CHANGELOG）

本包＝SM75 v0.1.6 代码线的自包含部署包。下列条目是每一轮 review／实机模拟发现问题后的修订，
标号（F/G/U/V/W/H/N/S/B/E/D）只是内部审计用编号，不影响使用。

## v3.6（2026-10-02）— 群友实机反馈：层 3/4 的目标路径写死

反馈形状：层 1、层 2 正常，层 3 `docker build` 挂在
`FileNotFoundError: /usr/local/lib/python3.12/dist-packages/vllm/models/qwen4_exp/nvidia/ngram_embedding.py`。
同一台机器的 P2P/NCCL 套件是先跑过的（56/56 链路全连通、单向下限 13.16 GB/s、双向 13.15、NCCL busbw 11.53），
所以问题不在 GPU 侧，在补丁层对环境的隐含假设。

- `docker/patch_ple_awq.py`：目标文件不再写死。新增 `docker/resolve_vllm_paths.py`，在镜像内问解释器要
  `vllm.__file__` 并拼出真实路径；解析失败时打印 python 版本／`sys.prefix`／`purelib`／`vllm.__file__`
  并以退出码 3 停——一次分辨"布局不同"与"基座不含 qwen4_exp"两种根因。旧报错只给一句写死路径的
  FileNotFound，使用者只能猜。读写一律显式 `encoding="utf-8"`。
- `docker/Dockerfile.incple`：顺带修掉一个**假通过**。旧写法 `COPY` 直接落到写死路径，目录不存在时
  Docker 会连目录一起造，于是基座不含 `qwen4_exp` 也能"构建成功"、产出一个没人 import 的孤儿文件
  （`py_compile` 不 import，`grep INCConfig` 查的是刚拷进去的载荷，两道断言都拦不住）。现在先解析、
  要求目标已存在（层 3 的产物必然在），再覆盖、再断言。
- `docker/build.sh` v7：层 4 复算用的 `NGRAM` 改为在镜像内解析（`resolve_ngram`），解析不到时打解释器
  实况并退出码 6；路径与基线不同时打 `NGRAM_PATH_DRIFT`（不影响校验，只是环境标注）。
- 文档：README「基座前提」补层 3/4 的额外前提，并明确包内 `code/` 是 321 文件的 overlay 树、不含
  `qwen4_exp`，故 `BOOTSTRAP=1` 那条路能否产出该目录**未验证**，确定能跑到层 3 的只有"本机已有基座"
  与"docker load 基座 tar"两条；部署文档的自验段、退出码表、故障表同步。
- 立场说明：路径解析是"让报错指向根因"，不是"适配任意环境"。参考环境仍是
  Ubuntu 24.04 + python 3.12 + dist-packages，非参考布局会打 DRIFT 行；结果可比性靠对齐，不靠兜底。
- 验证状态：`bash -n`／`py_compile` 过；解析器四条分支（目标在／目标不在／vllm 不可导入／`--allow-missing`）
  用假 vllm 包实测过。**未验**：真实基座镜像上的层 3/4 构建（需服务器开机或群友复跑）。

## v3.5（2026-10-01）— 三轮独立 review ＋ 安全审查后的修订

启动脚本 `run/start-here.sh`
- 下载值守两处"必误杀"修正：后台下载比值守更早结束时，旧版把"已经下完"当故障退出；现在先看日志里的
  `DOWNLOAD_ALL_DONE` 完成标记再判定。后台任务的命令行里没有脚本名（是 `bash -c` 展开的函数），
  旧版用脚本名去认进程永远认不出；现在认 `run_dl`／`snapshot_download` 标记。两类值守都加了总时长上限
  （下载 12 小时、编译 6 小时），到点停下报人工，不再无限死等。
- 挂载改数组传参并给 docker 参数加引号：数据目录路径含空格时，旧版会把一个挂载碎成两个残参。
- 值域与路径校验对 env 传入值同样生效：旧版只在"交互自定义配置"分支里校验，`MMBT=999`／`UTIL=0.99`
  会一路带到引擎才炸。现在 MMBT（2048/4096/8192）、util（0.50-0.95）、端口、BIND_HOST 一律校验。
- 数据目录门禁：`DATA_DIR` 会以读写方式挂进容器（容器内 root 可写），现在拒绝根目录、系统目录与家目录，
  并强制绝对路径；绑到 `0.0.0.0` 时明确提示"局域网可达、控制台能起引擎≈宿主权限"。
- `MODE=p2p` 与 `MODE=dlprobe` 不再询问模型目录（这两个模式与模型无关）；`MODE=dlprobe` 进一步提到最先早退
  （旧版要先过环境检测，在没有 GPU 的机器上想问一句"镜像站有这个仓吗"都会被驱动检查挡住）。
- `MODEL_DIR` 用 env 给定且目录里已有 `config.json` 时不再多问一句（配合 `</dev/null` 的免交互用法）。
- 分片门禁把 `model.safetensors.index.json` 解析失败单列为 `SHARD_GATE_BAD_INDEX`，不再与"缺文件"混在一起。
- 判别结果为 `unknown` 时早退并说明原因（旧版靠后面的空值防护间接拦住，报错不指向根因）。
- 待下载状态（`pending`）下编译档映射为 `incple`，不再把空值传给 build.sh。
- P2P 退出码 8（低于你设的带宽下限）改判为不通过并停下，不再只打印。
- 临时文件全部改 `mktemp`＋`umask 077`（可预测的 `/tmp/sm75-*-$$` 在多用户宿主上会被抢建或被读，
  cookie 与 token 都是凭据）；登录 token 做字符集校验后才拼进 JSON。
- `docker run` 失败时给三类常见原因的排查命令（端口被占／挂载源不存在／没有 nvidia 运行时）。
- 交互习惯：`yn` 先转小写再按前缀判方向（**先判否** `不*`/`否*`，**后判是** `是*`/`好*`/`确认*`/`ok*`，
  所以 `好的` 是、`不用了` 否；`Yes`/`NO` 大小写都认）；`ask` 去首尾全角与半角空格再走去尾斜杠。
  裁剪用显式变量的字节安全匹配，不用 `?` 通配——C/POSIX locale 下 `?` 只吃一个字节，会把全角空格劈成
  半个残字节塞进路径。
- 结尾屏显的常用命令自带"先登录拿 cookie"的完整步骤；并提醒跑过的目录含 `console-data/`（token 与 API key）
  与 `run/*.log`，不要整体 git 提交或打包外发，二次分发请重新 clone。
- 文案口径：权重体量按实测写（FP8PLE 约 120GiB／27 分片；AutoRound 约 169G），不再统一写 169G。

`tools/download-model-v3.sh`
- 两个 docker runner 补 `-i`：旧版没加，heredoc 里的 python 代码进不了容器 stdin，表现为"下载任务立刻退出"。
- 镜像 runner 补传 `local_dir` 且改用容器内挂载点 `/dst`：旧版只传 repo → `IndexError`；
  传宿主路径 → 权重落进容器可写层，`--rm` 后全丢。
- 容器内解释器固定 `python3`（宿主 python 可能叫 `python`，容器里未必有同名软链）。
- 下载前查一次磁盘余量并打印体量（余量 <140G 给提示）；`DEST` 强制绝对路径；未知参数直接报错而不是当前台跑。
- `--verify` 增加 `VERIFY_BAD_INDEX`（index 损坏）与缺片文件列表打印。

`tools/p2p-suite-run-v3.sh`
- 镜像变量改读 `TORCH_IMG`（`IMAGE` 仅作兼容别名）：`IMAGE=` 是使用者覆盖控制台镜像的公开口子，
  旧版同名会让套件"镜像不在"而跳过——跳过不等于通过，容易被误读。
- 所有判读行（`P2P_RESULT`／带宽值／早退原因）同时写进日志文件，留档能看到结论；解析时排除自己写进去的
  `P2P_` 行，避免重复解析时把上一轮结论当成本轮数据。
- `PARSE_ONLY=1` 的离线单测路径不再截断被测日志。

`run/env-check.sh` v4
- `/etc/os-release` 缺 `PRETTY_NAME` 时不再在 `set -u` 下崩；
- 本机没有"能真跑起来的 python"时，registry-mirrors 报 `?`／`none` 并说明原因，不再把"没 python"误报成"没配 mirror"。

`docker/build.sh` v5
- `BOOTSTRAP=1` 的判定移到基座预检之前：旧版预检先 `exit 4`，文档里写的"从源码现建基座"那条路永远走不到。
- 层 4 的 INCConfig 校验改成显式断言（命中数 ≥1），失败时报 rc=6 并打印实际文件路径；
  旧版只跑一条没人看结果的 grep，"补丁没进镜像"与"文件不存在"都只表现为构建失败。
- NVAPI 缺失的提示改为"该文件随仓附在 `docker/`，重新 clone 或按 `SHA256SUMS.txt` 校验取回"（旧文案写"公开仓不附文件"，已过期）。
`build.sh` v6（第二轮之后）：`SKIP_NVAPI=1` 才让"不随仓带 NVIDIA 那个专有库也能建镜像"真的可执行——
v5 里层 2 是硬必需（缺文件即 `exit 4`），而 `NOTICE` 写着"删掉也行"，承诺与代码不一致。
跳过时层 1 产物直接打标签给 `$OUT`、层 3/4 照常，并打印改 `power.mode` 的现成 sed 命令。
- 产物清单补层 4 标签；`BUILD_DONE` 标记移到所有产物打印之后（调用方以它为完成标记）。

## v3.5 的第二轮三条线隔离审查补丁（同日，未单独发版号）
第二轮又派三个隔离子会话分别过逻辑、安全/供应链、文档一致性，找出并修掉：
1. **阻断**：`tools/download-model-v3.sh --bg` 把下载代码放在**变量**里，而后台子进程只继承
   `declare -f` 展开的**函数** → heredoc 展开成空串，python 收到空程序秒退且 rc=0，日志只留
   `DOWNLOAD_FAILED`，**下载从未发生**。改成功能 `dl_code` 用管道喂 stdin，并补了"后台到底收到代码没有"的回归测试。
2. 登录/建档/启动/开扩展四处只看响应体里有没有 `"error"`、不看 HTTP 码：curl 连不上或被吞成 404 时
   空响应被当成功，一路走到 15 分钟健康等待才失败。现在统一走 `api_post`，非 2xx 立刻停并回显服务端原因。
3. 中途一版把 `rm -f "$TOKF"` 放在登录 POST 之前，等于拿已删除的 `--data` 文件发请求（必失败）。
4. `trap … EXIT INT TERM` 的 INT/TERM 只清文件不 `exit`，Ctrl-C 后编排继续跑；现在中断真的退出（130/143）。
5. 值守顺序：pid 可能早已退出并被复用（编译值守数小时后是常态），现在**先认 `DOWNLOAD_ALL_DONE`**
   再看 pid，不会把已成功的下载当故障杀。
6. `SERVED_NAME` 与交互输入的优先级反了：env 一给就静默丢掉你输入的值，而"采用配置"打印的正是被丢的那个。
7. 给了 `IMAGE=` 时脚本仍去编内置标签，编完报"镜像不在"；现在直接停下并说明产物标签要用 `OUT*_TAG`。
8. `MODE=detect`／`p2p` 也可能被默认值带走 120GiB 下载 → 下载问句现在只属于 `MODE=full`；
   `MODE=p2p` 不再被 128G 硬件门槛拦（只测连通不需要），`MODE` 取值本身加了校验。
9. 路径门禁补强：`DATA` 先 `readlink -f` 再判前缀（软链绕过已堵）；`DATA`/`CACHE_SRC`/`MODEL_DIR`
   禁逗号与等号（`--mount type=bind,source=…,target=…` 是逗号分隔键值串，实测能注入额外键）；
   容器内凭据路径 `cat "$TOKFILE"` 加引号。
10. 结尾"常用命令"以前教人把 token 写进 curl 命令行（`ps` 与 shell 历史都会留下），与本包文档自己的
    口径冲突；改成"token 走文件、curl 细节看部署文档第 4 节"。
11. `env-check` 会无条件清空使用者给的 `PYBIN`（另外三个脚本都尊重它），现在尊重、跑不动才回落自动探测。
12. P2P 套件在 `PARSE_ONLY=1` 离线单测时仍会把结论追加进被测日志，现在只读不写；套件目录改**只读挂载**
    （套件脚本不写文件，grep 证实——容器以 root 跑，可写挂载等于让一次体检有能力改宿主脚本）。
13. 默认值不变的前提下新增的口子：`FORCE=1`（免交互强继续）、`SKIP_NVAPI=1`（不装 NVIDIA 库也能建镜像，
    P-State 不可用、`power.mode` 须 `sleep`）、`--verify-sha`（按站点 LFS oid 逐片比权重 sha256）、
    `REVISION=` / `HF_VERSION=`（钉仓库修订与依赖版本）。**注意**：权重与镜像标签默认可变，
    本包不内置任何未核实的 digest/版本号；`SHA256SUMS.txt` 只保证"包内文件没被改"，不证明权重来源可信。
14. 文档一致性：基座镜像的三条来源写清（以前只写"有 tar 就 load"，而基座既不随包也没有下载点，
    外人第一步就断）；内存门槛统一成"硬门 128G／WARN 180G"（以前三处分别写 200G/128G/180G）；
    补 `start-here` 自己的退出码表、`FORCE/SKIP_NVAPI/DEST/OUT/…` 环境变量清单、
    "只在 Linux 宿主跑"与"zip 分发不保证 LF"两条，以及层 4 两道校验（Dockerfile 内 =1 且 953 行、
    build.sh 再断言 ≥1）的准确表述。
15. 修自己修出来的两个新坑（写在这里是因为"修完即对"不算修完，必须回归）：
    - `api_post` 一度被写成 `if ! X=$(api_post ...)`——命令替换把函数关进子 shell，`API_HTTP`/`API_BODY`
      全丢，失败原因变成空的；改成直接调用、状态走全局变量。
    - 宿主 runner 选完没 `return`，"宿主有 huggingface_hub"时也会再掉进 docker 兜底分支＝**一次调用下两回**；
      顺带把 `env` 命令换成脚本级 `export HF_ENDPOINT`（本机实测 Git Bash 的 `env` 会吞掉管道里的 stdin）。
16. 回归手段（服务器关机，全在本地做）：假 `docker`/`nvidia-smi`/`curl` 把 `MODE=full` 主干跑到
    `START_HERE_DONE`（rc=0），并把建档端点改成 503 验"非 2xx 立刻停"（rc=2、临时文件清理干净）；
    假 python 跑 `--bg` 验后台真的收到下载代码（`FAKEPY_GOT_LINES=9`）。
    **教训**：`api_post` 这类"用全局变量回传"的函数，只能直接调用，绝不能放进 `$( )`。
17. 第三轮验证又收掉几处（同版内）：`CROOT`/`MNT_MODEL` 也过路径门禁（它们是 `--mount …,target=` 的后半，
    逗号/等号同样能注键）；`CACHE_SRC` 与 `DATA` 一样做符号链接解析＋系统目录黑名单（它也是 rw 挂载）；
    凭据目录 `mkdir` 后显式 `chmod 700`（旧版在 `umask 077` 之前建，以 0755 出生）；`trap` 先装再建临时文件
    （旧顺序下中途 `die` 会把带 token 的文件留在 /tmp）；硬件门槛不再 fail-open（探不到数值时旧写法
    `[ "" -lt N ]` 报错即判假＝静默放行），且 `FORCE=1` 对它同样生效；`--verify-sha` 不许"空洞通过"
    （站点没给可比清单、或清单与本地 index 分片集合不一致 → rc=5）；P2P 下限判定改成 `awk` 数值化比较，
    避免 `emit` 失败时漏置失败位。
17. 第三轮验证又收掉几处（同版内）：`CROOT`/`MNT_MODEL` 也过路径门禁（它们是 `--mount …,target=` 的后半，
    逗号/等号同样能注键）；`CACHE_SRC` 与 `DATA` 一样做符号链接解析＋系统目录黑名单（它也是 rw 挂载）；
    凭据目录 `mkdir` 后显式 `chmod 700`（旧版在 `umask 077` 之前建，以 0755 出生）；`trap` 先装再建临时文件
    （旧顺序下中途 `die` 会把带 token 的文件留在 /tmp）；硬件门槛不再 fail-open（探不到数值时旧写法
    `[ "" -lt N ]` 报错即判假＝静默放行），且 `FORCE=1` 对它同样生效；`--verify-sha` 不许"空洞通过"
    （站点没给可比清单、或清单与本地 index 分片集合不一致 → rc=5）；P2P 下限判定改成 `awk` 数值化比较，
    避免 `emit` 失败时漏置失败位。

## 同日第三轮之后的补充（仍算 v3.5，未另发版号）
- `docker/build.sh` S6：清掉多轮补丁叠加出来的死分支与重复提示——`elif SKIP_NVAPI` 那一支永远不会执行，
  "不想带这个文件也可以"打印了两遍，末尾还留着与 `SKIP_NVAPI` 矛盾的"层 2 需自行注释掉"。
  现在互斥三分支，并把改 `power.mode` 的 sed 命令直接打印出来。
- 文档补齐：NVAPI 说明新增 `SKIP_NVAPI` 一节（含"只改模板不够，已建好的档要重 POST 或在控制台改一次"）；
  部署文档新增"凭据丢失与恢复"一节（`auth-cli.mjs show|reset|recover`，并写明 `recover` 会清除账户与
  允许网段限制、三个子命令都不动引擎 API key）；验收清单补可选的 `--verify-sha` 一条；
  README 里"不含任何机器专属路径"改成准确表述（脚本与模板不含；文档里的实测出处另说）。


## v3.4（2026-10-01）— 交互习惯（U1-U4）
中文是/否/好/确认与 y/n 都认；输入路径自动去全角空格与结尾斜杠；`python3` 存在但跑不动（商店别名）不算可用。

## v3.3（2026-10-01）— 服务器模拟实证（F14-F15）
`MODE=p2p` 恢复早退（旧版 P2P 跑完会继续走全流程并误起容器）；登录与建档/启动/测试开关改走
`/console-api/*` 前缀（这一代镜像的主服务把 `/api/*` 全部委派给 harness bridge，未登录一律 401/503）。

## v3.2（2026-10-01）— 二轮 review（F1-F13、D1-D4、G1-G3、B1-B2、E1-E3）
建档 python 缺 `import os`（实测 NameError）；探针地址随 `BIND_HOST`；`CROOT` 真正接进容器 env 与挂载目标；
判别空值防护；同名已停容器给可操作提示（rename 而不是删）；"P2P 跳过"与"通过"严格区分；编译错误 grep 收紧；
下载 pid 新鲜度校验；模板字段缺失给可操作报错；`ask` 去 `eval`；`CACHE_SRC` 挂到真实 cacheRoot；
建档失败回显服务端原因；`MODE=p2p` 不再偷起编译。
下载器 v2：后台任务接 `</dev/null`（否则偷走交互提示的 stdin）；`DEST` 不再拼进 `bash -c` 字符串（注入面）；
`resume_download` 按函数签名探测（新版 huggingface_hub 已移除该参数）；兜底 runner 改候选链。
P2P 运行器 v2：套件目录路径指错；带宽行右对齐使正则永不命中（最小值恒 0.00，一旦设下限就恒报失败）；
busbw 抓错列。build v3：层 1 不再写死某台机器上的本地标签，改 `ARG BASE` 并预检；基座缺失时给两条明路。
env-check v3：daemon.json 解析改"真能跑才认"的 python 探测；curl 失败双行输出修正；新增 nvidia-container-toolkit 缺失判定。

## v3 / v2 / v1.1
v3 加入 1Panel 式交互（所有可选项给默认值，回车即采用）、模型后台下载编排、P2P 七件套套件；
v2 是首条全流程脚本；v1.1 为首个可跑版本。历史脚本在包内 `lineage/` 目录留档。
