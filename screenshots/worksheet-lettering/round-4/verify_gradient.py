"""Re-evaluate native field contrast, edges and full-image comparisons.

Run python verify_gradient.py with numpy and Pillow to check the sampled fields,
the provided finished page, and its zero-end comparison. Add --clear OLD_CLEAR.png
--uniform OLD_SOFT.png using the previous round to check all six full-page pairs.
"""
from itertools import combinations
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent
states = ["clear", "uniform", "gradient02", "gradient0"]
parser = argparse.ArgumentParser(description=__doc__)
for n in states:
    parser.add_argument("--" + n, type=Path)
args = parser.parse_args()
d = json.loads((ROOT / "gradient-measurements.json").read_text(encoding="utf-8"))
points = np.load(ROOT / d["sample_file"]["file"], allow_pickle=False)
x = points["x"].astype(int)
y = points["y"].astype(int)
ink = {}
steepness = {}
for n in states:
    ink[n] = points[n+"_paper"].astype(np.int16) - points[n+"_output"].astype(np.int16)
    ink_x = (ink[n][:, 2] - ink[n][:, 1]).astype(float)
    ink_y = (ink[n][:, 4] - ink[n][:, 3]).astype(float)
    steepness[n] = np.hypot(ink_x, ink_y) / 2
exclude_rules = points["paper_clear_median_y21"].astype(np.int16) - points["clear_paper"][:, 0] < 12

def check_close(a,b):
    assert np.isclose(a,b,atol=.000051,rtol=0), (a,b)

def verify_rgb(a,b,e):
    gap = np.abs(a.astype(np.int16) - b)
    m = gap.max(axis=-1)
    assert m.size == e["pixels"] and int(m.max())==e["largest_channel_difference"]
    assert np.count_nonzero(m)==e["changed_rgb_pixels"]
    for k, threshold in [("changed_percent",1),("changed_at_least_3_percent",3),("changed_at_least_10_percent",10)]:
        check_close(100 * (m>=threshold).mean(), e[k])
    check_close(gap.mean(),e["mean_absolute_channel_difference"])

for field, item in d["field_metrics"].items():
    roi = np.zeros(x.shape,dtype=bool)
    for left,top,right,bottom in item["native_boxes_xyxy_exclusive"]:
        roi |= (x>=left)&(x<right)&(y>=top)&(y<bottom)
    c=roi&exclude_rules&(ink["clear"][:,0]>18)
    edges=roi&exclude_rules&(ink["clear"][:,0]>=8)&(steepness["clear"]>=12)
    assert c.sum()==item["contrast_samples"] and edges.sum()==item["edge_samples"]
    for n,v in item["values"].items():
        check_close(np.percentile(ink[n][c,0],90),v["ink_drop_p90"])
        check_close(np.median(steepness[n][edges]),v["edge_median"])
        check_close(np.percentile(steepness[n][edges],90),v["edge_p90"])
        for ref in ["clear","uniform"]:
            verify_rgb(points[n+"_rgb"][roi],points[ref+"_rgb"][roi],v["rgb_vs_"+ref])
    print("Verified",field,"over",int(edges.sum()),"fixed native edge samples.")

images={}
for n in states:
    p=getattr(args,n)
    if n=="gradient02" and p is None:
        p=ROOT/d["outputs"]["gradient02"]
    if n=="gradient0" and p is None and "gradient02" in images:
        from PIL import Image
        src=images["gradient02"].copy().reshape(-1,3)
        delta=np.load(ROOT/d["zero_end_verification_data"]["file"],allow_pickle=False)
        positions=np.cumsum(delta["position_steps"],dtype=np.int64)
        output=src[positions].astype(np.int16)+delta["delta_rgb"]
        assert output.min()>=0 and output.max()<=255
        src[positions]=output
        page=Image.fromarray(src.reshape(images["gradient02"].shape))
    elif p is not None:
        from PIL import Image
        page=Image.open(p).convert("RGB")
    else:
        continue
    assert list(page.size)==d["page_size"]
    assert hashlib.sha256(page.tobytes()).hexdigest()==d["controls"][n]["output_rgb_sha256"]
    for crop in d["controls"][n]["crop_checks"].values():
        h=hashlib.sha256(page.crop(crop["bbox_xyxy_exclusive"]).tobytes()).hexdigest()
        assert h==crop["rgb_sha256"]
    images[n]=np.array(page)
    assert np.array_equal(images[n][y,x],points[n+"_rgb"])
for n1,n2 in combinations(images,2):
    pair=d["pixel_comparisons"][n1+"__"+n2];a,b=images[n1],images[n2]
    yy,xx=np.nonzero(np.any(a!=b,axis=2))
    box=[xx.min(),yy.min(),xx.max()+1,yy.max()+1] if len(xx) else None
    assert box==pair["changed_bbox_xyxy_exclusive"]
    for band in pair["bands"].values():
        i,j=band["rows_y"]
        verify_rgb(a[i:j],b[i:j],band)
    print("Verified full RGB and band comparisons for",n1,"and",n2)
