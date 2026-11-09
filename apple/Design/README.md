# Florida identity

The geometric F is the primary mark. Pair it with the lowercase **Instrument
Serif Regular** wordmark for editorial contrast. Do not use the serif for dates,
tasks, controls or other UI text; those use native system text styles.

`FloridaMark.svg` and `FloridaWordmark.svg` are the vector masters. The wordmark
is outlined artwork, shaped with HarfBuzz from the Google Fonts Instrument Serif
Regular subset used in the approved study. It includes the `fl` ligature. The
font's attribution and OFL are in `InstrumentSerif-OFL.txt`; no font is loaded at
runtime. Do not stretch either mark, round its corners or add a gradient.

## Surfaces follow the system appearance

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| Paper | `#FAF9F5` | `#1A1E1B` | Calendar, primary screen and quick-add surfaces |
| Panel | `#F2F1EB` | `#202620` | Task pane and inset surfaces |
| Ink | `#252924` | `#EEEEE6` | Identity, selection and calendar text |
| Rule | `#E1E2D9` | `#363E34` | Quiet grid and panel separators |

Keep semantic warnings, priorities and user-selected calendar/category colors.
Calendar events use subtle fills and solid edges; flexible tasks use lighter
fills and dashed edges; pinned tasks retain a solid edge. An event's small left
rim identifies its account. Calendar text uses ink rather than arbitrary user
colors so yellow calendars and dark mode remain readable. Past items still dim.

Use modest radii (4–6 points for small items, 10 for the palette), native controls,
and system secondary text. iPhone rows get more vertical room; the desktop grid
keeps its existing time scale and keyboard behavior. No network call is needed
to load the identity or the theme.

## Regenerate assets

From the repository root:

```sh
uv run apple/Design/generate-assets.py
```

The script pins its build-only Python dependencies and produces vector PDF image
sets, light/dark color sets, opaque 1024px iPhone icons (including dark appearance),
and the full Mac icon size set. Assets are committed: Python is not needed to
build or run the apps. The shared catalog and `FloridaStyle.swift` compile only
into the two app targets, never into FloridaCore or FloridaKit.

## Native review

`ios.yml` captures Agenda, Tasks, Settings and detail/editor sheets in light and
dark appearances, plus large-text Agenda/Tasks. The CI macOS UI smoke test opens
the real app, filters commands with ⌘K, adds a task with c/Return, and captures
calendar, quick-add and month states in both appearances. Both use the same
Debug-only in-memory demo fixture, without a sync client or a keychain read.
The iPhone test waits for visible content and checks tab navigation before
capturing, rather than relying on a fixed delay after launch. Review the uploaded
screenshots; a successful build alone does not verify layout or contrast.
