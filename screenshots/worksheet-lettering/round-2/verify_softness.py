"""Verify the native-pixel softness comparison with Pillow and numpy."""
import json
from statistics import median

from verify_widths import DATA, ROOT, Image, axis, left, np, paper, sample_at, second, step, top

soft = json.loads((ROOT / "softness-comparison.json").read_text(encoding="utf-8"))
planes = np.moveaxis(np.array(Image.open(ROOT / soft["trial_luma_pixels"]["file"]), dtype=float), 2, 0)


def crossings(v, peak, fraction):
    level = v[peak] * fraction
    below_left = np.flatnonzero(v[:peak] < level)
    below_right = np.flatnonzero(v[peak + 1:] < level)
    if not len(below_left) or not len(below_right):
        return None
    i = below_left[-1]
    j = peak + 1 + below_right[0]
    return (
        axis[i] + step * (level - v[i]) / (v[i + 1] - v[i]),
        axis[j - 1] + step * (level - v[j - 1]) / (v[j] - v[j - 1]),
    )


def transition(v, peak):
    low, high = crossings(v, peak, .25), crossings(v, peak, .75)
    if low is not None and high is not None:
        return ((high[0] - low[0]) + (low[1] - high[1])) / 2
    return None


def measure(image, groups, kept=None):
    widths, rises, peaks = [], [], []
    drop = paper - image
    for key, group in groups.items():
        widths_here, rises_here, peaks_here = [], [], []
        guides = group["samples"]
        for index in (range(len(guides)) if kept is None else kept[key]):
            x, y, nx, ny, radius = guides[index][5:]
            v = sample_at(drop, x - left + axis * nx, y - top + axis * ny)
            allowed = np.flatnonzero(abs(axis) <= radius)
            peak = allowed[np.argmax(v[allowed])]
            lo, hi = crossings(v, peak, .5)
            widths_here.append(round(hi - lo, 3))
            rise = transition(v, peak)
            if rise is not None:
                rises_here.append(rise)
                peaks_here.append(v[peak])
        widths.append(round(median(widths_here), 3))
        rises.append(median(rises_here))
        peaks.append(median(peaks_here))
    return np.round([median(widths), median(rises), median(peaks)], 3)


for name, variant in soft["variants"].items():
    got = measure(planes[variant["packed_channel"]], DATA["second_round_edges"], variant["valid_guide_indices"])
    expect = [variant[k] for k in ("width_px", "edge_transition_25_75_px", "peak_luma_drop")]
    assert np.allclose(got, expect, atol=.001)
    print(f"{name}: FWHM {got[0]:.3f} px, 25%-75% transition {got[1]:.3f} px, peak drop {got[2]:.3f}")

got = measure(second, DATA["unchanged_body_rows"])
assert np.allclose(got, [soft["unchanged_body"][k] for k in ("width_px", "edge_transition_25_75_px", "peak_luma_drop")], atol=.001)

rulings = []
for group in soft["paper_reference"]["reference_rulings"].values():
    widths = []
    for x, y, peak_drop, edge_width in group:
        values = sample_at(paper, np.full(axis.shape, x - left), y - top + axis)
        residual = median(np.r_[values[:20], values[-20:]]) - values
        peak = np.argmax(residual)
        got = transition(residual, peak)
        assert abs(got - edge_width) < .00051 and abs(residual[peak] - peak_drop) < .0051
        widths.append(round(got, 3))
    rulings.append(median(widths))
assert abs(median(rulings) - soft["paper_reference"]["edge_rise_px"]) <= .001
print(f"Paper ruling 25%-75% transition: {median(rulings):.3f} px")
