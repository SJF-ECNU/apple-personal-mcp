# App 图标生成记录

生成方式：内置 GPT Image（imagegen），2026-10-27。用户选定的简约入口方案。

源图：[AppIcon.png](../../Resources/AppIcon.png)。使用 `Scripts/build-icon.sh` 生成 ICNS；仅做系统图标尺寸转换，保留原始图形与透明度。

实际提示词：

```text
Use case: logo-brand.
Design ONE original, extremely minimal macOS app icon for Apple Personal MCP, an app that gives AI agents a unified entry into a user's Mac workspace.

The user wants simplicity and abstraction. Do not depict individual applications or their icons. Do not make an infographic. The concept is "one quiet entry point into a personal workspace."

Composition: square canvas with genuine transparent outer margins. A centered near-black rounded-square macOS tile occupies about 84% of the canvas. The tile is matte graphite (#171719), with only the faintest edge definition. Absolutely no glossy bevel, no chunky 3D plastic, no chrome and no strong shadow.

The tile contains ONE custom pearl-white geometric emblem. Design this emblem as a stylized open workspace frame: a softly rounded rectangular outline, with a deliberate opening at the middle of its LEFT edge. A short, bold right-facing chevron enters through that opening. The chevron is a geometric stroke, not typed text, and its proportions, stroke width, and corner treatment match the frame so that together they feel like one compact original glyph. This combines the suggestion of a Mac workspace with an agent command/entry gesture. The emblem must be beautifully balanced and immediately legible at 16–32 pixels.
Use just a few clean strokes and generous negative space. Stroke weight should be substantial and consistent, with softly rounded ends, not thin hairlines. The whole emblem should occupy around 52–58% of the tile width. Precisely optically center it.

Visual character: sophisticated, understated, native Mac, near-flat monochrome, sharp clean graphic edges, strong silhouette. Make the symbol feel like a considered piece of graphic design rather than a stock chain-link icon or a literal terminal screenshot.

Only two main tones: near-black and warm off-white (#F5F5F2). No colored accents.
No application glyphs, no six-item grid, no envelope, calendar, checklist, notebook, chat bubbles, or waveform. No robots, faces, sparkles, brain, network nodes, chain links, infinity signs, letter monograms, words, typography, dots, window buttons, or extra symbols. No title. No scene, mockup, or presentation. The final image is the single icon itself with real transparent space outside the rounded tile.
```

喵～
