# Poliwhirl menu bar artwork

Each folder contains the editable AppKit drawing and its original light and dark preview. Each preview shows the ready, speaking, paused, and muted states from left to right.

| Version | Date | Change |
| --- | --- | --- |
| [Original](original/preview.png) | September 10, 2026 | First menu bar drawings with a spiral belly and raised eyes. |
| [Mouth](mouth/preview.png) | September 10, 2026 | Different mouth shapes identify each speech state. |
| [Muted](muted/preview.png) | September 22, 2026 | The muted state gains a red zipped mouth and a red ×. |
| [Paused](paused/preview.png) | September 22, 2026 | The paused state gains a yellow mouth and pause bars. |
| [Yellow star](yellow-star/preview.png) | September 22, 2026 | A yellow star replaces the pause bars. |

To render a version on macOS, run this from the repository root and choose an output path.

```sh
swift artwork/yellow-star/render.swift /tmp/poliwhirl-yellow-star.png
```
