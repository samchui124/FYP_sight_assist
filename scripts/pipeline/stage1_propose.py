"""三段式自动预标 —— 第一段：出候选框（老师可以是 YOLO-World 或 Grounding DINO）。

对每张图推理、再做**类内 NMS 合并**，产出**同一份** `proposals.jsonl`，
后两段（`stage2_verify.py` / `stage3_arbitrate.py`）不需要知道老师是谁。

## 两个老师的取舍（实测）

| | `--teacher yoloworld` | `--teacher gdino` |
|---|---|---|
| 调用 | 1 次推理出全部 prompt 的框 | **每类 1 次推理**（GDINO 不能一次发多个 prompt） |
| 速度 | 快（批量前向） | **慢得多**（N 类 × N 图） |
| 覆盖 | 对 9 个核心类**零召回**（`stairs` 最高分 0.000） | 48 类里 **46 类非零** |
| 噪声 | 少 | **大**（实测 ≈66 框/图），靠后两段筛 |
| 阈值 | 全局一个 `--conf` | **每类一个** `gdin_threshold` |

**默认仍是 yoloworld**（快、便宜）；要覆盖结构性障碍物时用 gdino。
两者的输出格式与坐标约定完全一致，所以可以混用、可以对比。

> GDINO 路径必须在 **`.venv-vlm`** 里跑（要 transformers + torch-cuda），
> YOLO-World 路径在 `.venv` 里跑。

产出：
    <out>/proposals.jsonl   每张图的候选框（类别 id、归一化框、置信度、命中的 prompt）
    <out>/proposals_stats.json  逐类框数统计
    <out>/labels/            YOLO 标签草稿（**逐级镜像输入目录树**）
    <out>/images/            仅当 `--stage-images`：复核用的图像副本

## 让人来复核草稿（这才是这一段的终点）

第一段的产物**不是标签，是草稿**。要变成能用的数据必须过人的眼睛：

    python scripts/pipeline/stage1_propose.py --teacher gdino \\
        --images data/probe/hk/footbridge --out data/auto/draft_footbridge --stage-images
    .\\label.cmd -Images data\\auto\\draft_footbridge\\images

`--stage-images` 把图复制进 `<out>/images/`，与 `<out>/labels/` 路径一一对应，
所以 X-AnyLabeling 能直接读出草稿框、人只需改而不用从零画。
**图必须复制进 `<out>` 而不是写在源素材旁边** —— 老师草稿混进源目录后，
以后没人分得清哪些框是人标的。

用法：
    python scripts/pipeline/stage1_propose.py --images data/probe/hk --out data/auto/proposals
    python scripts/pipeline/stage1_propose.py --images data/raw/route_A --out data/auto/proposals \\
        --weights yolov8m-world.pt --limit 50
    .venv-vlm\\Scripts\\python.exe scripts/pipeline/stage1_propose.py \\
        --teacher gdino --images data/raw/external/scooter --out data/auto/proposals_scooter
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "pipeline"))

import env_setup  # noqa: E402  必须在 ultralytics 之前导入

from label_taxonomy import LabelTaxonomy, normalize_text  # noqa: E402

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def find_images(root: Path, recursive: bool = True) -> list[Path]:
    it = root.rglob("*") if recursive else root.glob("*")
    return sorted(p for p in it if p.is_file() and p.suffix.lower() in IMAGE_EXTS)


def yolo_to_xyxy(box: list[float], w: int, h: int) -> tuple[float, float, float, float]:
    """Ultralytics 的 xywh（像素、中心点）-> 归一化 xyxy。"""
    cx, cy, bw, bh = box
    return ((cx - bw / 2) / w, (cy - bh / 2) / h, (cx + bw / 2) / w, (cy + bh / 2) / h)


def nms_same_class(dets: list[dict], iou_thr: float) -> list[dict]:
    """类内 NMS：同一类别、重叠高的框只留置信度最高的。

    为什么需要：同一类别的多个 prompt 说法（"stairs" / "staircase" / "steps"）
    会各出一批框、彼此高度重叠。不合并会导致后续跨模型匹配时
    一个真实目标对应多个候选，IoU 比较失去意义。
    """
    def iou(a: dict, b: dict) -> float:
        ax1, ay1, ax2, ay2 = a["bbox"]
        bx1, by1, bx2, by2 = b["bbox"]
        ix1, iy1 = max(ax1, bx1), max(ay1, by1)
        ix2, iy2 = min(ax2, bx2), min(ay2, by2)
        iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
        inter = iw * ih
        if inter <= 0:
            return 0.0
        aa = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
        ab = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
        u = aa + ab - inter
        return inter / u if u > 0 else 0.0

    ordered = sorted(dets, key=lambda d: d["conf"], reverse=True)
    kept: list[dict] = []
    for d in ordered:
        if all(iou(d, k) <= iou_thr for k in kept):
            kept.append(d)
    return kept


def make_yoloworld_detector(args, prompts, prompt_to_id):
    """YOLO-World 老师：**一次前向**出全部 prompt 的框。

    返回 `(detect, teacher_stats)`，其中 `detect(paths) -> [(raw, w, h) | None]`。
    与 GDINO 路径同签名，所以 main() 里的合并/写出代码只有一份。
    """
    from ultralytics import YOLO

    model = YOLO(args.weights)
    model.set_classes(prompts)
    # Ultralytics 会把 set_classes 的文本按原顺序存为 names
    names = model.names
    if len(names) != len(prompts):
        print(f"[WARN] names 数 ({len(names)}) 与 prompts 数 ({len(prompts)}) 不一致，按索引对齐")
    idx_to_id = {}
    for i, p in enumerate(prompts):
        cid = prompt_to_id.get(normalize_text(p))
        if cid is not None:
            idx_to_id[i] = cid

    def detect(paths):
        results = model.predict([str(p) for p in paths], imgsz=args.imgsz,
                                conf=args.conf, verbose=False)
        out = []
        for r in results:
            h, w = r.orig_shape[:2]
            raw: list[dict] = []
            if r.boxes is not None and len(r.boxes):
                for c_i, cf, box in zip(r.boxes.cls.tolist(),
                                        r.boxes.conf.tolist(),
                                        r.boxes.xywh.tolist()):
                    cid = idx_to_id.get(int(c_i))
                    if cid is None:
                        continue
                    raw.append({"class_id": cid, "conf": float(cf),
                                "bbox": yolo_to_xyxy(box, w, h),
                                "prompt": prompts[int(c_i)]})
            out.append((raw, w, h))
        return out

    return detect, {"teacher": "yoloworld", "weights": args.weights,
                    "imgsz": args.imgsz, "conf": args.conf,
                    "n_prompts": len(prompts)}


def make_gdino_detector(args, tax):
    """Grounding DINO 老师：**每类一次推理**（GDINO 不能一次发多个 prompt）。

    慢得多（提问词数 × 图数 次前向），这是正确性的代价，不能靠合并 prompt 省掉——
    多 prompt 会产出 `##cala stairs` / `estor` 这类破损标签（见 gdino_teacher 的说明）。

    与 YOLO-World 的两点结构差异都体现在这里：
    1. 阈值是**逐类**的 `gdin_threshold`，不是全局 `--conf`；
    2. 坐标取 PIL 的真实 W/H（YOLO 那边用 `orig_shape`），归一到同一约定。
    """
    import gdino_teacher as gd
    from PIL import Image

    queries = gd.queries_from_taxonomy(tax)

    # 同一条提问词只跑一次前向：通用类（obstacle/escalator）与具体类并存时
    # 可能共用提问词，重复前向纯属浪费。
    by_query: dict[str, list[dict]] = {}
    for q in queries:
        by_query.setdefault(q["query"], []).append(q)

    proc, model, src = gd.load(args.gdino_model or gd.DEFAULT_MODEL,
                               device=args.device, model_path=args.gdino_model)
    print(f"GDINO 权重：{src}（{len(by_query)} 条提问词 -> {len(queries)} 个类）")
    if len(by_query) != len(queries):
        shared = {q: [o["name_en"] for o in os_] for q, os_ in by_query.items() if len(os_) > 1}
        print(f"  共用提问词：{shared}")

    tstats = {"teacher": "gdino", "weights": src, "device": args.device,
              "n_queries": len(by_query), "n_classes": len(queries),
              "label_kind": Counter(), "label_samples": {},
              "failed_images": []}

    def detect(paths):
        out = []
        for p in paths:
            try:
                img = Image.open(p).convert("RGB")
            except Exception as e:  # noqa: BLE001
                # 读不了就整张跳过：写一个空标签文件等于伪造负样本，
                # 而项目的负样本是"确实没有该类目标"，两者语义完全不同。
                print(f"[WARN] 读图失败，跳过 {p}: {e}", flush=True)
                tstats["failed_images"].append(str(p))
                out.append(None)
                continue
            W, H = img.size
            raw: list[dict] = []
            for q, owners in by_query.items():
                # 先按最宽的门槛推理，再按各类自己的门槛筛，避免跑两遍
                hits = gd.infer(proc, model, img, q,
                                min(o["threshold"] for o in owners),
                                device=args.device)
                for hit in hits:
                    # ★ 框一律保留。类别 id 来自**我发出去的** query，不是返回的
                    # label，所以 label 再怎么破也不会错配到别的类。
                    # 这里曾经按「label != query」丢框，实测丢掉了 11% 的框，
                    # 而且系统性偏向多词提问词（= 最需要 GDINO 的描述型障碍物类）。
                    kind = gd.classify_label(q, hit["label"])
                    tstats["label_kind"][kind] += 1
                    if kind in ("artifact", "mismatch"):
                        tstats["label_samples"].setdefault(
                            f"{kind}:{q}->{hit['label']}", str(p))
                    for o in owners:
                        if hit["conf"] < o["threshold"]:
                            continue
                        raw.append({"class_id": o["class_id"], "conf": hit["conf"],
                                    "bbox": hit["bbox"], "prompt": q,
                                    "label": hit["label"]})
            out.append((raw, W, H))
        return out

    return detect, tstats


def label_path_for(labels_dir: Path, rel: str) -> Path:
    """`rel`（相对输入根的正斜杠路径）-> 标签文件路径，**逐级镜像**目录树。

    不要改成把子目录拍平成一个文件名（曾经用 `__` 连接过）。拍平之后
    X-AnyLabeling 按镜像路径去找标签会一个都找不到，而它的表现是
    「0 个实例」——不报错，看起来就像图里真的没东西。本项目已经踩过一次。
    """
    return labels_dir / Path(rel).with_suffix(".txt")


def image_path_for(images_dir: Path, rel: str) -> Path:
    """`rel` -> 复核包里图像的目标路径，与标签同构。"""
    return images_dir / Path(rel)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True, help="输入图像目录（递归）")
    ap.add_argument("--out", default="data/auto/proposals")
    ap.add_argument("--teacher", choices=["yoloworld", "gdino"], default="yoloworld",
                    help="yoloworld：快、一次出全类，但对结构性障碍物召回差；"
                         "gdino：每类一次推理、慢，但覆盖广（须在 .venv-vlm 里跑）")
    ap.add_argument("--weights", default="yolov8s-world.pt",
                    help="[yoloworld] yolov8s-world.pt（快）/ yolov8m-world.pt（更准）")
    ap.add_argument("--gdino-model", default=None,
                    help="[gdino] 本地权重目录；不给则从 HF 缓存取 grounding-dino-tiny")
    ap.add_argument("--device", default="cuda", help="[gdino] cuda / cpu")
    ap.add_argument("--imgsz", type=int, default=640, help="[yoloworld] 推理尺寸")
    ap.add_argument("--conf", type=float, default=0.15,
                    help="[yoloworld] 预标阶段门槛要低：宁可多留候选，由后两段筛掉。"
                         "gdino 用逐类 gdin_threshold，此参数无效")
    ap.add_argument("--iou-merge", type=float, default=0.55,
                    help="类内合并的 IoU 阈值")
    ap.add_argument("--batch", type=int, default=16,
                    help="[yoloworld] 批量前向的张数；gdino 逐张推理，此参数只影响进度打印频率")
    ap.add_argument("--limit", type=int, default=None, help="只处理前 N 张（试跑用）")
    ap.add_argument("--no-labels", action="store_true",
                    help="只写 proposals.jsonl，不写 YOLO 标签文件")
    ap.add_argument("--stage-images", action="store_true",
                    help="把图像复制进 <out>/images/（镜像输入目录树），"
                         "使 <out> 成为自成一体的复核包："
                         "images/ 与 labels/ 路径一一对应，直接 "
                         "label.cmd -Images <out>\\images 就能打开改框。"
                         "注：写进 <out> 而不是原图目录 —— 老师草稿不能混进源素材，"
                         "否则以后会把它当成人工真值")
    args = ap.parse_args()

    images_root = (REPO_ROOT / args.images) if not Path(args.images).is_absolute() else Path(args.images)
    if not images_root.exists():
        print(f"输入目录不存在：{images_root}")
        return 1
    images = find_images(images_root)
    if args.limit:
        images = images[: args.limit]
    if not images:
        print(f"未在 {images_root} 找到图像。")
        return 1

    out_dir = REPO_ROOT / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    tax = LabelTaxonomy()
    if args.teacher == "yoloworld":
        prompts = tax.yolo_world_prompts()
        prompt_to_id = tax.prompt_to_id()
        print(f"类别 {len(tax.classes)} 个，prompt 说法 {len(prompts)} 条")
    else:
        prompts, prompt_to_id = [], {}
        print(f"类别 {len(tax.classes)} 个（gdino 逐类提问）")
    print(f"图像 {len(images)} 张 -> {images_root.relative_to(REPO_ROOT)}")

    if args.teacher == "yoloworld":
        detect, teacher_stats = make_yoloworld_detector(args, prompts, prompt_to_id)
    else:
        if args.conf != ap.get_default("conf"):
            print(f"[注意] --conf {args.conf} 对 gdino 无效，"
                  f"用的是各类自己的 gdin_threshold")
        detect, teacher_stats = make_gdino_detector(args, tax)

    t0 = time.time()
    n_images = 0
    n_boxes_raw = 0
    n_boxes_kept = 0
    class_hits: Counter[int] = Counter()
    img_with_class: dict[int, set[str]] = {}

    jsonl_path = out_dir / "proposals.jsonl"
    labels_dir = out_dir / "labels"
    images_dir = out_dir / "images"
    if not args.no_labels:
        labels_dir.mkdir(parents=True, exist_ok=True)
    if args.stage_images:
        images_dir.mkdir(parents=True, exist_ok=True)

    # gdino 每张图要跑 N 条提问词，几十秒才一张，所以逐张报进度
    report_every = 1 if args.teacher == "gdino" else 80

    with jsonl_path.open("w", encoding="utf-8") as jf:
        for start in range(0, len(images), args.batch):
            chunk = images[start:start + args.batch]
            for path, got in zip(chunk, detect(chunk)):
                if got is None:          # 读图失败：整张跳过，见 make_gdino_detector
                    continue
                raw, w, h = got
                n_boxes_raw += len(raw)

                # 类内合并
                by_class: dict[int, list[dict]] = {}
                for d in raw:
                    by_class.setdefault(d["class_id"], []).append(d)
                merged: list[dict] = []
                for cid, dets in by_class.items():
                    for d in nms_same_class(dets, args.iou_merge):
                        # 「多少个 prompt 说法都指向这一处」
                        # 注意是**去重后的说法数**，不是同类别框数：
                        # yoloworld 下一个类的多条别名会各出一批重叠框，
                        # 数框数会把它放大成十几，读起来像是十几个说法同意。
                        # gdino 每类只有一条提问词，所以恒为 1 —— 这是对的。
                        d["n_prompts"] = len({x.get("prompt", "") for x in dets})
                        merged.append(d)
                merged.sort(key=lambda d: d["conf"], reverse=True)
                n_boxes_kept += len(merged)
                for d in merged:
                    class_hits[d["class_id"]] += 1
                    img_with_class.setdefault(d["class_id"], set()).add(str(path))

                rel = path.relative_to(images_root).as_posix()
                jf.write(json.dumps({
                    "image": rel, "source": str(path), "width": w, "height": h,
                    "detections": merged,
                }, ensure_ascii=False) + "\n")

                if not args.no_labels:
                    lines = []
                    for d in merged:
                        x1, y1, x2, y2 = d["bbox"]
                        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
                        bw, bh = x2 - x1, y2 - y1
                        lines.append(f"{d['class_id']} {cx:.6f} {cy:.6f} {bw:.6f} {bh:.6f}")
                    # ★ 标签路径必须**逐级镜像**输入目录树，不能把子目录拍平。
                    # 拍平过（用 `__` 连接）会导致 X-AnyLabeling 找不到标签，
                    # 而它的表现是「0 个实例」——不报错，看起来就像图里真没东西。
                    # 这个坑本项目已经踩过一次，不要再踩。
                    lp = label_path_for(labels_dir, rel)
                    lp.parent.mkdir(parents=True, exist_ok=True)
                    # 空标签也要写：空文件是有效的负样本，与"缺文件"语义不同
                    lp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
                if args.stage_images:
                    # 复核包：images/ 与 labels/ 同级且路径一一对应，
                    # 这样一条命令就能用 label.ps1 打开，不用手工搬文件。
                    ip = image_path_for(images_dir, rel)
                    ip.parent.mkdir(parents=True, exist_ok=True)
                    if not ip.exists():
                        shutil.copy2(path, ip)
                n_images += 1

            done = min(start + args.batch, len(images))
            if done % report_every == 0 or done == len(images):
                rate = done / max(time.time() - t0, 1e-9)
                print(f"  {done}/{len(images)}  ({rate:.1f} img/s)", flush=True)

    elapsed = time.time() - t0
    stats = {
        "images": n_images,
        "boxes_raw": n_boxes_raw,
        "boxes_after_merge": n_boxes_kept,
        "elapsed_s": round(elapsed, 1),
        "img_per_s": round(n_images / elapsed, 2) if elapsed else None,
        "iou_merge": args.iou_merge,
        "per_class": {
            str(c["id"]): {
                "name_en": c["name_en"], "name_zh": c["name_zh"],
                "boxes": class_hits.get(c["id"], 0),
                "images": len(img_with_class.get(c["id"], ())),
            }
            for c in tax.classes
        },
    }
    # 老师的记录整体并入：imgsz/conf/weights 由老师自己写，
    # 免得 gdino 跑完后统计文件里还挂着一个它根本没用的 imgsz=640。
    stats.update(teacher_stats)
    if isinstance(stats.get("label_kind"), Counter):
        stats["label_kind"] = dict(stats["label_kind"])
    (out_dir / "proposals_stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n完成：{n_images} 张，{elapsed:.1f}s（{stats['img_per_s']} img/s）")
    print(f"框：原始 {n_boxes_raw} -> 类内合并后 {n_boxes_kept}")
    kinds = teacher_stats.get("label_kind")
    if kinds:
        print(f"返回标签：{dict(kinds)}"
              f"（subspan = 匹配到提问句的片段，属正常，见 gdino_teacher.classify_label）")
        if kinds.get("artifact"):
            print(f"[WARN] {kinds['artifact']} 个框含 `##` WordPiece 残留 —— 真 tokenizer 破损")
        for k, v in list(teacher_stats.get("label_samples", {}).items())[:8]:
            print(f"    可疑样本 {k}  例图 {v}")
    if teacher_stats.get("failed_images"):
        print(f"[WARN] {len(teacher_stats['failed_images'])} 张图读取失败、整张跳过，"
              f"见 proposals_stats.json 的 failed_images")
    print(f"\n{'id':>3} {'类别':<24} {'框数':>7} {'出现图数':>8}")
    for cid in sorted(int(k) for k in stats["per_class"]):
        e = stats["per_class"][str(cid)]
        if e["boxes"]:
            print(f"{cid:>3} {e['name_en']:<24} {e['boxes']:>7} {e['images']:>8}")
    zero = [stats["per_class"][str(c["id"])]["name_en"] for c in tax.classes
            if not stats["per_class"][str(c["id"])]["boxes"]]
    if zero:
        print(f"\n零框类别（{len(zero)}）：{', '.join(zero)}")
    print(f"\n候选框：{jsonl_path.relative_to(REPO_ROOT)}")
    print(f"统计  ：{(out_dir / 'proposals_stats.json').relative_to(REPO_ROOT)}")
    if not args.no_labels:
        print(f"标签  ：{labels_dir.relative_to(REPO_ROOT)}  （第一段草稿，未经复核）")
    if args.stage_images:
        print(f"复核包：{images_dir.relative_to(REPO_ROOT)}"
              f"  →  .\\label.cmd -Images {images_dir.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
