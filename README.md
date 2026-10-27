# Squall

Weather for your desktop. Squall is a native macOS menu-bar app that makes it rain or snow across
every screen, in a click-through overlay that lives above your windows. The weather is physical:
snow piles up on the top edges of your open windows and along the bottom of the screen, rain pools
and runs off window corners in drips, and the cursor ploughs through all of it.

## Weather

| | |
|---|---|
| **Snow** | Two depth layers of flakes that flutter and drift with the wind. Near flakes settle into drifts with a real angle of repose; past the lip of a window the excess slides off the end and falls onto whatever is below. |
| **Rain** | Slanted streaks that splash into droplets where they land. Water levels out along each window edge, ripples, and drips off both corners; the screen floor fills into a shallow pool. Rain melts settled snow. |
| **Clear** | The sky stops. Snow melts into water, and water evaporates, until everything is gone — then Squall stops drawing entirely and uses no CPU. |

## Interaction

- **Cursor** — flakes swirl away from the pointer and get dragged along in its wake. Sweep through a pile to throw snow; drag through water to make waves. Raindrops splash off the pointer.
- **Clicks** — every click (in any app) is a puff of air: nearby flakes scatter and snow blasts off the ledges around it.
- **Windows** — piles ride along when you move a window. Drag fast and snow flies off; stop hard and it's flung forward; water sloshes. Resize and the snow past the new edge falls. Close a window and its load drops. Minimize or switch Spaces and the pile waits for you.
- Piles only form on edges you can see: a window in front hides (and blocks) the part of a pile behind it, and windows tucked under the menu bar get nothing.

## Controls

Click the menu-bar icon for the panel: the Clear · Rain · Snow picker, intensity, wind, and switches
for settling on windows, cursor interaction, click gusts and launch at login. **Shake Off** knocks
everything off. Right-click the menu-bar icon to cycle the weather without opening the panel.

## Permissions

None. Window positions come from the window server (no Screen Recording needed), the cursor position
is public, and watching clicks in other apps doesn't require Accessibility.

## Build

Requires macOS 14+ and Xcode or the Command Line Tools.

```bash
./build.sh                     # → build/Squall.app
cp -R build/Squall.app /Applications/ && open /Applications/Squall.app
./make-dmg.sh                  # → build/Squall-<version>.dmg
swift test                     # pile physics tests
```

## How it works

- `Core/Ledge.swift` — a surface as a row of 3 pt cells holding snow and water heights: angle-of-repose
  relaxation, water diffusion and drainage, a 1-D wave equation for ripples, melt and evaporation.
- `Simulation.swift` — particles, emission, wind, cursor forces, collisions (ledge segments binned by x),
  window sync (move/shake/resize/close/hibernate), occlusion, and instance generation.
- `WindowTracker.swift` — `CGWindowListCopyWindowInfo` at up to 60 Hz, front to back.
- `Renderer.swift` — one transparent, click-through window per screen with an `MTKView`; everything is
  drawn as instanced quads in a single draw call with 4× MSAA. Shaders compile from source at launch.
- `Engine.swift` — a `CADisplayLink` loop (120 Hz on ProMotion) that stops when the sky is clear and empty.
- `ControlPanel.swift`, `WeatherPicker.swift`, `Glass.swift`, `Logo.swift` — the UI, in Wedge's glass style.
