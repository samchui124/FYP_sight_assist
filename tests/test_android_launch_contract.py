"""Android 启动契约：应用 label 必须本地化，且所有 `@string/` 引用必须可解析。

## 为什么值得钉住

**语音启动靠应用 label 匹配。** Assistant / Siri 找 App 用的是 label 字面，
所以 label 必须随系统语言变化。原来 manifest 里硬编码 `android:label="領路通"`，
后果是：系统语言为英文的视障用户必须**念中文**才能启动，而他不可能知道这件事。
（这条来自 `docs/A11Y-ENTRY-AND-AUTH.md` §2.2。）

**`@string/` 解析失败是构建期错误，不是运行期。** manifest 里写了
`@string/app_name` 而某个 `values-*` 里没有它，Gradle 直接失败。
所以引用的字符串**必须**在默认 `values/` 里存在（其余语言是可选覆盖）。

这一类「配置写错却只有构建时才报」的问题，正是本仓库一贯用测试钉死的对象。
"""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
ANDROID_MAIN = REPO_ROOT / "app" / "android" / "app" / "src" / "main"
MANIFEST = ANDROID_MAIN / "AndroidManifest.xml"
RES = ANDROID_MAIN / "res"

ANDROID_NS = "http://schemas.android.com/apk/res/android"

# 应用名在英文系统下必须是拉丁字母：否则英文语音用户无法用英文念出它
DEFAULT_APP_NAME = "PathGuide"
# 繁体以「領」开头、简体以「领」开头（繁简必须真的不同，别复制粘贴忘了改）
TRADITIONAL_APP_NAME = "領路通"
SIMPLIFIED_APP_NAME = "领路通"

# 期望存在的本地化目录 -> 期望的 app_name
EXPECTED_LOCALES = {
    "values": DEFAULT_APP_NAME,
    "values-zh-rHK": TRADITIONAL_APP_NAME,
    "values-zh-rTW": TRADITIONAL_APP_NAME,
    "values-zh-rCN": SIMPLIFIED_APP_NAME,
}


@pytest.fixture(scope="module")
def manifest_root():
    assert MANIFEST.exists(), f"找不到 manifest：{MANIFEST}"
    return ET.parse(MANIFEST).getroot()


def _string_values(locale_dir: str) -> dict[str, str]:
    """读某个 values 目录下的 strings.xml -> {name: value}。"""
    path = RES / locale_dir / "strings.xml"
    if not path.exists():
        return {}
    root = ET.parse(path).getroot()
    return {el.get("name"): (el.text or "") for el in root.findall("string")}


# ---- manifest 本身 ----

def test_manifest_is_well_formed():
    """XML 是否良构只能靠解析，肉眼看不出（缺一个引号就整个构建挂掉）。"""
    ET.parse(MANIFEST)


def test_manifest_xml_files_are_all_well_formed():
    """res/ 下每个 XML 都要能解析。"""
    bad = []
    for p in RES.rglob("*.xml"):
        try:
            ET.parse(p)
        except ET.ParseError as e:
            bad.append(f"{p.relative_to(RES)}: {e}")
    assert not bad, "以下资源 XML 解析失败：\n" + "\n".join(bad)


def test_label_uses_a_string_resource_not_a_hardcoded_name(manifest_root):
    """★ 核心断言：label 不能硬编码。

    硬编码 = 语音启动只在一种语言下可用，而这恰恰是盲人打开 App 的主要方式之一。
    """
    app = manifest_root.find("application")
    assert app is not None
    label = app.get(f"{{{ANDROID_NS}}}label")
    assert label == "@string/app_name", (
        f"application@android:label 应为 @string/app_name，实际是 {label!r}。"
        "硬编码会让语音启动只在一种语言下可用（见 docs/A11Y-ENTRY-AND-AUTH.md §2.2）"
    )


# ---- 字符串资源 ----

@pytest.mark.parametrize("locale_dir,expected", sorted(EXPECTED_LOCALES.items()))
def test_each_locale_defines_app_name(locale_dir, expected):
    got = _string_values(locale_dir).get("app_name")
    assert got == expected, f"{locale_dir}/strings.xml 的 app_name 应为 {expected!r}，实际 {got!r}"


def test_default_locale_is_latin_script():
    """默认值必须是拉丁字母。

    英文系统的语音用户念不出「領路通」，所以默认（英文）这一份必须是 PathGuide。
    """
    default = _string_values("values").get("app_name", "")
    assert default.isascii(), f"默认 app_name 必须能用英文念出，实际 {default!r}"


def test_traditional_and_simplified_actually_differ():
    """繁体简体要真的不同。复制粘贴忘了改是这类资源最常见的错误。"""
    tw = _string_values("values-zh-rTW").get("app_name", "")
    cn = _string_values("values-zh-rCN").get("app_name", "")
    assert tw != cn, "繁體與簡體的 app_name 相同，應為「領路通」與「领路通」"


def test_app_name_has_no_em_dash():
    """emoji/dash 会让 TTS 读得奇怪，也会让语音匹配失准。"""
    for locale_dir in EXPECTED_LOCALES:
        for name, value in _string_values(locale_dir).items():
            assert "—" not in value and "–" not in value, f"{locale_dir}/{name} 含 em dash"


def test_app_name_is_not_a_generic_word():
    """别用会与系统应用抢语音匹配的泛用词。"""
    banned = {"导航", "地圖", "地图", "相機", "相机", "助手", "設定", "设置"}
    for locale_dir in EXPECTED_LOCALES:
        value = _string_values(locale_dir).get("app_name", "")
        assert value not in banned, f"{locale_dir} 的 app_name 是泛用詞 {value!r}，會與系統應用搶語音匹配"


# ---- 引用完整性（构建期风险）----

def test_every_string_reference_in_manifest_resolves(manifest_root):
    """manifest 里每个 `@string/x` 都必须在默认 values/ 里存在。

    缺一个就是 Gradle 构建失败（`resource string/x not found`），
    而在那之前没有别的环节会报错。
    """
    text = MANIFEST.read_text(encoding="utf-8")
    referenced = set(re.findall(r"@string/([A-Za-z0-9_]+)", text))
    assert referenced, "manifest 里居然没有 @string/ 引用？label 可能又被硬编码了"

    available = set(_string_values("values"))
    missing = sorted(referenced - available)
    assert not missing, f"manifest 引用了但 values/strings.xml 里没有：{missing}"


def test_every_locale_string_file_is_reachable_by_reference_scan():
    """反向检查：默认 values/ 之外的字符串文件也必须是良构且非空。

    空文件通常意味着「建了目录忘了写内容」，而它的表现是那个语言静默回落英文，
    不会报错。
    """
    for locale_dir in EXPECTED_LOCALES:
        path = RES / locale_dir / "strings.xml"
        assert path.exists(), f"缺少 {locale_dir}/strings.xml"
        assert _string_values(locale_dir), f"{locale_dir}/strings.xml 没有任何 <string>"


# ---- 快速設定磁貼（Quick Settings tile）----
#
# 為什麼磁貼要單獨一組測試：磁貼的三個 manifest 屬性**任何一個寫錯**，
# 結果都是「磁貼清單裡根本找不到它」，而且系統不會給任何錯誤訊息。
# 這種「靜默不生效」正好是本倉庫一貫用測試釘死的對象。

TILE_SERVICE = "PathGuideTileService"
QS_TILE_ACTION = "android.service.quicksettings.action.QS_TILE"
BIND_TILE_PERMISSION = "android.permission.BIND_QUICK_SETTINGS_TILE"


@pytest.fixture(scope="module")
def tile_service(manifest_root):
    for svc in manifest_root.findall("application/service"):
        if svc.get(f"{{{ANDROID_NS}}}name", "").endswith(TILE_SERVICE):
            return svc
    pytest.fail(
        f"manifest 裡找不到 {TILE_SERVICE}。沒有它的話 App 只能靠桌面圖示啟動，"
        "而對全盲使用者那是線性搜尋，很慢（見 docs/A11Y-ENTRY-AND-AUTH.md 第 2 節）"
    )


def test_tile_service_declares_bind_permission(tile_service):
    """缺這個 permission，系統不會綁定磁貼，而且不會報錯。"""
    assert tile_service.get(f"{{{ANDROID_NS}}}permission") == BIND_TILE_PERMISSION


def test_tile_service_is_exported(tile_service):
    """磁貼是由 SystemUI（另一個程式）綁定的，所以必須 exported。"""
    assert tile_service.get(f"{{{ANDROID_NS}}}exported") == "true"


def test_tile_service_has_qs_tile_intent_filter(tile_service):
    """系統靠這個 action 把服務列進可用磁貼清單。"""
    actions = {
        a.get(f"{{{ANDROID_NS}}}name")
        for f in tile_service.findall("intent-filter")
        for a in f.findall("action")
    }
    assert QS_TILE_ACTION in actions, f"缺少 {QS_TILE_ACTION}，磁貼不會出現在清單裡"


def test_tile_icon_resource_exists(tile_service):
    """manifest 指到的 drawable 必須真的在 res/ 裡（否則建構期失敗）。"""
    icon = tile_service.get(f"{{{ANDROID_NS}}}icon", "")
    assert icon.startswith("@drawable/"), f"磁貼 icon 應指向 drawable，實際 {icon!r}"
    assert (RES / "drawable" / f"{icon.split('/', 1)[1]}.xml").exists(), f"{icon} 不存在"


def test_tile_label_is_localised_in_every_locale(tile_service):
    """磁貼標籤與 app_name 一樣要跟隨系統語言。

    標籤是全盲使用者唯一會聽到的字，硬編碼等於只在一個語言下可用。
    """
    label = tile_service.get(f"{{{ANDROID_NS}}}label")
    assert label == "@string/tile_label", f"磁貼 label 應為 @string/tile_label，實際 {label!r}"
    for locale_dir in EXPECTED_LOCALES:
        assert _string_values(locale_dir).get("tile_label"), f"{locale_dir} 缺少 tile_label"


def test_tile_label_is_an_action_not_the_app_name():
    """★ 磁貼標籤必須寫「動作」，不能寫成 App 名字。

    理由：磁貼標籤是全盲使用者唯一聽到的字。若只寫「PathGuide」或「領路通」，
    他在有幾十個磁貼的清單裡聽到的是一個名字而不是一個動作，無從判斷用途。
    這條測試是為了擋住「順手讓它跟 app_name 一樣」這種看起來無害的簡化。
    """
    for locale_dir in EXPECTED_LOCALES:
        values = _string_values(locale_dir)
        assert values.get("tile_label") != values.get("app_name"), (
            f"{locale_dir} 的 tile_label 與 app_name 相同。"
            "磁貼標籤要說明「會發生什麼」，不是「這是哪個 App」"
        )


def test_tile_service_kotlin_uses_start_activity_and_collapse():
    """從 TileService 啟動 Activity 必須用 startActivityAndCollapse。

    用 `startActivity` 會被系統當成背景啟動而擋掉，**表現是磁貼按了沒反應**，
    同樣沒有錯誤訊息。這條測試不檢查語法（那個交給
    scripts/check_kotlin_compiles.py 與 Gradle），只確認呼叫的是正確的 API 名。
    """
    kt = (ANDROID_MAIN / "kotlin" / "hk" / "pathguide" / "pathguide"
          / f"{TILE_SERVICE}.kt")
    assert kt.exists(), f"找不到 {kt}"
    src = kt.read_text(encoding="utf-8")
    assert "startActivityAndCollapse" in src, "應使用 startActivityAndCollapse，不是 startActivity"
    assert "TileService" in src, "應繼承 TileService"
