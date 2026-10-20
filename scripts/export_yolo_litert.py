"""把一個 YOLO 模型匯出成 LiteRT（`.tflite`）——**最小用法示範**。

## 它與 `export_tflite.py` 的差別（先看這個再決定用哪個）

| | `export_yolo_litert.py`（本檔） | `export_tflite.py` |
|---|---|---|
| 用途 | 快速試一個模型**能不能匯出** | **正式部署**一條龍 |
| 產出 | 一個 `.tflite` | float32 + int8、張量形狀校驗、模型清單、可選寫入 assets |
| 參數 | 檔案內寫死 | 命令列（weights / imgsz / deploy / copy-to-assets） |
| 類別映射 | **不處理** | 從訓練資料集的 `classes.json` 生成 |

**要部署到手機上就用 `export_tflite.py`，不要用這支。**
這支的價值是：當 `export_tflite.py` 因為版本護欄或流水線問題失敗時，
可以用最少的環節確認「模型本身到底能不能匯出」。

## ⚠️ 在 Windows 上的硬限制（已實測，不是推測）

`ultralytics >= 8.4.83` 起，`format='tflite'` 被重定向到新的 **litert** 匯出器，
而它**只支援 Linux x86 / macOS**。在 Windows 上會直接斷言失敗：

    assert MACOS or (LINUX and not ARM64), "LiteRT export only supported on Linux x86 and macOS"

`scripts/export_tflite.py` 有對應的版本護欄（會提早說清楚並要求降級），
但**它只擋 `export_tflite.py` 自己**。直接呼叫 `model.export(format='litert')`
（也就是本檔的做法）會直接撞上那個斷言。

所以：

- **本機（Windows）要匯出 TFLite，必須用 `ultralytics < 8.4.83`**
  （本專案 `.venv-export` 是 8.3.253，就是這個原因）
- 升級到 8.4.x 是為了**訓練** YOLO26（8.3.253 的 `SPPF` 簽名吃不下 YOLO26 的
  `model.yaml`），不是為了匯出
- 訓練環境（`.venv`）與匯出環境（`.venv-export`）在本專案是**分開的**

## ★ 但「分開」救不了 YOLO26（已實測）

原本以為「在 `.venv` 訓、用 `.venv-export` 匯出」就能繞過，
**實測不成立**。把 8.4.174 訓出來的 `pg_b_yolo26n/weights/best.pt`
載進 `.venv-export`（8.3.253）：

```
載入 checkpoint:                                    OK
從 model.yaml 重建 (DetectionModel(m.model.yaml)):  FAILED
  TypeError: SPPF.__init__() takes from 3 to 4 positional arguments but 6 were given
```

**`.train()` 與 `.export()` 都會從 `model.yaml` 重建模型**，
所以 8.3.253 對 YOLO26 是「能載入、不能用」——訓練與匯出都一樣。

**結論：YOLO26 在這台 Windows 機器上目前無法產出可上機的 `.tflite`。**
可選路徑見 `docs/MODELS.md`；要嘛把 `.venv-export` 升到
`8.4.x` 且 `< 8.4.83`（尚未實測那個區間是否還支援 Windows 匯出），
要嘛在 Linux x86 / macOS 上匯出。

## 用法

    # 直接跑（參數在下面 MAIN 區塊改）
    python scripts/export_yolo_litert.py

改模型只要改 `WEIGHTS`；`IMGSZ` 預設 416，與部署端一致
（分類任務用 224）。
"""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# ---- 要在這裡改的參數 ----
WEIGHTS = REPO_ROOT / "weights" / "yolo26n.pt"
IMGSZ = 416


def main() -> int:
    from ultralytics import YOLO

    if not WEIGHTS.exists():
        print(f"找不到權重：{WEIGHTS}")
        print("（若剛換過模型，先確認路徑。本專案的預訓練權重放在 weights/）")
        return 2

    print(f"權重   {WEIGHTS}")
    print(f"輸出尺寸 imgsz={IMGSZ}")
    print("格式   litert  ← 注意：Windows 上不支援，見本檔開頭的說明\n")

    model = YOLO(str(WEIGHTS))
    out = model.export(format="litert", imgsz=IMGSZ)

    p = Path(out)
    print(f"\n產出 {p}")
    if p.exists():
        print(f"體積 {p.stat().st_size / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
