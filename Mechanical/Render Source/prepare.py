from pathlib import Path
from PIL import Image
import re,json,math,hashlib,sys
if len(sys.argv) != 3:
    raise SystemExit("Usage: prepare.py REPOSITORY OUTPUT")
REV, HERE = (Path(value).resolve() for value in sys.argv[1:])
im=Image.open(REV/'Mechanical/Renders/01 Rev E Bare Top.png').convert('RGB')
im.crop((397,294,1785,1274)).save(HERE/'pcb_top_texture.png')
def parse(text):
 stack=[];result=None
 for t in re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',text):
  if t=='(':stack.append([])
  elif t==')':
   a=stack.pop()
   if stack:stack[-1].append(a)
   else:result=a
  else:stack[-1].append(json.loads(t) if t.startswith('"') else t)
 return result
def child(n,k):return next((i for i in n if isinstance(i,list) and i and i[0]==k),None)
circuit=json.loads((REV/'CAD/Circuit.json').read_text())
parts={p['ref']:p for p in circuit['parts']}
for fp in parse((REV/'CAD/FDS1010_Budget_E.kicad_pcb').read_text()):
 if not isinstance(fp,list) or not fp or fp[0]!='footprint':continue
 ref=next((n[2] for n in fp if isinstance(n,list) and n[:2]==['property','Reference']),None)
 if ref not in parts:continue
 at=child(fp,'at');x,y=map(float,at[1:3]);a=float(at[3]) if len(at)>3 else 0;r=math.radians(a)
 points=[]
 for pad in fp:
  if isinstance(pad,list) and pad and pad[0]=='pad':
   at=child(pad,'at');dx,dy=map(float,at[1:3]);drill=child(pad,'drill');size=child(pad,'size');pad_angle=float(at[3]) if len(at)>3 else a
   points.append({'pin':pad[1],'x':x+dx*math.cos(r)+dy*math.sin(r),'y':y-dx*math.sin(r)+dy*math.cos(r),'drill':float(drill[1]),'square':pad[3]=='rect','shape':pad[3],'size_mm':list(map(float,size[1:3])),'angle_deg':pad_angle,'footprint_angle_deg':a,'native_pad_at':list(map(float,at[1:]))})
 parts[ref]['pads']=points
order=['R1','R2','R4','R5','R6','R7','R8','R9','R10','R11','R12','R3','D1','D2','C2','C4','C6','C8','C5','C7','C1','C3','U1','J1','J2','J3','J4']
bands={'10k':['brown','black','black','red','brown'],'1M':['brown','black','black','yellow','brown'],'52.3k':['green','red','orange','red','brown'],'1k':['brown','black','black','brown','brown'],'49.9k':['yellow','white','white','red','brown'],'100R':['brown','black','black','black','brown']}
for p in parts.values():
 if p['value'] in bands:p['bands']=bands[p['value']]
assert len(parts)==27 and sum(len(p['pads']) for p in parts.values())==71
(HERE/'model_config.json').write_text(json.dumps({'parts':parts,'order':order,'sources':{'pcb':str(REV/'CAD/FDS1010_Budget_E.kicad_pcb'),'circuit':str(REV/'CAD/Circuit.json')},'notes':['Full bodies and leads added solely for assembly documentation.','Pad positions, native outer sizes, shapes, rotations and drill diameters parsed from unchanged native PCB.','Circuit.json body fields are conservative CAD envelopes retained as source evidence. Physical documentation body selections come from component_geometry.json.','Blue resistor bodies and nominal five band codes are illustrations. Manufacturer lot coatings and band spacing may differ.','IC label is illustrative. Align notch and pin 1, not printed text.','Native artwork used as board texture. Green soldermask color is illustrative.']},indent=2))

config=json.loads((HERE/'model_config.json').read_text())
config['source_sha256']={k:hashlib.sha256(Path(v).read_bytes()).hexdigest() for k,v in config['sources'].items()}
config['top_mapping']={'stage_width':1600,'stage_height':1200,'horizontal_span_mm':94,'center_mm':[42.5,30],'board_bounds_px':[76.59574468085111,89.36170212765956,1523.404255319149,1110.6382978723404]}
(HERE/'model_config.json').write_text(json.dumps(config,indent=2))
