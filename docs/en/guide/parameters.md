# Parameters

The "Handwriting & paper" panel groups basic settings, paper, natural variation, and cross-out
effects. These are the default values; a restored draft or preset can have different values.

!!! info "What jitter is for"
    Handwriting looks handwritten because no two characters are identical. The backend adds a
    small random offset to every character, drawn from a normal distribution — the "sigma"
    parameters control the width of that distribution. **Bigger means messier; 0 means perfectly
    regular.** The defaults are already tuned to look natural, so don't change them all at once.

## Basic parameters

| Parameter | Default | Meaning |
|---|---:|---|
| Font Size | `160` | Character size in pixels. Bigger text means fewer characters per sheet. |
| Line Spacing | `260` | Baseline-to-baseline distance. Must exceed the font size or lines will overlap. |
| Top Margin | `50` | Distance from the text block to the top edge. |
| Bottom Margin | `50` | Distance to the bottom edge. |
| Left Margin | `50` | Distance to the left edge. |
| Right Margin | `50` | Distance to the right edge; `>>>` right-alignment measures from here too. |
| Word Spacing | `1` | Extra gap between characters. |
| Width | `2800` | Paper width. Mutually exclusive with a background image. |
| Height | `3960` | Paper height. Mutually exclusive with a background image. |

The default paper has approximately A4 proportions. Pixel dimensions do not prescribe a print DPI.

## Toggles

| Parameter | Default | Meaning |
|---|---|---|
| Ruled paper | on | Draws a rule under every line. Also decides whether auto-generated paper is ruled. |
| Wider English word spacing | off | Widens the gaps between English words so they don't run together. Irrelevant for Chinese. |

## Natural variation

| Parameter | Default | Meaning |
|---|---:|---|
| Line Spacing Sigma | `0` | Variation in line spacing. Off by default. |
| Font Size Sigma | `2` | Variation in character size. |
| Word Spacing Sigma | `2` | Variation in the gap between characters. |
| Perturb X Sigma | `3` | Variation in each character's horizontal position. |
| Perturb Y Sigma | `3` | Variation in each character's vertical position. |
| Perturb Theta Sigma | `0.05` | Variation in each character's rotation, in radians. |
| Ink depth sigma | `30` | Variation in ink darkness, simulating heavier and lighter strokes. |

## Strikethroughs

Use these to leave a few "crossed out" marks on the page.

| Parameter | Default | Meaning |
|---|---:|---|
| Probability of a strikethrough occurring | `0.005` | Chance that any given character gets struck through. |
| Width of strikethrough | `8` | Thickness of the line. |
| Standard deviation of the strikethrough length | `2` | Variation in line length. |
| Standard deviation of the strikethrough width | `2` | Variation in line thickness. |
| Standard deviation of the strikethrough angle | `2` | Variation in line tilt. |

## Uploading and aligning ruled paper

Upload a background under Paper settings and confirm paper detection. The app measures spacing
between line centres, straightens detectable tilt, and applies the corrected background and layout
margins together. Use **Re-detect paper** below the filename to repeat the measurement on the current
background; repeated detection does not accumulate rotation.

The detected top margin positions the first text baseline on a rule; it is not simply the distance
from the image edge to the first rule. If the first rule is too close to the edge, writing starts at
the next usable one. An oversized font is reduced to fit; smaller sizes remain unchanged.
The corrected background and settings are saved with the draft. Text after tall formulas returns
to the ruling grid.

Blank images, too few lines or irregular spacing require manual settings and leave existing
parameters unchanged. Replacing the background or editing parameters during detection discards the
outdated result. Use a flat, clearly cropped page: perspective distortion, curved paper and major
occlusions are outside automatic rotation correction. Generate a preview to check the result;
reduce Line Spacing Sigma and Perturb Y Sigma for closer alignment.

## Built-in preset

The presets dropdown offers "Small ruled · Yunyan", "Natural handwriting", and "Neat handwriting".

**Small with underlines (Yunyan)** — small text in the Yunyan font, generous line spacing and
margins, with underlines:

| Parameter | Preset | (Default for comparison) |
|---|---:|---|
| Font Size | `70` | 160 |
| Line Spacing | `100` | 260 |
| All four margins | `150` | 50 |
| Font Size Sigma | `1` | 2 |
| Line Spacing Sigma | `1` | 0 |
| Word Spacing | `2` | 1 |
| Perturb X Sigma | `1` | 3 |
| Perturb Y Sigma | `1` | 3 |
| Probability of a strikethrough occurring | `0` | 0.005 |
| Add underline | on | on |

Remove the background image before applying paper presets. The Yunyan preset selects `云烟体.ttf`
when that font is installed; otherwise it keeps the currently selected font.

## Tuning tips

- **Characters are colliding** → raise Line Spacing or Word Spacing.
- **Looks too tidy to be handwriting** → raise Perturb X Sigma and Perturb Y Sigma.
- **Looks too chaotic** → lower Perturb Theta Sigma first; it affects the impression the most.
- **Want to fit more per page** → lower Font Size, Line Spacing, or margins.
- **Changed a parameter and nothing happened** → you have to click "Generate preview"
  again. The preview does not re-render on its own.
