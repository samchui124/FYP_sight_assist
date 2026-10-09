"""Grounding DINO 老师：**让 stage1 与 gd_detect 共用同一套推理实现**。

## 为什么单独抽成模块

`gd_detect.py` 里已经有一份正确实现（含它的坑），而把 GDINO 接进 stage1
需要完全一样的逻辑。若各写一份，两处会各自漂移 —— 而漂移的表现是
「同一张图两条路给出不同的框」，这类差异极难查，且不会报错。

所以这里只保留**一份**实现与**一条**约束说明，两边都 import 它。

## ★ 必须遵守：每次只发一个 prompt

`configs/class_aliases.json` 的 `gdin_prompt_note` 记着实测：

> Grounding DINO **每次只能发一个 prompt**。实测每组发 6 个 prompt 时产生
> `##cala stairs` / `estor` 等破损标签，且 `estor` 被错误映射成 `shop_front`。
> 单 prompt 后异常降至 12/792。prompt 必须小写 + 句号结尾。

代价是「N 个类要跑 N 次推理」，但那是**正确性**的代价，不能省。
（这正是 GDINO 慢的原因，也是它与 YOLO-World「一次全类」路径的结构差异。）

> **对那句「异常降至 12/792」的更正**：当时用的是「label != query 即算异常」，
> 而 GDINO 返回的本来就可能只是提问句里被匹配到的**子串**（见 `classify_label`），
> 所以 12/792 是**真破损的上界**，不是破损数。多 prompt 会产出 `##cala stairs`
> 这种 WordPiece 残留是确实的（含 `##`，无法用子串解释），结论不变；
> 但别再把 12/792 当成破损计数引用。

## 与 YOLO-World 路径的差异

| | YOLO-World | Grounding DINO |
|---|---|---|
| 调用次数 | 1 次推理出全部 prompt 的框 | **每类 1 次推理** |
| prompt | 每类多条说法（`yolo_world_prompts`） | 每类**一条**（`gdin_prompt` 或 `verify_query`） |
| 阈值 | 全局一个 `--conf` | **每类一个** `gdin_threshold`（实测各类分值分布差异极大） |
| 已知缺陷 | 对 9 个核心类零召回（`stairs` 最高分 0.000） | 覆盖广（48 类里 46 类非零）但噪声大（≈66 框/图） |
"""
from __future__ import annotations

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MODEL = "IDEA-Research/grounding-dino-tiny"

_PUNCT = re.compile(r"[^a-z0-9]+")


def _normalize_label(s: str) -> str:
    """小写 + 非字母数字压成单空格。`water - filled` == `water-filled`。"""
    return _PUNCT.sub(" ", (s or "").lower()).strip()


def queries_from_taxonomy(tax) -> list[dict]:
    """从类别表 + 别名表取出「每个类一条」的 GDINO 查询。

    用 `gdin_prompt`（若有）否则 `verify_query` 作为提问词；
    阈值用该类自己的 `gdin_threshold`（缺省 0.30）。

    `never_from_vlm` 标记的类**跳过** —— 那类东西本身「无法判定」，
    让模型去出框自相矛盾。
    """
    out: list[dict] = []
    for c in tax.classes:
        if c.get("never_from_vlm"):
            continue
        q = c.get("gdin_prompt") or c.get("verify_query")
        if not q:
            continue
        out.append({
            "class_id": int(c["id"]),
            "name_en": c["name_en"],
            "query": str(q).lower(),
            "threshold": float(c.get("gdin_threshold") or 0.30),
        })
    return out


def local_snapshot(repo_id: str, hub_root: Path | None = None) -> Path | None:
    """在**工作区内**的 HF hub 里找已下好的快照目录；找不到返回 None。

    ## 为什么必须自己认路径，而不是让调用者改环境变量

    本项目有两处 HF 缓存，**分居两地**（见 `scripts/env_setup.py` docstring 第 4 条）：

    | 模型 | 在哪 |
    |---|---|
    | `IDEA-Research/grounding-dino-tiny`（约 700 MB） | 工作区内 `.hf/hub` |
    | `nvidia/LocateAnything-3B`（7.3 GB，stage2 用） | 系统默认 `~/.cache/huggingface/hub` |

    切换缓存只能靠全局改 `HF_HUB_CACHE` / `HF_HOME`，而那样做会**把另一个模型藏起来**。
    实测后果：stage1 为了离线加载 GDINO 覆盖了 `HF_HOME`，随后 stage2 就报
    「LocateAnything-3B does not appear to have files named model-0000X-of-00002.safetensors」——
    而那两个分片（4729.9 + 2576.6 MB）一直好好地躺在盘上，于是白折腾了一轮
    「网络不通、要换镜像」的诊断。

    所以这里自己认路径：调用者**不需要动任何环境变量**，也就不会误伤另一处缓存。
    """
    if hub_root is None:
        try:
            import env_setup

            hub_root = env_setup.HF_LOCAL_HUB
        except Exception:  # noqa: BLE001
            hub_root = REPO_ROOT / ".hf" / "hub"
    snaps = hub_root / f"models--{repo_id.replace('/', '--')}" / "snapshots"
    if not snaps.is_dir():
        return None
    # 有多个快照（不同 revision）时取最近下载的那个
    cands = [d for d in snaps.iterdir() if (d / "config.json").exists()]
    if not cands:
        return None
    return max(cands, key=lambda d: d.stat().st_mtime)


def load(model_id: str = DEFAULT_MODEL, device: str = "cuda",
         model_path: str | None = None):
    """加载 GDINO，返回 (processor, model, 实际来源字符串)。

    不给 `model_path` 时**优先用工作区内已下好的快照**（离线），
    找不到才回落到 Hub 在线拉取。
    """
    import torch
    from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor

    if model_path is not None:
        src, offline = model_path, True
    else:
        snap = local_snapshot(model_id)
        if snap is not None:
            src, offline = str(snap), True
        else:
            src, offline = model_id, False

    proc = AutoProcessor.from_pretrained(src, local_files_only=offline)
    model = AutoModelForZeroShotObjectDetection.from_pretrained(
        src, local_files_only=offline).to(device).eval()
    return proc, model, src


def infer(proc, model, img, query: str, thr: float,
          device: str = "cuda") -> list[dict]:
    """单 prompt 推理一张图，返回 [{bbox(归一化 xyxy), conf, label}]。

    坐标按**图像宽高**归一化，与 stage1 的 YOLO-World 路径同一约定，
    所以两条路的 `proposals.jsonl` 可以直接互换。
    """
    import torch

    inp = proc(images=img, text=query + ".", return_tensors="pt").to(device)
    with torch.no_grad():
        out = model(**inp)
    res = proc.post_process_grounded_object_detection(
        out, inp.input_ids, threshold=thr, text_threshold=0.2,
        target_sizes=[img.size[::-1]])[0]
    W, H = img.size
    labels = res.get("text_labels") or res.get("labels") or []
    hits = []
    for b, s, lb in zip(res["boxes"].tolist(), res["scores"].tolist(), labels):
        hits.append({
            "bbox": [b[0] / W, b[1] / H, b[2] / W, b[3] / H],
            "conf": float(s),
            "label": str(lb).strip(),
        })
    return hits


def classify_label(query: str, label: str) -> str:
    """给「返回的 label」分类，而不是简单地判「一致/不一致」。

    ## 为什么不能只判一致/不一致

    最初这里写的是 `label != query` 即算异常，结果实测 153 个框里有 17 个被判异常
    （11%）。逐个看下来，**它们绝大多数不是破损**：

    | query | 返回 label | 真相 |
    |---|---|---|
    | `water-filled barrier` | `water - filled barrier` | 连字符被插空格，同一句话 |
    | `roll up banner` | `banner` | 匹配到的**子串** |
    | `tree roots on the pavement` | `pavement` / `tree roots` | 匹配到的**子串** |

    GDINO 的 `post_process_grounded_object_detection` 返回的是**提问句里被匹配到的
    那段 span**，不是整句。所以多词提问词必然「不一致」——而多词提问词正是描述型
    障碍物类（`goods placed on the street`）唯一能用的措辞。按 `!=` 判异常等于专门
    冤枉这些类。

    真正的破损长这样：`##cala stairs`（WordPiece 残留）、`estor`（与所问毫无关系），
    它们会被后续的文本归一化**错误地映射成别的类**。所以必须单独识别。

    返回四种之一：
        "ok"        完全一致
        "subspan"   label 是 query 的子串（含连字符/空格差异）—— **正常**
        "artifact"  label 含 `##` WordPiece 残留 —— **真破损**
        "mismatch"  既不是子串也无 `##` —— 可疑，需人看
    """
    # `##` 必须**先判**：`_normalize_label` 会把 `#` 当标点删掉，
    # 于是 `##stairs` 归一化后正好等于 `stairs`，会被误判成 "ok"。
    # （这一条是先写错、后被 tests/test_gdino_teacher.py 抓出来的。）
    if "##" in label:
        return "artifact"
    q, l = _normalize_label(query), _normalize_label(label)
    if l == q:
        return "ok"
    if l and l in q:
        return "subspan"
    return "mismatch"


def is_label_mismatch(query: str, label: str) -> bool:
    """**可疑**（需人看），而不是「与整句不同」。

    包含 `artifact`（`##` 破损）与 `mismatch`（解释不通），**不含** `subspan` ——
    子串是 GDINO 的正常返回，见 `classify_label`。
    """
    return classify_label(query, label) in ("artifact", "mismatch")


def load_out_of_taxonomy_words() -> list[str]:
    """表外候选词（用于类别发现）。**这些不是类别**，命中后交人决定是否扩表。"""
    doc = json.loads((REPO_ROOT / "configs" / "class_aliases.json")
                     .read_text(encoding="utf-8"))
    return [w.lower() for w in doc["out_of_taxonomy_candidates"]["words"]]
