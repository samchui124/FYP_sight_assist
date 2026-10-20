"""check_kotlin_compiles.py 的 R 存根生成。

## 为什么这个工具本身要被测

`R` 是 AGP 从资源生成的类，单独用 kotlinc 编译源码时**不存在**。
所以门禁必须自己生成一份只含符号的存根，否则任何正常的 Android 代码
（`R.string.x`、`R.drawable.x`）都会被误报成 `unresolved reference 'R'`。

而存根一旦生成错，症状是**反过来**的：门禁报出一堆看起来像真错的东西。
开发工具说谎比开发工具不工作更糟，因为它会让人去改本来正确的代码。
所以这里把「扫描 res/」与「生成存根」两段钉住。
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from check_kotlin_compiles import (  # noqa: E402
    app_namespace,
    collect_resources,
    write_stub_r,
)


@pytest.fixture
def fake_res(tmp_path):
    """造一棵最小的 res/ 树：两个 values（含限定符）、drawable、mipmap。"""
    res = tmp_path / "res"
    (res / "values").mkdir(parents=True)
    (res / "values-zh-rHK").mkdir()
    (res / "drawable").mkdir()
    (res / "mipmap-xxhdpi").mkdir()

    (res / "values" / "strings.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '  <string name="app_name">PathGuide</string>\n'
        '  <string name="tile_label">Start guidance</string>\n'
        "</resources>\n", encoding="utf-8")
    (res / "values-zh-rHK" / "strings.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '  <string name="app_name">領路通</string>\n'
        '  <string name="tile_label">開始引導</string>\n'
        "</resources>\n", encoding="utf-8")
    (res / "drawable" / "ic_qs_tile.xml").write_text("<vector/>", encoding="utf-8")
    (res / "mipmap-xxhdpi" / "ic_launcher.png").write_bytes(b"\x89PNG")
    return res


def test_collects_strings_and_drawables(fake_res):
    got = collect_resources(fake_res)
    assert got["string"] == {"app_name", "tile_label"}
    assert got["drawable"] == {"ic_qs_tile"}
    assert got["mipmap"] == {"ic_launcher"}


def test_locale_qualified_values_merge_not_duplicate(fake_res):
    """`values-zh-rHK` 是同一个 string 类型的限定符目录，要合并而不是多出一类。"""
    got = collect_resources(fake_res)
    assert "string-zh-rHK" not in got
    assert len(got["string"]) == 2


def test_missing_res_dir_returns_empty_not_crash(tmp_path):
    """res/ 不存在时回空，让调用方去警告，而不是抛异常。"""
    assert collect_resources(tmp_path / "nope") == {}


def test_nine_patch_name_is_stripped(fake_res):
    """`foo.9.png` 的资源名是 `foo`，不是 `foo.9`（那样含点、是非法标识符）。"""
    (fake_res / "drawable" / "bg.9.png").write_bytes(b"\x89PNG")
    got = collect_resources(fake_res)
    assert "bg" in got["drawable"]
    assert not any("." in n for n in got["drawable"])


def test_invalid_resource_names_are_skipped(fake_res):
    """含点、连字符、空名、数字开头的资源名不能进 Kotlin 标识符位置。

    注意断言的是「非法名被排除」而不是精确集合：`values-zh-rHK` 里的
    合法名会一并合并进来，那是另一个测试负责的事。
    """
    (fake_res / "values" / "strings.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '  <string name="ok_name">x</string>\n'
        '  <string name="bad.name">x</string>\n'
        '  <string name="bad-name">x</string>\n'
        '  <string name="">x</string>\n'
        '  <string name="1leading">x</string>\n'
        "</resources>\n", encoding="utf-8")
    got = collect_resources(fake_res)
    assert "ok_name" in got["string"]
    for bad in ("bad.name", "bad-name", "", "1leading"):
        assert bad not in got["string"], f"{bad!r} 是非法的資源名，不該進存根"


def test_stub_is_valid_kotlin_shape(tmp_path):
    stub = tmp_path / "R.kt"
    n = write_stub_r("hk.example.app", {"string": {"app_name"}, "drawable": {"ic_x"}}, stub)
    src = stub.read_text(encoding="utf-8")
    assert n == 2
    assert src.startswith("//")
    assert "package hk.example.app" in src
    assert "object R {" in src
    assert "    object drawable {" in src
    assert "const val ic_x = 0" in src
    # 花括号必须配平，否则编译器会报在存根自己身上，误导排查方向
    assert src.count("{") == src.count("}")


def test_kotlin_keyword_resource_name_is_escaped(tmp_path):
    """资源名撞上 Kotlin 关键字时要加反引号，否则存根自己编译不过。"""
    stub = tmp_path / "R.kt"
    write_stub_r("p", {"string": {"object", "in", "normal"}}, stub)
    src = stub.read_text(encoding="utf-8")
    assert "const val `object` = 0" in src
    assert "const val `in` = 0" in src
    assert "const val normal = 0" in src


def test_empty_resources_still_produces_compilable_stub(tmp_path):
    """空资源也要产出合法的空 R，而不是空文件（空文件会让错误指向別处）。"""
    stub = tmp_path / "R.kt"
    n = write_stub_r("p", {}, stub)
    src = stub.read_text(encoding="utf-8")
    assert n == 0
    assert "object R {" in src and src.count("{") == src.count("}")


def test_app_namespace_matches_gradle():
    """从真实的 build.gradle.kts 读 namespace；写死会使存根落到错误的包。"""
    assert app_namespace() == "hk.pathguide.pathguide"


def test_real_resources_include_the_tile_resources():
    """真实 res/ 里必须能扫到磁贴的两个资源。

    少了 `tile_label`，存根就没有它，而磁贴服务引用 `R.string.tile_label`
    会被误报成编译错误。
    """
    got = collect_resources()
    assert "tile_label" in got.get("string", set())
    assert "app_name" in got.get("string", set())
    assert "ic_qs_tile" in got.get("drawable", set())
