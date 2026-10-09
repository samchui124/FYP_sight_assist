"""stage1 的标签/图像路径推导。

这里唯一要守的不变量：**标签路径必须逐级镜像输入目录树**。
它曾经被拍平成 `子目录__文件名.txt`，后果是 X-AnyLabeling 一个标签都找不到，
而表现是「0 个实例」——不报错，看起来就像图里真的没东西。
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))

from stage1_propose import image_path_for, label_path_for  # noqa: E402


@pytest.mark.parametrize("rel,expected", [
    ("a.jpg", "a.txt"),
    ("sub/a.jpg", "sub/a.txt"),
    ("a/b/c.png", "a/b/c.txt"),
    ("a/b/c.jpeg", "a/b/c.txt"),
])
def test_label_path_mirrors_tree(tmp_path, rel, expected):
    got = label_path_for(tmp_path / "labels", rel)
    assert got.relative_to(tmp_path / "labels").as_posix() == expected


def test_label_path_does_not_flatten(tmp_path):
    """拍平的写法会得到 `sub__a.txt` —— 钉住它不许回来。"""
    got = label_path_for(tmp_path / "labels", "sub/a.jpg")
    assert "__" not in got.name
    assert got.parent.name == "sub"


def test_label_and_image_paths_are_isomorphic(tmp_path):
    """复核包要能被 X-AnyLabeling 直接打开：images/ 与 labels/ 同构。

    同构才能让「图 xxx/sub/a.jpg」对上「标签 labels/sub/a.txt」。
    """
    for rel in ("a.jpg", "sub/a.jpg", "a/b/c.png"):
        lab = label_path_for(tmp_path / "labels", rel).relative_to(tmp_path / "labels")
        img = image_path_for(tmp_path / "images", rel).relative_to(tmp_path / "images")
        assert lab.with_suffix("") == img.with_suffix("")


def test_extension_is_replaced_not_appended(tmp_path):
    """`with_suffix` 而不是拼字符串：`a.jpg` 不能变成 `a.jpg.txt`。"""
    assert label_path_for(tmp_path, "a.jpg").name == "a.txt"
