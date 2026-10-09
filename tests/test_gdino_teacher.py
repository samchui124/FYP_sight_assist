"""GDINO 老师：提问词抽取与「返回标签」分类。

`classify_label` 是这里唯一有实质逻辑的东西，而且它已经被写错过一次：
最初按 `label != query` 判异常，于是 11% 的框被**丢掉**，且丢的都是多词提问词
（= 描述型障碍物类，恰恰是最需要 GDINO 的那些）。这类错误不会报错，
只会让某一类悄悄变少，所以必须钉测试。
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "pipeline"))

from gdino_teacher import (  # noqa: E402
    classify_label,
    is_label_mismatch,
    local_snapshot,
    queries_from_taxonomy,
)


@pytest.fixture(scope="module")
def tax():
    from label_taxonomy import LabelTaxonomy

    return LabelTaxonomy()


# ---- 分类 ----

@pytest.mark.parametrize("query,label", [
    ("stairs", "stairs"),
    ("water-filled barrier", "water - filled barrier"),
    ("water-filled barrier", "water-filled barrier"),
    ("roll up banner", "banner"),
    ("tree roots on the pavement", "pavement"),
    ("tree roots on the pavement", "tree roots"),
    ("goods placed on the street", "goods"),
])
def test_ok_and_subspan_are_not_anomalies(query, label):
    """子串是 GDINO 的正常返回（它给的是被匹配到的片段），不是破损。"""
    assert classify_label(query, label) in ("ok", "subspan")
    assert is_label_mismatch(query, label) is False


@pytest.mark.parametrize("label", ["##cala stairs", "##estor", "estor"])
def test_wordpiece_artifact_is_detected(label):
    """`##` 残留与毫不相干的词是真破损 —— 这类会被后续归一化错误映射到别的类。"""
    kind = classify_label("stairs", label)
    assert kind in ("artifact", "mismatch")
    assert is_label_mismatch("stairs", label) is True


def test_artifact_wins_over_subspan():
    """`##` 判定优先于子串判定：`##stairs` 里确实含 `stairs`，但它仍是破损。"""
    assert classify_label("stairs", "##stairs") == "artifact"


def test_short_label_does_not_match_by_empty_string():
    """空 label 不能被当成「子串」放过去（空串是任何串的子串）。"""
    assert classify_label("stairs", "") == "mismatch"
    assert classify_label("stairs", "   ") == "mismatch"


def test_case_and_punctuation_insensitive():
    assert classify_label("Water-Filled Barrier.", "WATER FILLED BARRIER") == "ok"


@pytest.mark.parametrize("query,label", [("bicycle", "bicycles")])
def test_plural_is_flagged_not_silently_ok(query, label):
    """复数是**可疑**，不是正常。

    钉住现状：宁可多报、由人看，也不要静默放过。若将来决定把复数归入正常，
    必须连同这里的期望一起改 —— 否则「判定变松了」这件事就没人看见了。
    """
    assert is_label_mismatch(query, label) is True


# ---- 提问词抽取 ----

def test_one_query_per_class(tax):
    """GDINO 一次只能发一个 prompt，所以每类恰好一条提问词。"""
    qs = queries_from_taxonomy(tax)
    assert len(qs) == len(tax.classes)
    assert len({q["class_id"] for q in qs}) == len(qs)
    assert all(q["query"] == q["query"].lower() for q in qs)


def test_never_from_vlm_classes_are_skipped(tax):
    """无法判定的类不该被拿去提问 —— 让模型给「无法判定」的东西出框是自相矛盾。"""
    qs = queries_from_taxonomy(tax)
    skipped = {c["id"] for c in tax.classes if c.get("never_from_vlm")}
    assert skipped.isdisjoint({q["class_id"] for q in qs})


def test_thresholds_are_per_class_and_in_range(tax):
    """阈值是**逐类**的（实测各类分值分布差异极大），不是全局一个数。"""
    qs = queries_from_taxonomy(tax)
    assert all(0.0 < q["threshold"] <= 1.0 for q in qs)
    assert len({q["threshold"] for q in qs}) > 1


def test_generic_obstacle_queries_its_own_word_not_the_umbrella(tax):
    """48=obstacle 的提问词是 `barrier` 而不是伞形词本身。

    伞形词（"obstacle"）作提问词会让 GDINO 把任何东西都框成障碍物；
    用具体说法（barrier）才拿得到可复核的框。
    """
    qs = {q["class_id"]: q["query"] for q in queries_from_taxonomy(tax)}
    assert qs[48] == "barrier"
    assert qs[49] == "escalator"


# ---- 本地快照解析（踩过的坑，钉死）----

def _fake_hub(root, repo_id, snapshots, with_config=True):
    for name in snapshots:
        d = root / f"models--{repo_id.replace('/', '--')}" / "snapshots" / name
        d.mkdir(parents=True)
        if with_config:
            (d / "config.json").write_text("{}", encoding="utf-8")
    return root


def test_local_snapshot_finds_downloaded_model(tmp_path):
    _fake_hub(tmp_path, "IDEA-Research/grounding-dino-tiny", ["abc123"])
    got = local_snapshot("IDEA-Research/grounding-dino-tiny", hub_root=tmp_path)
    assert got is not None
    assert got.name == "abc123"


def test_local_snapshot_none_when_absent(tmp_path):
    """没下过就返回 None（去在线拉），而不是抛异常。"""
    assert local_snapshot("IDEA-Research/grounding-dino-tiny", hub_root=tmp_path) is None


def test_local_snapshot_ignores_empty_snapshot(tmp_path):
    """只有目录、没有 config.json 的空快照不算「已下好」。

    这正是那个坑的样子：快照目录存在、小文件也在，但权重分片缺失。
    判据用 config.json 存在与否，**不能只看目录在不在**。
    """
    _fake_hub(tmp_path, "IDEA-Research/grounding-dino-tiny", ["empty"], with_config=False)
    assert local_snapshot("IDEA-Research/grounding-dino-tiny", hub_root=tmp_path) is None


def test_local_snapshot_picks_newest(tmp_path):
    import os
    import time

    _fake_hub(tmp_path, "nvidia/LocateAnything-3B", ["old", "new"])
    base = tmp_path / "models--nvidia--LocateAnything-3B" / "snapshots"
    os.utime(base / "old", (time.time() - 1000, time.time() - 1000))
    got = local_snapshot("nvidia/LocateAnything-3B", hub_root=tmp_path)
    assert got is not None and got.name == "new"


def test_default_hub_root_is_the_in_workspace_one():
    """默认必须指向工作区内的 `.hf/hub`，不是系统缓存。

    两个缓存分居两地，GDINO 在工作区内；默认指错就等于每次都要在线重下。
    """
    import env_setup

    got = local_snapshot("IDEA-Research/grounding-dino-tiny")
    assert got is not None, "工作区内应有已下好的 GDINO 快照"
    assert env_setup.HF_LOCAL_HUB in got.parents
