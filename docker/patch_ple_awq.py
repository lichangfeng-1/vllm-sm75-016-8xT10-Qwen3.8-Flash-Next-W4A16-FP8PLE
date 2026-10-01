#!/usr/bin/env python3
"""层3补丁：让 Qwen4Exp PLE/n-gram 嵌入支持 compressed-tensors（AWQ int4）。
目标模型 cyankiwi/Qwen3.8-Flash-Next-AWQ-INT4 必需；不打则引擎启动报
NotImplementedError: Qwen4Exp PLE embedding does not support quantization config CompressedTensorsConfig
幂等：已含分支则直接退出0。契约：锚点唯一 + py_compile 通过 + 回读分支在位 → PLE_AWQ_CONTRACT_OK。
原理：该类 AWQ checkpoint 仅 Linear/expert 为 int4-packed，PLE/n-gram 表以 BF16 未量化存放，
故 CompressedTensors 配置下 PLE 应走 Unquantized 分支。"""
import hashlib
import py_compile
import sys

SRC = "/usr/local/lib/python3.12/dist-packages/vllm/models/qwen4_exp/nvidia/ngram_embedding.py"
src = open(SRC).read()
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

open(SRC, "w").write(src)
py_compile.compile(SRC, doraise=True)
s2 = open(SRC).read()
assert "isinstance(quant_config, CompressedTensorsConfig)" in s2, "branch missing after write"
print("sha256:", hashlib.sha256(s2.encode()).hexdigest())
print("PLE_AWQ_CONTRACT_OK")
