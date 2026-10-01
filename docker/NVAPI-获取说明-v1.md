# NVAPI 库说明（`libnvidia-api.so.1` · 2026-10-01 · 发版件）

## 获取：直接从本 GitHub 仓库下载
本仓**随附**该库副本：`docker/libnvidia-api.so.1`（720,104 字节）。
clone 整仓或网页下载单文件均可：
- `git clone https://github.com/lichangfeng-1/vllm-sm75-016-8xT10-Qwen3.8-Flash-Next-W4A16-FP8PLE.git` 后取 `docker/libnvidia-api.so.1`；
- 或网页进入 `docker/` 目录点该文件下载（注意：raw.githubusercontent.com 在部分网络不可达，优先前两种）。
下载后必过 sha 门禁：
```bash
sha256sum libnvidia-api.so.1
# 须等于 4a199f9b259a1098ab9c01d31c67f882a2531a0fbb9c3595ad3d016c7d131d8c
```

## 它是什么、配什么驱动
- NVIDIA 驱动配套组件，本包用于控制台的 **P-State 电源管理**（层 2 `Dockerfile.nvapi` 烘进镜像）。
- 随附副本与驱动 **580.173.02** 配套实测（sha 即门禁值）。**换驱动版本**时该库可能不同：
  优先用本仓副本试；P-State 异常再按下面"重新获取"或走降级路。

## 干脆不带这个文件（`SKIP_NVAPI=1`）
不想在本地保留这个 NVIDIA 专有二进制时，整层跳过即可（`docker/build.sh` v6 起是真开关，不需要手工注释 Dockerfile）：

```bash
SKIP_NVAPI=1 bash docker/build.sh incple
```

- 行为：层 2 不构建，层 1 产物直接打标签给 `…:patched-nvapi`，层 3/4 照常建在它上面；
- 代价：**没有该库，控制台的 P-State 电源管理校验会拒起引擎**。三套档模板里的
  `power.mode` 都写死 `pstate`，要改成 `sleep`（等价"不管电源"）：

```bash
sed -i 's/"mode": "pstate"/"mode": "sleep"/' run/profiles/*.json
```

  或者建档之后在控制台网页里改。**只改模板不够**——已经建好的档要重新 POST 或在控制台里改一次。
- 推理本身、其余补丁层、模型加载与生成都与这个库无关。
- 之后想补回来：按下面方法 A 自己取件，放进 `docker/`，正常 `bash build.sh` 即可（sha 门禁会验）。


## 文件缺失或换驱动时的重新获取
- **方法 A（已实证）**：从任何已含该库的同族镜像提取：
  ```bash
  docker run --rm --entrypoint cat <含该库的镜像> /usr/local/nvidia/lib64/libnvidia-api.so.1 \
    > libnvidia-api.so.1
  sha256sum libnvidia-api.so.1   # 过门禁才可用
  ```
- **降级路（已实证语义）**：没有该库也能跑推理——把档模板 `power.mode` 改 `sleep`
  （等价"不管电源"；validateProfile 没有"关电源"选项），其余功能不受影响。
  本包三套模板默认 `pstate`＋`gpus=0..7`；走降级路时同步改模板或建档后在控制台改。

## 红线
- 不要从不明来源下载同名文件、不过 sha 就进镜像（供应链）。
- 该库只服务 P-State；引擎本体（加载/推理/控制台）不依赖它。
