#!/usr/bin/env python3
"""
FRB 2.13 codegen 后处理 —— 每次跑 `flutter_rust_bridge_codegen generate` 之后都要跑一次。

历史踩坑（FRB 2.13.0 + Windows + rustc 1.85+）：

1. **E0753 "expected outer doc comment"**
   FRB 的 `integrate` 会把 `mod frb_generated;` **注入到 lib.rs 文件最开头**，
   排在 `//!` 文档注释之前。而 `//!` 是 inner doc comment，必须位于所有 item 之前，
   于是 rustc 报错。
   ✅ 正解：把 `mod frb_generated;` 移到所有 `//!` **之后**。
   ❌ 错的绕法：改 `include!("frb_generated.rs")` —— 会让生成文件头部的
      `#![allow(...)]` 变成非法的 inner attribute（报 "inner attribute is not permitted"），
      还会连带破坏 `#[macro_export]` 宏的作用域。
   👉 本脚本会自动把 `mod frb_generated;` 挪到文档注释之后。

2. **不要动 `IntoIntoDart` / `into_into_dart`**
   这看起来像重复单词的 bug，但它是 FRB 2.13 crate 内部**真实**的 trait 名
   （`transform_result_dco<T, E> where T: IntoIntoDart<..>`）。
   把它"修正"成 `IntoDart` 会引发几十个 trait bound 错误。

3. **不要动 SSE codec 名字**（`SseCodec` / `SseDeserializer` / `Dart2RustMessageSse`）
   FRB 2.13 的 Rust 端**没有** `Dart2RustMessageDco`（Dart→Rust 走 raw allo_isolate），
   只有 SSE 路径有完整 `from_wire`。强行 sse→dco 会引入 40+ 个找不到符号的错误。

4. **不要在 lib.rs 手动调 `frb_generated!()`**
   宏的真名是 `frb_generated_boilerplate!`，而且**生成的 frb_generated.rs 第 39 行
   已经自己调了**。再调一次会报 "cannot find macro"。

5. **`MgError` 必须是纯值类型**
   如果写成 `Http(#[from] reqwest::Error)`，FRB 会把它识别成 RustOpaque，
   进而在 Dart 端生成 `SseDecode` impl，而 Dart 端找不到该类型 → 编译失败。
   改为 `Http(String)` / `Json(String)`，手动 `map_err` 即可。
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LIB = ROOT / "src" / "lib.rs"
GEN = ROOT / "src" / "frb_generated.rs"

MOD_LINE = "mod frb_generated;"


def fix_lib_rs() -> bool:
    """确保 `mod frb_generated;` 排在所有 `//!` 文档注释之后。"""
    if not LIB.exists():
        print(f"[!] 找不到 {LIB}")
        return False

    t = LIB.read_text(encoding="utf-8")

    # 去掉旧的（可能位置错误的）声明
    t = re.sub(rf"^\s*{re.escape(MOD_LINE)}[^\n]*\n", "", t, flags=re.MULTILINE)
    # 去掉可能残留的 include!/frb_generated! 绕法
    t = re.sub(r"^\s*include!\(\"frb_generated\.rs\"\);[^\n]*\n", "", t, flags=re.MULTILINE)
    t = re.sub(r"^\s*flutter_rust_bridge::frb_generated!\(\);[^\n]*\n", "", t, flags=re.MULTILINE)

    lines = t.splitlines(keepends=True)

    # 找最后一个 `//!` 行的下标
    last_doc = -1
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("//!"):
            last_doc = i

    marker = (
        "\n"
        "// FRB v2 生成的绑定代码。\n"
        "// 注意：`mod` 声明必须放在所有 `//!` 文档注释之后，否则 rustc 报 E0753。\n"
        "// FRB 的 integrate 默认注入到文件最开头，会踩这个坑；每次 codegen 后都要检查。\n"
        f"{MOD_LINE}\n"
    )
    lines.insert(last_doc + 1, marker)
    LIB.write_text("".join(lines), encoding="utf-8")
    print(f"[ok] {LIB.name}: `{MOD_LINE}` 已置于文档注释之后")
    return True


def check_generated() -> bool:
    """校验生成文件没被误改（trait 名 / codec 名 / 宏调用）。"""
    if not GEN.exists():
        print(f"[!] 找不到 {GEN}")
        return False

    t = GEN.read_text(encoding="utf-8")
    ok = True

    if not t.lstrip().startswith("//"):
        print("[!] frb_generated.rs 头部异常")
        ok = False

    if "frb_generated_boilerplate!" not in t:
        print("[!] 缺少 frb_generated_boilerplate! 宏调用")
        ok = False

    if "IntoIntoDart" not in t:
        print("[!] 缺少 IntoIntoDart，可能被误替换过")
        ok = False

    if "SseCodec" not in t:
        print("[!] 缺少 SseCodec，可能被误替换成 DcoCodec")
        ok = False

    # `#![allow(...)]` 作为模块文件的 inner attribute 是合法的，必须保留 `#![`
    m = re.search(r"^#!\[allow", t, flags=re.MULTILINE)
    if not m:
        print("[!] 头部 `#![allow(` 缺失或被改成了 `#[`，模块 inner attribute 会失效")
        ok = False

    print(f"[ok] {GEN.name}: 结构校验{'通过' if ok else '失败'}")
    return ok


if __name__ == "__main__":
    a = fix_lib_rs()
    b = check_generated()
    sys.exit(0 if (a and b) else 1)
