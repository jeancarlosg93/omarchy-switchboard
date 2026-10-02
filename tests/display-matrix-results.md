# Display layout verification

Verified on 2026-10-02 with Hyprland 0.56.2 and Quickshell 0.3.1.

The actual Switchboard QML was instantiated in a separate Quickshell process on a temporary Hyprland headless output. Its configuration used a temporary home directory and the default Omarchy style metrics. The harness only adds output selection and layout inspection methods to a temporary copy of the plugin; production geometry and navigation functions run unchanged. The keyboard check raises the test instance’s pointer-movement threshold to prevent host-pointer hover events from changing the selection during measurement.

## Matrix

| Physical output size | Display scale | Effective size |
| --- | --- | --- |
| 1366x768 | 100% | 1366 × 768 |
| 1920x1080 | 100% | 1920 × 1080 |
| 2560x1440 | 125% | 2048 × 1152 |
| 2560x1440 | 160% | 1600 × 900 |
| 3840x2160 | 150% | 2560 × 1440 |
| 3840x2160 | 200% | 1920 × 1080 |
| 1280x720 | 100% | 1280 × 720 |
| 1080x1920 | 100% | 1080 × 1920 |
| 1920x1080 | 200% | 960 × 540 |
| 1280x720 | 160% | 800 × 450 |

Each display ran launcher scales `1`, `1.2`, and `2`, both `top` and `center` alignment, and root menu, search, long application list, 60-item selection dialog, and input dialog: **300 scenarios passed**. Each search scenario also types through `s`, `sc`, `scr`, an unmatched query, backspacing, and clearing without closing the launcher. Across centered configurations, 210 query transitions verify that the search field and first-result position remain stationary, including empty results. Initial centering is checked separately from those transitions.

Assertions check the named output and effective dimensions, horizontal centering, vertical centering on opening, screen bounds, footer placement, and full selected-row visibility after navigating to the end of the list. Configuration changes apply through the real watched shell.json reader. The output coexisted with two physical 2560 × 1440 displays at scale 1, exercising rendering with mixed output scales.

## Regressions found and fixed

- The neighbouring-row scroll margin could hide part of the selected row when the viewport was narrow. The margin now shrinks to the available room.
- A large launcher with the original top offset could leave insufficient room for a detailed search/selection row. The viewport minimum now uses the actual row height, and the top offset shrinks only when needed to fit the controls and one complete row.
- Recomputing centered position for every result-list height made the search field and first result jump during typing. Centered mode now captures its top edge on opening and grows downward, with enough room reserved for a detailed row. Empty-result height is constrained to the remaining space as well.

The compact visual check confirmed that a detailed selected row, search field, and footer remain usable at an effective 800 × 450 with launcher scale 2.

## Reproduce

```bash
node tests/ui-scale.cjs
python tests/display-matrix.py
# Optional focused visual stress check:
SWITCHBOARD_TEST_ARTIFACTS=/tmp/switchboard-compact-results python tests/display-matrix.py --compact
```

Run the integration test inside an active Hyprland session with Omarchy, Quickshell, Python 3, and grim. The script creates and removes a uniquely named headless output and stops its test shell in a finally block. It does not edit physical monitor modes or the user’s configuration. Results and screenshots are local artifacts rather than committed desktop captures.

## Limits

These are real Wayland/QML rendering tests on simulated outputs, not tests on physical 4K hardware. They use default style metrics; arbitrary theme overrides and font families were not exhaustively tested. The harness binds the test output explicitly, so compositor selection of the output when summoning the normal launcher is outside this matrix. The normal launcher’s existing output selection behavior is unchanged.

No QML TypeError, ReferenceError, or binding-loop errors appeared in the final run. The isolated process logged portal-registration and SVG-asset warnings; neither caused layout assertion failures.
