# Vibhor's Notch

A personal Dynamic-Island-style app for the MacBook notch. Hover over the notch to open it.

## Tabs
- **Home**: clock, date, battery, and calendar events for today and tomorrow
- **Notes**: create, edit and delete notes (autosaved)
- **Shelf**: drop files to keep them handy, then drag them back out, double-click to open, or right-click for more options. Dragging a file onto the closed notch opens the shelf.
- **Teleprompter**: paste a script, press Start, and it scrolls right under the camera. Space plays or pauses, and you can drag the text to scrub. Speed and font size are adjustable.

## Behaviour
- Opens on hover and closes when the mouse leaves. It stays open while you're typing, while the teleprompter is playing, or when pinned (📌).
- Esc or clicking elsewhere closes it.
- `…` menu → Launch at Login / Quit.
- Shows only on the built-in display.

## Build & run
```bash
./build.sh            # build to build/Vibhor's Notch.app
./build.sh --run      # build and (re)launch
./build.sh --install  # copy to /Applications and launch
```
Requires macOS 14+ and Xcode command line tools.

Data lives in `~/Library/Application Support/VibhorsNotch/` (`notes.json`, `shelf.json`).

## Customizing
- Add a tab: add a case to `NotchTab` (NotchViewModel.swift) and a view in `ExpandedView`.
- Expanded size: `expandedSize` in NotchViewModel.swift.
- Hover delays: `handleMouse` in NotchController.swift.
