#!/usr/bin/env python3
"""Export the design documentation from the owning AppKit implementation."""
import json
import re
from pathlib import Path

SYSTEM = Path(__file__).resolve().parents[1]
REPOSITORY = SYSTEM.parents[1]
WINDOW = REPOSITORY / "Sources/AndroidUse/ManagementWindow.swift"
VISUALS = REPOSITORY / "Sources/AndroidUse/ManagementVisuals.swift"
window_source = WINDOW.read_text()
visual_source = VISUALS.read_text()


def kebab(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()


def number(value):
    if not re.fullmatch(r"[0-9. /+-]+", value):
        raise ValueError(f"Unsupported numeric literal: {value}")
    return float(eval(value, {"__builtins__": {}}, {}))


def color(expression):
    expression = re.sub(r"\s+", "", expression)
    hex_value = re.fullmatch(r"hex\(0x([A-Fa-f0-9]{6})\)", expression)
    if hex_value:
        return "#" + hex_value[1].lower()
    white = re.fullmatch(r"NSColor.white.withAlphaComponent\(([0-9.]+)\)", expression)
    if white:
        return f"rgba(255, 255, 255, {white[1]})"
    rgba = re.fullmatch(r"NSColor\(srgbRed:(.*?),green:(.*?),blue:(.*?),alpha:(.*?)\)", expression)
    if rgba:
        r, g, b, a = [number(v) for v in rgba.groups()]
        return f"rgba({r * 255:g}, {g * 255:g}, {b * 255:g}, {a:g})"
    raise ValueError(f"Unsupported color expression: {expression}")


def themed(expression):
    expression = expression.strip()
    if not expression.startswith("isDark"):
        return color(expression)
    branches = expression[expression.index("?") + 1:]
    depth = 0
    for index, character in enumerate(branches):
        depth += (character == "(") - (character == ")")
        if character == ":" and depth == 0:
            return {"dark": color(branches[:index]), "light": color(branches[index + 1:])}
    raise ValueError("Missing theme branch")


usages = {
    "bg": "窗口底色；与 canvas 一起形成层级。",
    "canvas": "主工作区底色，承载卡片和页面标题。",
    "card": "列表、设置、状态和诊断卡片底色。",
    "card2": "次级控件底色，承载 ink 与 ink2。",
    "ink": "canvas、card、card2 上的主要文字。",
    "ink2": "canvas、card、card2 上的次要文字。",
    "ink3": "canvas、card、card2 上的说明和注释；不可再降低透明度。",
    "sidebar-ink": "深蓝侧栏上的选中导航与标题。",
    "sidebar-ink2": "深蓝侧栏上的未选中导航与快捷入口。",
    "sidebar-accent": "选中导航图标；与文字和选中底板共同表达状态。",
    "sidebar-selection": "侧栏选中态的通透底板，叠在深蓝背景上。",
    "sidebar-selection-line": "侧栏选中底板的装饰高光，不能单独承载状态。",
    "surface-hover": "次级按钮的悬停叠层，叠在 card/card2 上。",
    "line": "卡片内部的装饰性分隔线；不作为唯一控件边界。",
    "seam-line": "工作区外缘分界。",
    "accent": "card 上的链接、图标和强调色。",
    "accent-fill": "主要操作填充色；仅搭配 on-fill。",
    "accent-pressed": "主要操作悬停/按下填充色；仅搭配 on-fill。",
    "accent-ink": "accent-soft 和强调悬停叠层上的文字。",
    "accent-soft": "列表中的打开按钮等常规强调操作底色，搭配 accent-ink。",
    "positive": "positive-soft 或 card 上的成功文字；始终附明确状态词。",
    "positive-soft": "成功状态标签底色，搭配 positive。",
    "positive-fill": "启动操作填充色，搭配 on-fill。",
    "positive-pressed": "启动操作按下填充色，搭配 on-fill。",
    "warn": "warn-soft 或 card 上的提醒文字；始终附文字。",
    "warn-soft": "提醒状态标签底色，搭配 warn。",
    "danger": "danger-soft 或 card 上的错误、悬停卸载文字；始终附文字。",
    "danger-soft": "错误标签或破坏性操作悬停底色，搭配 danger。",
    "danger-fill": "停止操作填充色，搭配 on-fill。",
    "danger-pressed": "停止操作按下填充色，搭配 on-fill。",
}
colors = []
theme_body = window_source.split("enum TFTheme {", 1)[1].split("static func hex", 1)[0]
for match in re.finditer(r"static var (\w+): NSColor \{(.*?)\}", theme_body, re.S):
    native_name, expression = match.groups()
    name = kebab(native_name)
    colors.append({"name": name, "value": themed(expression), "usage": usages[name],
                   "source": {"path": "Sources/AndroidUse/ManagementWindow.swift", "symbol": f"TFTheme.{native_name}"}})
colors.append({"name": "on-fill", "value": "#ffffff", "usage": "accent-fill、positive-fill、danger-fill 及其按下态上的文字。",
               "source": {"path": "Sources/AndroidUse/ManagementWindow.swift", "symbol": "TFButton.refreshColors / TFRuntimeControlButton.draw"}})

palette = visual_source.split("private enum ManagementVisualPalette {", 1)[1].split("\n}", 1)[0]
for match in re.finditer(r"static let (\w+) = (NSColor\([^\n]+\))", palette):
    native_name, expression = match.groups()
    colors.append({"name": "scene-" + kebab(native_name), "value": color(expression),
                   "usage": "自绘平板与侧栏材质的内部配色，仅作装饰，不承载文字。",
                   "source": {"path": "Sources/AndroidUse/ManagementVisuals.swift", "symbol": f"ManagementVisualPalette.{native_name}"}})


def token(name, value, usage):
    return {"name": name, "value": value, "usage": usage}


styles = [
    {"name": "page-title", "fontSize": "21px", "lineHeight": "28px", "fontWeight": 600, "usage": "固定标题区，仅一个页面标题。"},
    {"name": "runtime-title", "fontSize": "15px", "lineHeight": "21px", "fontWeight": 600, "usage": "运行环境卡片的当前状态。"},
    {"name": "row-title", "fontSize": "14.5px", "lineHeight": "20px", "fontWeight": 500, "usage": "应用或插件的名称。"},
    {"name": "section-title", "fontSize": "14px", "lineHeight": "20px", "fontWeight": 600, "usage": "设置分组标题。"},
    {"name": "setting-title", "fontSize": "13.5px", "lineHeight": "19px", "fontWeight": 500, "usage": "设置项目名称。"},
    {"name": "body", "fontSize": "12.5px", "lineHeight": "18px", "fontWeight": 400, "usage": "页面说明与应用副标题。"},
    {"name": "caption", "fontSize": "12px", "lineHeight": "17px", "fontWeight": 400, "usage": "设置说明和状态指标说明。"},
    {"name": "control-label", "fontSize": "12px", "lineHeight": "17px", "fontWeight": 500, "usage": "小型原生按钮。"},
    {"name": "badge-label", "fontSize": "11px", "lineHeight": "15px", "fontWeight": 500, "usage": "状态标签。"},
    {"name": "metric-value", "fontSize": "20px", "lineHeight": "26px", "fontWeight": 600, "usage": "资源指标，数字等宽；无样本时显示 —。"},
]
tokens = {
    "name": "Macdora", "version": 1,
    "meta": {"source": {"kind": "native-code", "paths": ["Sources/AndroidUse/ManagementWindow.swift", "Sources/AndroidUse/ManagementVisuals.swift"]},
             "role": "Macdora implementation tokens; CleanMyMac observations are recorded separately in REFERENCE.md.",
             "typography": "Native font sizes are points. CSS uses the same numeric values as CSS px for documentation, not physical screenshot pixels. Native line heights follow AppKit metrics; CSS line heights are documentation choices."},
    "color": {"themes": [{"id": "dark", "name": "深色"}, {"id": "light", "name": "浅色"}], "tokens": colors},
    "type": {"fonts": [], "families": {"sans": '-apple-system, BlinkMacSystemFont, "PingFang SC", system-ui, sans-serif'},
             "groups": [{"name": "原生文字层级", "family": "sans", "styles": styles}]},
    "spacing": {"tokens": [token(f"space-{n}", f"{n}px", usage) for n, usage in [(4, "文字与辅助信息之间。"), (8, "同组控件之间。"), (12, "图标与正文之间。"), (16, "卡片内部横向留白。"), (18, "页面卡片之间，沿用原生布局。"), (24, "标题区顶部留白。"), (32, "主工作区左右最小留白。")]]},
    "radius": {"tokens": [token("radius-badge", "6px", "状态标签。"), token("radius-button", "8px", "小型按钮与分段控件。"), token("radius-nav", "9px", "侧栏选中底板。"), token("radius-compact", "10px", "紧凑状态卡与指标卡。"), token("radius-card", "12px", "应用、设置与插件卡片。") ]},
    "shadow": {"tokens": [token("shadow-card", {"dark": "0 1px 2px rgba(0, 0, 0, 0.22)", "light": "0 1px 2px rgba(0, 0, 0, 0.03)"}, "原生卡片阴影在 CSS 中的视觉映射；CALayer radius/offset 见生产代码。") ]},
    "duration": {"tokens": [token("duration-page", "200ms", "用户切页时淡入与 3pt 轻微位移。"), token("duration-scene", "450ms", "平板主视觉入场。"), token("duration-busy", "480ms", "真实忙碌状态的光晕提示，最多两轮。") ]},
    "easing": {"tokens": [token("ease-standard", "cubic-bezier(0, 0, 0.58, 1)", "页面和设备入场；对应 CoreAnimation easeOut。"), token("ease-pulse", "cubic-bezier(0.42, 0, 0.58, 1)", "忙碌提示；对应 CoreAnimation easeInEaseOut。") ]},
}

css = ["/* Macdora — generated from tokens.json */"]
themes = [theme["id"] for theme in tokens["color"]["themes"]]
for index, theme in enumerate(themes):
    css.append((":root, " if index == 0 else "") + f'[data-theme="{theme}"] {{')
    for entry in colors + tokens["shadow"]["tokens"]:
        value = entry["value"]
        css.append(f'  --{entry["name"]}: {value[theme] if isinstance(value, dict) else value};')
    css.append("}")
css.append(":root {")
for family in ["spacing", "radius", "duration", "easing"]:
    for entry in tokens[family]["tokens"]:
        css.append(f'  --{entry["name"]}: {entry["value"]};')
css.append(f'  --font-sans: {tokens["type"]["families"]["sans"]};')
css.append("}")
for style in styles:
    css.append(f'.{style["name"]} {{ font-family: var(--font-sans); font-size: {style["fontSize"]}; line-height: {style["lineHeight"]}; font-weight: {style["fontWeight"]}; }}')
css.append(".metric-value { font-variant-numeric: tabular-nums; }")
(SYSTEM / "tokens.json").write_text(json.dumps(tokens, ensure_ascii=False, indent=2) + "\n")
(SYSTEM / "tokens.css").write_text("\n".join(css) + "\n")
print(f"Exported {len(colors)} colors, {len(styles)} typography styles, 2 themes.")
