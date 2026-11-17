from pathlib import Path
import json,hashlib,re,math,sys
from PIL import Image
from geometry_validation import validate_component_geometry
h=Path(sys.argv[1]).resolve()
cfg=json.loads((h/'model_config.json').read_text());parts=cfg['parts'];order=cfg['order']
assert len(parts)==len(order)==len(set(order))==27
assert set(order)==set(parts)
assert sum(len(p['pads']) for p in parts.values())==71
lookup=lambda ref,pin:next(q for q in parts[ref]['pads'] if q['pin']==pin)
assert lookup('U1','1')['shape']=='rect' and lookup('U1','1')['size_mm']==[2.0,2.0]
for ref,pin in [('U1','4'),('C2','1')]:
 q=lookup(ref,pin);assert q['shape']=='oval' and q['size_mm']==[1.5,1.5] and q['drill']==.9
q=lookup('U1','5');assert q['shape']=='oval' and q['size_mm']==[2.0,1.5] and q['drill']==1
geometry=json.loads((h/'pad_geometry.json').read_text())
assert len(geometry)==71
for q in geometry:
 native=lookup(q['ref'],q['pin'])
 assert q['shape']==native['shape'] and q['native_size_mm']==native['size_mm']
 assert q['native_drill_mm']==q['mesh_hole_diameter_mm']==native['drill']
 assert q['position_mm']==[native['x'],native['y']]
 assert q['native_angle_deg']==native['angle_deg']
 assert all(abs(a-b)<1e-6 for a,b in zip(q['mesh_outer_size_mm'],native['size_mm']))
 width,height=native['size_mm'];shape=native['shape'];outer=q['outer_local_vertices_mm'];inner=q['inner_local_vertices_mm']
 assert len(outer)==len(inner)>=128
 for x,y in outer:
  if shape=='rect':assert abs(max(abs(x)/(width/2),abs(y)/(height/2))-1)<1e-6
  elif shape=='circle':assert abs(math.hypot(x,y)-width/2)<1e-6
  elif width>=height:assert abs(math.hypot(max(abs(x)-(width-height)/2,0),y)-height/2)<1e-6
  else:assert abs(math.hypot(x,max(abs(y)-(height-width)/2,0))-width/2)<1e-6
 if shape=='rect':
  for sx,sy in [(-1,-1),(-1,1),(1,-1),(1,1)]:assert any(abs(x-sx*width/2)<1e-6 and abs(y-sy*height/2)<1e-6 for x,y in outer)
 assert all(abs(math.hypot(x,y)-native['drill']/2)<1e-6 for x,y in inner)
drill_proof=json.loads((h/'drill_geometry_proof.json').read_text())
assert len(drill_proof)==71 and {(q['ref'],q['pin']) for q in drill_proof}=={(q['ref'],q['pin']) for q in geometry}
assert all(q['passed'] and q['inside_hole_ray_tests']==8 and q['outside_hole_ray_tests']==4 for q in drill_proof)

package=json.loads((h/'component_geometry.json').read_text())
component_proof=json.loads((h/'component_geometry_proof.json').read_text())
component_checks=validate_component_geometry(h,parts,package,component_proof)

renders=json.loads((h/'renders.json').read_text())
assert len(renders['stages'])==27
for i,stage in enumerate(renders['stages']):
 assert stage['installed']==order[:i+1]
 assert stage['ref']==order[i] and stage['image']==f'stage_{i+1:02d}_{order[i]}.png'
for key,path in cfg['sources'].items():
 assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==cfg['source_sha256'][key]
digit=dict(zip(['black','brown','red','orange','yellow','green','blue','violet','gray','white'],range(10)))
expected={'10k':10000,'1M':1000000,'52.3k':52300,'1k':1000,'49.9k':49900,'100R':100}
for p in parts.values():
 if 'bands' in p:
  b=p['bands'];value=(100*digit[b[0]]+10*digit[b[1]]+digit[b[2]])*10**digit[b[3]]
  assert value==expected[p['value']] and b[4]=='brown'
previous=json.loads((h/'model_QA.json').read_text()) if (h/'model_QA.json').exists() else {}
files=['assembled_top.png','assembled_isometric.png','U1_C2_top_detail.png','U1_C2_isometric_detail.png']+[f'stage_{i+1:02d}_{r}.png' for i,r in enumerate(order)]
files += [p.name for p in sorted(h.glob('part_*.png'))]
output=[]
for name in files:
 p=h/name
 assert p.stat().st_mtime>=max((h/source).stat().st_mtime for source in ['model_config.json','component_geometry.json','render.py']), f'Stale component image: {name}'
 im=Image.open(p);im.verify();im=Image.open(p)
 if name.startswith('stage'):assert im.size==(1600,1200)
 output.append({'file':name,'pixels':list(im.size),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
report={'placements':27,'joints':71,'stages':27,'expected_band_values_checked':11,'images_verified':len(files),'source_sha256':cfg['source_sha256'],'board_image_revision':'native pad shapes and sizes, version2','native_pad_shapes_verified':71,'mesh_pad_boundaries_verified':71,'board_drill_ray_tests':852,'geometry_proof_sha256':hashlib.sha256((h/'pad_geometry.json').read_bytes()).hexdigest(),'drill_proof_sha256':hashlib.sha256((h/'drill_geometry_proof.json').read_bytes()).hexdigest(),'special_pad_checks':['U1.1 rect2x2','U1.4 oval1.5x1.5 drill0.9','U1.5 oval2x1.5','C2.1 oval1.5x1.5 drill0.9'],'scope':'Digital geometry and images only. No physical assembly, electrical test, measured body color or received-part certification.','images':output}
report.update(component_checks)
report['component_geometry_proof_source_sha256']=component_proof['source_sha256']
if all(next((old['sha256']==item['sha256'] for old in previous.get('images',[]) if old['file']==item['file']),False) for item in output):
 for key in ['render_engine','render_timing','visual_review','renderer_wrapper_validation','native_shape_counts','cleanup']:
  if key in previous:report[key]=previous[key]
report['render_source_sha256']=hashlib.sha256((h/'render.py').read_bytes()).hexdigest()
(h/'model_QA.json').write_text(json.dumps(report,indent=2));print(json.dumps({k:report[k] for k in ['placements','joints','stages','images_verified','source_sha256','scope']},indent=2))
