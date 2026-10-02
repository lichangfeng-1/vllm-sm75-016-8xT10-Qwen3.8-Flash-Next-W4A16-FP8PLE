#!/usr/bin/env python3
"""在镜像内解析 vllm 包内目标文件的真实路径（层 3/层 4 共用）。

为什么不写死 /usr/local/lib/python3.12/dist-packages/…：那是"参考环境＝Ubuntu 24.04 + 系统 pip"
这一种布局的产物。venv/conda 落 site-packages、Debian 老分支 python 号不同，写死会让补丁层
报 FileNotFoundError 却不指向根因（群友 2026-10-02 那次就是这个形状）。

解析失败时把解释器信息一并打出来，一次分辨两种根因：
  ① vllm 可导入但 qwen4_exp 不在 → 基座不含该模型目录（不是 SM75 v0.1.6 ultra 派生镜像）
  ② vllm 不可导入 → 基座根本不是预期镜像
用法：python3 resolve_vllm_paths.py        → 成功打印绝对路径，rc=0；失败 rc=3 并打诊断
"""
import os
import sys
import sysconfig

REL = ("models", "qwen4_exp", "nvidia", "ngram_embedding.py")
BASELINE_DIR = "/usr/local/lib/python3.12/dist-packages/vllm"


def resolve(require_exists=True):
    """返回 (绝对路径, None) 或 (None, 错误说明)。"""
    try:
        import vllm
    except Exception as e:  # noqa: BLE001 - 任何导入失败都要变成可读诊断
        return None, "vllm 导入失败: %r" % (e,)
    root = os.path.dirname(os.path.abspath(vllm.__file__))
    path = os.path.join(root, *REL)
    if require_exists and not os.path.isfile(path):
        return None, "vllm 包内没有 %s（vllm 根=%s）" % ("/".join(REL), root)
    return path, None


def diagnostics():
    out = [
        "--- 解释器与包路径诊断 ---",
        "python      = %s" % sys.version.split()[0],
        "executable  = %s" % sys.executable,
        "sys.prefix  = %s" % sys.prefix,
        "purelib     = %s" % sysconfig.get_paths()["purelib"],
        "基线口径    = %s（参考环境 Ubuntu 24.04 + 系统 pip；布局不同不影响补丁，只说明这台机不是参考环境）" % BASELINE_DIR,
    ]
    try:
        import vllm
        out.append("vllm.__file__ = %s" % vllm.__file__)
        out.append("vllm version  = %s" % getattr(vllm, "__version__", "?"))
    except Exception as e:  # noqa: BLE001
        out.append("vllm 不可导入 = %r" % (e,))
    return "\n".join(out)


if __name__ == "__main__":
    p, err = resolve(require_exists="--allow-missing" not in sys.argv)
    if err:
        print("RESOLVE_FAIL " + err)
        print(diagnostics())
        sys.exit(3)
    print(p)
