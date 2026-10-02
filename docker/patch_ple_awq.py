#!/usr/bin/env python3
"""层3补丁：让 Qwen4Exp PLE/n-gram 嵌入支持 compressed-tensors（AWQ int4）。
目标模型 cyankiwi/Qwen3.8-Flash-Next-AWQ-INT4 必需；不打则引擎启动报
NotImplementedError: Qwen4Exp PLE embedding does not support quantization config CompressedTensorsConfig
幂等：已含分支则直接退出0。契约：锚点唯一 + py_compile 通过 + 回读分支在位 → PLE_AWQ_CONTRACT_OK。
原理：该类 AWQ checkpoint 仅 Linear/expert 为 int4-packed，PLE/n-gram 表以 BF16 未量化存放，
故 CompressedTensors 配置下 PLE 应走 Unquantized 分支。
目标文件路径由 resolve_vllm_paths.py 在镜像内解析（v2，2026-10-02）：旧版写死
/usr/local/lib/python3.12/dist-packages/…，非参考布局的机器报 FileNotFoundError 且不指向根因。"""
import hashlib
import os
import py_compile
import sys

BASELINE_PREFIX = "/usr/local/lib/python3.12/dist-packages/"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from resolve_vllm_paths import diagnostics, resolve  # noqa: E402

SRC, _err = resolve()
if _err:
    print("PLE_AWQ_RESOLVE_FAIL " + _err)
    print(diagnostics())
    print("两种根因按上面分辨：vllm 可导入但文件不在＝基座不含 qwen4_exp（不是 SM75 v0.1.6 ultra 派生镜像）；"
          "vllm 不可导入＝基座不是预期镜像。这属于基座问题，不在本包的补丁范围内。")
    sys.exit(3)
if not os.path.abspath(SRC).startswith(BASELINE_PREFIX):
    print("PLE_PATH_DRIFT 实际=%s（基线 %s…；布局不同不影响补丁正确性，只说明这台机不是参考环境）" % (SRC, BASELINE_PREFIX))

with open(SRC, encoding="utf-8") as f:
    src = f.read()
if "isinstance(quant_config, CompressedTensorsConfig)" in src:
    print("PLE_AWQ_ALREADY_PATCHED")
    sys.exit(0)

IMP_ANCHOR = "from vllm.model_executor.layers.quantization.fp8 import Fp8Config\n"
IMP_ADD = ("from vllm.model_executor.layers.quantization.compressed_tensors.compressed_tensors import (\n"
           "    CompressedTensorsConfig,\n"
           ")\n")
assert src.count(IMP_ANCHOR) == 1, "import anchor not unique: %d" % src.count(IMP_ANCHOR)
src = src.replace(IMP_ANCHOR, IMP_ANCHOR + IMP_ADD, 1)

BR_ANCHOR = ("        if not isinstance(quant_config, Fp8Config):\n"
             "            raise NotImplementedError(")
BR_ADD = ("        if isinstance(quant_config, CompressedTensorsConfig):\n"
          "            # compressed-tensors (e.g. AWQ int4) checkpoints keep the PLE/n-gram\n"
          "            # table unquantized (BF16); only Linear/expert layers carry packs.\n"
          "            return Qwen4ExpPLEUnquantizedEmbeddingMethod()\n"
          "        if not isinstance(quant_config, Fp8Config):\n"
          "            raise NotImplementedError(")
assert src.count(BR_ANCHOR) == 1, "branch anchor not unique: %d" % src.count(BR_ANCHOR)
src = src.replace(BR_ANCHOR, BR_ADD, 1)

with open(SRC, "w", encoding="utf-8", newline="") as f:
    f.write(src)
py_compile.compile(SRC, doraise=True)
with open(SRC, encoding="utf-8") as f:
    s2 = f.read()
assert "isinstance(quant_config, CompressedTensorsConfig)" in s2, "branch missing after write"
print("sha256:", hashlib.sha256(s2.encode()).hexdigest())
print("PLE_AWQ_CONTRACT_OK")
