"""在本地直接编译 Kotlin 源码，提前发现编译错误。

## 为什么需要它

Gradle 构建要 1–3 分钟，而 Kotlin 的编译错误本来可以在几秒内发现。
更麻烦的是「构建失败 → 用户贴错误 → 代理改 → 用户再构建」这个循环，
每轮都要占用用户几分钟。

实测：Dart/子进程在受限环境下不可用，但 **JVM 可以直接跑**，而
`kotlin-compiler-embeddable` 已经在 Gradle 缓存里（依赖下载过就有）。
于是可以绕开 Gradle，直接用它编译项目自己的 Kotlin 源文件。

这已经抓到过一个真实错误：
    VisionPlugin.kt:921:28: error: unresolved reference 'PAD'
（常量定义在了 VisionPlugin 的 companion 里，却在 YoloDetector 中引用——
顶层类之间不能互访 companion 成员。）

## 它不替代 Gradle

只检查**语法与类型**，不做资源打包、不做 D8、不验 AGP 集成。
正式构建仍必须由 Gradle 执行。它的定位是「快速门禁」。

## 用法

    python scripts/check_kotlin_compiles.py
    python scripts/check_kotlin_compiles.py -v   # 显示全部编译器输出
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ANDROID_APP = REPO_ROOT / "app" / "android" / "app"
KOTLIN_SRC = ANDROID_APP / "src" / "main" / "kotlin"
GRADLE_CACHE = REPO_ROOT / ".tools" / "gradle" / "caches" / "modules-2" / "files-2.1"
JBR = Path(r"C:\Program Files\Android\Android Studio\jbr\bin\java.exe")
WORK = REPO_ROOT / ".tmp" / "kotlin-compile-check"

# 编译器自身需要的 jar（版本要成套，混版本会 NoClassDefFound）
COMPILER_JARS = [
    "kotlin-compiler-embeddable",
    "kotlin-stdlib",
    "kotlin-reflect",
    "kotlin-daemon-embeddable",
    "kotlin-script-runtime",
    "kotlinx-coroutines-core-jvm",
    "intellij-core",
    "annotations",
]

# 项目源码依赖的库（AAR 需要抽出里面的 classes.jar）
PROJECT_AARS = [
    "camera-core-1.6.2.aar", "camera-camera2-1.6.2.aar", "camera-lifecycle-1.6.2.aar",
    "camera-view-1.6.2.aar", "litert-2.2.0.aar", "litert-api-2.2.0.aar",
    "core-1.13.1.aar", "lifecycle-runtime-2.7.0.aar", "annotation-experimental-1.4.1.aar",
]
PROJECT_JARS = [
    "guava-*-android.jar",
    "failureaccess-*.jar",
    "jspecify-*.jar",
    "concurrent-futures-1*.jar",
    "lifecycle-common-jvm-*.jar",
    "lifecycle-common-2.7.0.jar",
    "annotations-23.0.0.jar",
]

# ★ listenablefuture 这个坐标在 Gradle 里几乎总是被替换成
#   9999.0-empty-to-avoid-conflict-with-guava（空壳），真正的 ListenableFuture
#   来自 guava 本身。所以不主动加空壳 jar，避免引入冲突。

# ★ 按前缀匹配的 jar。用精确前缀而不是「名字最短」，否则会选错变体：
# 曾用「名长最短」的启发式挑 kotlin-stdlib，结果挑中 jdk8 变体而漏掉主 stdlib，
# 于是满屏 "cannot access built-in declaration 'kotlin.Int'"。
# flutter_embedding 是 Flutter 引擎的 jar，缺了会让 io.flutter.* 全部 unresolved。
PROJECT_JARS_BY_PREFIX = [
    ("kotlin-stdlib-2.", 1),          # 主 stdlib（可接受多版本，取第一个）
    ("flutter_embedding_debug", 1),   # io.flutter.embedding.*
]


def android_jar() -> Path | None:
    sdk = Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk" / "platforms"
    if not sdk.is_dir():
        return None
    best, best_ver = None, ()
    for d in sdk.iterdir():
        j = d / "android.jar"
        if not j.exists():
            continue
        try:
            ver = tuple(int(p) for p in d.name.split("-")[-1].split("."))
        except ValueError:
            ver = ()
        if ver > best_ver:
            best, best_ver = j, ver
    return best


def find_jar(name: str, *, exact_suffix: bool = True) -> Path | None:
    """在 Gradle 缓存里找 jar。支持三种写法：
    - 完整文件名（`guava-33.5.0-android.jar`）
    - 不含 .jar 的完整名（`guava-33.5.0-android`）
    - 带通配（`lifecycle-common-*`）
    """
    if not GRADLE_CACHE.is_dir():
        return None
    hits: list[Path] = []
    if "*" in name:
        hits = [p for p in GRADLE_CACHE.rglob("*.jar") if p.match(name)]
    else:
        tail = name if name.endswith(".jar") else f"{name}.jar"
        hits = [p for p in GRADLE_CACHE.rglob("*.jar") if p.name == tail]
    if not hits:
        return None
    # 同名多版本时取版本号最大的
    def ver(p: Path) -> tuple:
        out: list[int] = []
        for seg in p.stem.replace("-", ".").split("."):
            if seg.isdigit():
                out.append(int(seg))
            else:
                out.append(0)
        return tuple(out)

    hits.sort(key=ver)
    return hits[-1]


def compiler_classpath() -> list[Path]:
    """编译器自身 + 其运行时依赖。版本必须成套。"""
    out: list[Path] = []
    for base in COMPILER_JARS:
        # 优先取版本最高的，避免抓到旧版本导致 NoClassDefFound
        cands = [p for p in GRADLE_CACHE.rglob("*.jar")
                 if p.name.startswith(f"{base}-") or p.name == f"{base}.jar"]
        if not cands:
            continue

        def ver(p: Path) -> tuple:
            stem = p.stem.replace(base, "").strip("-")
            parts = []
            for seg in stem.split("-"):
                for sub in seg.split("."):
                    if sub.isdigit():
                        parts.append(int(sub))
            return tuple(parts)

        cands.sort(key=ver)
        out.append(cands[-1])
    return out


def project_classpath() -> list[Path]:
    out: list[Path] = []
    WORK.mkdir(parents=True, exist_ok=True)
    for aar in PROJECT_AARS:
        hits = [p for p in GRADLE_CACHE.rglob(aar)]
        if not hits:
            continue
        dest = WORK / hits[0].stem
        dest.mkdir(parents=True, exist_ok=True)
        cj = dest / "classes.jar"
        if not cj.exists():
            with zipfile.ZipFile(hits[0]) as z:
                try:
                    z.extract("classes.jar", dest)
                except KeyError:
                    continue
        out.append(cj)
    for j in PROJECT_JARS:
        p = find_jar(j)
        if p:
            out.append(p)
    # kotlin-stdlib / flutter_embedding 按前缀匹配（版本号会变）
    for prefix, take in PROJECT_JARS_BY_PREFIX:
        cands = sorted(p for p in GRADLE_CACHE.rglob("*.jar") if p.name.startswith(prefix))
        # 排除 -jdk7/-jdk8 之类的变体，只取主 jar
        main = [p for p in cands if not any(
            v in p.name for v in ("-jdk7", "-jdk8", "-sources", "-javadoc"))]
        chosen = (main or cands)[:take]
        out.extend(chosen)
    aj = android_jar()
    if aj:
        out.append(aj)
    return out


def app_namespace() -> str | None:
    """从 build.gradle.kts 读 `namespace = "..."`。

    为什么要读而不是写死：存根 `R` 必须与真实 AGP 生成的 `R` 落在**同一个包**里，
    否则 Kotlin 里 `R.string.x` 照样解析不到，而且错误信息看不出是包名错了。
    """
    gradle = ANDROID_APP / "build.gradle.kts"
    if not gradle.exists():
        return None
    m = re.search(r'namespace\s*=\s*"([^"]+)"', gradle.read_text(encoding="utf-8"))
    return m.group(1) if m else None


# Kotlin 硬关键字不能直接当标识符（资源名撞上时要加反引号）。
_KOTLIN_KEYWORDS = {
    "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if",
    "in", "interface", "is", "null", "object", "package", "return", "super", "this",
    "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while",
}

# 合法的资源名（Android 本身就是这个限制）。
_RES_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

# values/ 目录里值得生成符号的标签。
_VALUE_TAGS = ("string", "color", "dimen", "style", "bool", "integer", "array",
               "string-array", "integer-array", "plurals", "attr")


def collect_resources(res_root: Path | None = None) -> dict[str, set[str]]:
    """扫描 res/，返回 {资源类型: {名字}}。

    ★ 只需要**名字**，不需要值：存根 `R` 的作用只是让编译器知道符号存在。
      真正的值由 AGP 在正式构建时生成。
    """
    found: dict[str, set[str]] = {}

    def add(kind: str, name: str) -> None:
        if _RES_NAME.match(name):
            found.setdefault(kind, set()).add(name)

    if res_root is None:
        res_root = ANDROID_APP / "src" / "main" / "res"
    if not res_root.is_dir():
        return found

    for d in sorted(p for p in res_root.iterdir() if p.is_dir()):
        # 目录名形如 `values`、`values-zh-rHK`、`drawable`、`mipmap-xxhdpi`
        kind = d.name.split("-", 1)[0]
        if kind == "values":
            for xml in sorted(d.glob("*.xml")):
                try:
                    root = ET.parse(xml).getroot()
                except ET.ParseError:
                    continue
                for el in root:
                    tag = el.tag if isinstance(el.tag, str) else ""
                    if tag in _VALUE_TAGS:
                        add(tag, el.get("name", ""))
        elif kind in ("drawable", "mipmap", "layout", "xml", "menu", "anim", "raw"):
            for f in sorted(d.iterdir()):
                if not f.is_file():
                    continue
                # `ic_launcher.png` -> ic_launcher；`foo.9.png` -> foo
                add(kind, f.name.split(".")[0])
    return found


def write_stub_r(namespace: str, resources: dict[str, set[str]], dest: Path) -> int:
    """生成只含符号、不含值的 `R` 存根，返回成员总数。

    为什么需要：`R` 是 AGP 从资源生成的，单独用 kotlinc 编译源码时**不存在**，
    于是任何引用 `R.drawable.x` / `R.string.x` 的正常 Android 代码都会报
    `unresolved reference 'R'`。那是门禁的盲点，不是代码的错。
    """
    lines = [
        "// 由 scripts/check_kotlin_compiles.py 自动生成，请勿编辑。",
        "// 只提供符号名，值一律为 0：编译检查不需要真实资源 id。",
        f"package {namespace}",
        "",
        "@Suppress(\"unused\")",
        "object R {",
    ]
    n = 0
    for kind in sorted(resources):
        members = sorted(resources[kind])
        if not members:
            continue
        lines.append(f"    object {kind} {{")
        for name in members:
            ident = f"`{name}`" if name in _KOTLIN_KEYWORDS else name
            lines.append(f"        const val {ident} = 0")
            n += 1
        lines.append("    }")
    lines.append("}")
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--no-stub-r", action="store_true",
                    help="不生成 R 存根（用于确认某一类错误是否由存根引起）")
    args = ap.parse_args()

    if not JBR.exists():
        print(f"未找到 JDK：{JBR}")
        return 2
    if not GRADLE_CACHE.is_dir():
        print(f"未找到 Gradle 缓存：{GRADLE_CACHE}")
        print("请先在这台机器上成功构建过一次（或让用户跑一次 flutter run）。")
        return 2

    sources = sorted(KOTLIN_SRC.rglob("*.kt"))
    if not sources:
        print(f"未找到 Kotlin 源文件：{KOTLIN_SRC}")
        return 2

    cc = compiler_classpath()
    pc = project_classpath()
    if not cc or not pc:
        print(f"类路径不完整：编译器 {len(cc)} 项 / 项目 {len(pc)} 项")
        return 2
    if args.verbose:
        print(f"编译器类路径 {len(cc)} 项：")
        for p in cc:
            print("  " + p.name)
        print(f"项目类路径 {len(pc)} 项：")
        for p in pc:
            print("  " + (p.name if p.name != "classes.jar" else f"{p.parent.name}/classes.jar"))

    out_dir = WORK / "out"
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # ---- R 存根 ----
    # 见 write_stub_r 的说明：没有它，任何引用 R 的正常 Android 代码都会误报。
    extra_sources: list[Path] = []
    if not args.no_stub_r:
        ns = app_namespace()
        if not ns:
            print("[WARN] build.gradle.kts 里读不到 namespace，跳过 R 存根；"
                  "引用 R 的文件可能误报 unresolved reference 'R'")
        else:
            resources = collect_resources()
            stub_dir = WORK / "stub_r"
            stub_dir.mkdir(parents=True, exist_ok=True)
            stub = stub_dir / "R.kt"
            n_members = write_stub_r(ns, resources, stub)
            extra_sources.append(stub)
            print(f"R 存根：{ns}，{len(resources)} 类资源 / {n_members} 个符号")
            # ★ 空存根是个**假阳性陷阱**：如果 res/ 扫描失败（目录搬家、权限、
            #   解析器跟不上），存根就没有成员，于是所有引用 R 的代码都会被报
            #   `unresolved reference 'R'`——看起来像代码错了，其实是门禁坏了。
            #   所以这里主动检查并说清楚。
            if n_members == 0 or not resources:
                refs_r = [s for s in sources if "R." in s.read_text(encoding="utf-8")]
                if refs_r:
                    print(f"[WARN] R 存根是空的，但有 {len(refs_r)} 个源文件引用了 R。"
                          f"下面若有 unresolved reference 'R'，那是**本脚本扫描 res/ 失败**"
                          f"造成的，不是代码错误。res/ 实际路径：{ANDROID_APP / 'src' / 'main' / 'res'}")

    cmd = [
        str(JBR),
        "-cp", ";".join(str(p) for p in cc),
        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
        "-no-stdlib",
        "-classpath", ";".join(str(p) for p in pc),
        "-d", str(out_dir),
        *[str(s) for s in sources],
        *[str(s) for s in extra_sources],
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace")

    output = (proc.stdout or "") + (proc.stderr or "")
    errors = [ln for ln in output.splitlines() if "error:" in ln]

    print(f"Kotlin 编译检查：{len(sources)} 个源文件")
    if errors:
        print(f"\n发现 {len(errors)} 个编译错误：")
        for e in errors:
            print("  " + e.strip())
        return 1
    if proc.returncode != 0:
        print(f"\n编译器退出码 {proc.returncode}，但没有 error: 行，原始输出：")
        print(output[-3000:])
        return 1

    n_class = sum(1 for _ in out_dir.rglob("*.class"))
    print(f"通过（生成 {n_class} 个 class 文件）")
    if args.verbose:
        print(output[-2000:])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
