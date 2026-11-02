# Brag plan — Vibhor's Notch: CPU & GPU monitoring

## Answers
- **What is it?** A personal Dynamic-Island-style app for the MacBook notch: hover the notch and it opens into tabs (Home, Apollo, Music, Tasks, Notes, Shelf, Focus, System, Teleprompter).
- **Who is it for / what does it do for them?** MacBook owners who want their notch to do something. The new System tab shows live CPU and GPU load, and can keep CPU/GPU % beside the camera when the notch is closed.
- **What sets it apart?** It lives *in the notch*. CPU is split into efficiency vs performance cores, GPU load and memory come straight from the GPU driver, no root and no permission prompts, and a sample costs ~24 µs.
- **Most impressive / funniest claim:** The notch, a literal hole in the screen, finally does something. And all of it costs your Mac 24 µs a second.
- **Visual hook:** Zoomed in on a black notch; "ears" spring out of it showing live `CPU 24%` / `GPU 52%`.
- **Real UI / flow to show:** hover → notch springs open → System tab (real SwiftUI views) → `swift build` pegs all 10 cores → GPU hits 100% → close it → numbers stay by the camera.
- **Tone:** `default`: punchy, playful, clean, with Apple-keynote polish.
- **Share caption:** "My MacBook notch now shows live CPU and GPU load. It costs 24 µs a second."

## Angle
"The notch finally does something." The video is the real app, with real data. Every number on screen was recorded by the app's own `SystemMonitor` on this M4. The CPU spike is the notch watching a clean `swift build` of its own source (all 10 cores hit 100%), and the GPU spike is a Metal compute burst.

## Visual identity
- Canvas: 1920×1080, 30 fps. The top edge of the frame is the top of the Mac's screen, with a dark wallpaper, a menu bar strip, and the notch hanging from it.
- Real components rendered frame-by-frame: `NotchShape`, `ExpandedView` (header + tabs), `SystemView`, `SystemLiveActivity`. Spring constants copied from the app (open 0.4/0.78, close 0.35/0.9, ears 0.4/0.8).
- Colors: CPU `#3987e5`, GPU `#d95926` (the app's validated series colors), black notch, white/secondary text.
- Type: SF Pro (captions), SF Pro Rounded (numbers), as in the app.
- Camera: one continuous camera (zoom + pan) instead of cuts.

## Storyboard (22.0 s)
| # | Time | Scene | On screen | Caption | Sound |
|---|---|---|---|---|---|
| 1 | 0.0–3.0 | **Hook** | Camera tight on the closed notch in the menu bar. At 0.4s the ears spring out: `CPU 24%` / `GPU 52%`, ticking live. | "Your notch finally does something." | Soft pad; two-note blip as the ears pop |
| 2 | 3.0–6.4 | **Reveal** | Cursor glides to the notch. Notch springs open into the System tab while the camera pulls back. | **Vibhor's Notch** / "Live CPU & GPU stats, right under your camera." | Whoosh into the downbeat at 4.0; drums enter |
| 3 | 6.4–11.2 | **Build** | Camera on the CPU card. Terminal chip types `swift build`. Graph climbs, all 10 core meters fill to 100%, then "Build complete! (6.71s)". | "Hit build. All 10 cores light up." + footnote "Real readings, recorded on an Apple M4" | Typing ticks, riser into an impact at 9.0 (100%) |
| 4 | 11.2–14.4 | **GPU** | Camera pans to the GPU card. GPU climbs to 100%, memory in use rises to ~790 MB. | "GPU load and memory too. No root, no prompts." | Pan whoosh; smaller hit as GPU pegs |
| 5 | 14.4–18.0 | **Close it** | Cursor leaves; notch springs shut; camera pushes in on the ears still showing `GPU 100%`. | "Close it. The stats stay by the camera." | Reverse whoosh, blip as ears land |
| 6 | 18.0–22.0 | **Outro** | Camera pulls back. Title, the 9 tab icons (System highlighted), GitHub URL. | **Vibhor's Notch** / "All of this costs 24 µs a second." / github.com/Vibhor7-7/vibhors-notch | Final chord, drums drop out, tail |

Durations: 3.0 + 3.4 + 4.8 + 3.2 + 3.6 + 4.0 = 22.0 s.

## Data replay
- History graphs are prefilled with 60 real idle samples (session A).
- Session B (real): idle 0–7, clean debug build 8–17 (all cores 100% at 13), Metal burst 21–28 (GPU 100%), idle after.
- Data clock: ~1 sample/s while idle, ~3.6 samples/s during the build, ~1 sample/s through the GPU burst. Core meters ease between samples the way the app's `.animation(.easeOut(0.3))` does.

## Sound
120 BPM, C major / A minor (F–G–Am–C). Pad, sub bass, soft kick, quiet hats, plucked arp in highlights. SFX use the same key and share one reverb. They sit under the music. Gentle soft-clip and peak normalize to -1 dBFS.
