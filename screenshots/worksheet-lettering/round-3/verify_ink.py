from pathlib import Path
import json,sys,numpy as np
from PIL import Image,ImageDraw
from scipy.ndimage import median_filter
ROOT=Path(__file__).resolve().parent
data=json.loads((ROOT/'page-ink-samples.json').read_text(encoding='utf8'))
ox,oy,ex,ey=data['packed_lumas']['xyxy_exclusive']
p,old,mild,strong=np.moveaxis(np.asarray(Image.open(ROOT/data['packed_lumas']['file']),dtype=float),2,0)
assert p.shape==(ey-oy,ex-ox)
med=median_filter(p,size=(21,1))
for key,group in data['paper_rulings'].items():
 samples=[]
 for x,marked_y,y,pixel,median,drop in group['samples']:
  cx=x-ox; cy=y-oy; marked=marked_y-oy
  assert cy==int(np.argmin(p[marked-10:marked+11,cx])+marked-10)
  assert p[cy,cx]==pixel and med[cy,cx]==median and median-pixel==drop
  samples.append(drop)
 assert np.array_equal(np.percentile(samples,[25,50,75]),group['p25_p50_p75_drop'])
for key,region in data['printing'].items():
 poly=np.array(region['polygon_xy'])-[ox,oy];x,y=poly.min(0);r,b=poly.max(0)+1
 raw=p[y-12:b+12,x-12:r+12];ink=median_filter(raw,size=(21,21))[12:-12,12:-12]-p[y:b,x:r]
 mask=Image.new('L',(r-x,b-y));ImageDraw.Draw(mask).polygon([tuple(t)for t in (poly-[x,y]).tolist()],fill=255)
 values=ink[(np.asarray(mask)>0)&(ink>18)]
 assert len(values)==region['samples'] and np.percentile(values,90)==region['p90_drop'] and np.percentile(values,50)==region['p50_drop']
for label,group in data['writing'].items():
 mask=np.zeros(p.shape,dtype=bool)
 for x,y,r,b in group['glyph_boxes_xyxy_exclusive']:
  mask[y-oy:b-oy,x-ox:r-ox]=True
 mask &= (p-old>18)&(med-p<12)
 assert mask.sum()==group['samples']
 for name,image in [('v24',old),('mild',mild),('strong',strong)]:
  raw=(p-image)[mask];m=group['states'][name]
  assert np.isclose(np.percentile(raw,90),m['p90_drop']) and np.median(raw)==m['p50_drop'] and np.median(image[mask])==m['median_rendered_luma']
print('Verified 3 renders, 13 handwriting groups, 2 areas of original printing and 385 ruled-line profiles.')
