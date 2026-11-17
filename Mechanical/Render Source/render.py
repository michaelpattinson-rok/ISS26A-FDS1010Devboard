import bpy,math,json,sys,hashlib
from pathlib import Path
from mathutils import Vector
HERE = Path(sys.argv[sys.argv.index('--output-dir') + 1]).resolve()
VALIDATE_ONLY='--validate-only' in sys.argv
cfg=json.loads((HERE/'model_config.json').read_text());parts=cfg['parts'];order=cfg['order']
geometry=json.loads((HERE/'component_geometry.json').read_text())
assert set(geometry['ref_family'])==set(parts)
ONLY_IMAGES=None
if '--only' in sys.argv:
 ONLY_IMAGES=set(sys.argv[sys.argv.index('--only')+1].split(','))
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene
scene.render.engine='CYCLES';scene.cycles.samples=8;scene.cycles.use_denoising=True
scene.cycles.device='CPU'
scene.render.image_settings.file_format='PNG';scene.render.film_transparent=False
scene.world.color=(.8,.8,.8)
scene.view_settings.view_transform='AgX'
scene.render.resolution_x=1800;scene.render.resolution_y=1350;scene.render.resolution_percentage=100
materials={}
def mat(name,color,metal=0,rough=.4):
 if name in materials:return materials[name]
 m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
 bs=m.node_tree.nodes.get('Principled BSDF');bs.inputs['Base Color'].default_value=(*color,1);bs.inputs['Metallic'].default_value=metal;bs.inputs['Roughness'].default_value=rough
 materials[name]=m;return m
silver=mat('Tin plated leads',(.52,.56,.58),.8,.24);gold=mat('Plated square posts',(.68,.48,.15),.8,.24)
black=mat('Black molded package',(.018,.022,.025),0,.5);blue=mat('Illustrative blue film resistor',(.17,.47,.65),0,.28)
colors={'brown':(.27,.09,.032),'black':(.008,.009,.012),'red':(.68,.025,.025),'orange':(.95,.27,.015),'yellow':(.91,.67,.015),'green':(.02,.28,.07),'white':(.85,.86,.8)}
bandmats={n:mat(n+' band',v,0,.35) for n,v in colors.items()}
ceramicblue=mat('TDK blue dipped coating illustration',(.055,.23,.50),0,.3);beige=mat('KEMET ceramic coating illustration',(.63,.40,.09),0,.36);glass=mat('DO35 glass illustration',(.61,.20,.04),0,.18);mark=mat('Illustrative light gray marking',(.64,.67,.63),0,.7)
boardmat=mat('PCB edge illustrative green',(.023,.12,.071),0,.5);bg=mat('Neutral background',(.93,.94,.94),0,.9)
objects={};current=[]
component_bodies={};component_leads={}
def register(obj):
 current.append(obj);return obj

def box(name,center,size,m,bevel=.0):
 bpy.ops.mesh.primitive_cube_add(size=1,location=center);o=bpy.context.object;o.name=name;o.dimensions=size;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(m)
 if bevel:
  mod=o.modifiers.new('Rounded package edge','BEVEL');mod.width=bevel;mod.segments=3
  o.modifiers.new('Weighted normals','WEIGHTED_NORMAL')
 return register(o)
def cyl(name,p1,p2,r,m,vertices=32):
 a,b=Vector(p1),Vector(p2);d=b-a;bpy.ops.mesh.primitive_cylinder_add(vertices=vertices,radius=r,depth=d.length,location=(a+b)/2)
 o=bpy.context.object;o.name=name;o.rotation_euler=d.to_track_quat('Z','Y').to_euler();o.data.materials.append(m)
 for poly in o.data.polygons:poly.use_smooth=True
 return register(o)
def wire(name,pts,r,m):
 curve=bpy.data.curves.new(name,'CURVE');curve.dimensions='3D';curve.resolution_u=2;curve.bevel_depth=r;curve.bevel_resolution=3
 s=curve.splines.new('POLY');s.points.add(len(pts)-1)
 for p,co in zip(s.points,pts):p.co=(*co,1)
 o=bpy.data.objects.new(name,curve);scene.collection.objects.link(o);o.data.materials.append(m);return register(o)
def text(name,body,loc,size,rot=0):
 bpy.ops.object.text_add(location=loc,rotation=(0,0,rot));o=bpy.context.object;o.name=name;o.data.body=body;o.data.size=size;o.data.align_x='CENTER';o.data.align_y='CENTER';o.data.extrude=.003;o.data.materials.append(mark);return register(o)
def stamped_pin(name,sections,thickness,m):
 # Flat stamped lead, lofted through horizontal rectangular sections.
 # Each section is (x,y,z,width along the package pin pitch).
 vs=[]
 for x,y,z,width in sections:
  vs.extend([(x-thickness/2,y-width/2,z),(x+thickness/2,y-width/2,z),(x+thickness/2,y+width/2,z),(x-thickness/2,y+width/2,z)])
 fs=[(3,2,1,0)]
 for i in range(len(sections)-1):
  a=4*i;b=a+4
  fs.extend([(a+j,a+(j+1)%4,b+(j+1)%4,b+j) for j in range(4)])
 fs.append(tuple(range(len(vs)-4,len(vs))))
 mesh=bpy.data.meshes.new(name);mesh.from_pydata(vs,[],fs);mesh.materials.append(m)
 obj=bpy.data.objects.new(name,mesh);scene.collection.objects.link(obj);return register(obj)
# Board dimensions are native. The top artwork is a direct orthographic crop of the unchanged CAD render.
# Exact 2 mm outline corner radii from native Edge.Cuts. Top artwork is UV mapped only to the board, never a rectangular screenshot plane.
verts2=[]
for cx,cy,start in [(83,-2,0),(2,-2,90),(2,-58,180),(83,-58,270)]:
 for i in range(17):
  a=math.radians(start+i*90/16);verts2.append((cx+2*math.cos(a),cy+2*math.sin(a)))
n=len(verts2);vs=[(x,y,z) for z in [-1.6,0] for x,y in verts2]
fs=[tuple(range(n-1,-1,-1)),tuple(range(n,n*2))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
mesh=bpy.data.meshes.new('Native rounded board outline');mesh.from_pydata(vs,[],fs);mesh.materials.append(boardmat)
board=bpy.data.objects.new('85 by 60 mm PCB',mesh);scene.collection.objects.link(board)
m=bpy.data.materials.new('Native top artwork');m.use_nodes=True;bs=m.node_tree.nodes.get('Principled BSDF');tex=m.node_tree.nodes.new('ShaderNodeTexImage');tex.image=bpy.data.images.load(str(HERE/'pcb_top_texture.png'));m.node_tree.links.new(tex.outputs['Color'],bs.inputs['Base Color']);bs.inputs['Roughness'].default_value=.65
mesh.materials.append(m);mesh.polygons[1].material_index=1
uv=mesh.uv_layers.new()
for poly in mesh.polygons:
 for li in poly.loop_indices:
  co=mesh.vertices[mesh.loops[li].vertex_index].co;uv.data[li].uv=(co.x/85,(co.y+60)/60)
for x,y in [(4,-4),(81,-4),(4,-56),(81,-56)]:
 bpy.ops.mesh.primitive_cylinder_add(vertices=64,radius=1.6,depth=6,location=(x,y,-.8));cut=bpy.context.object
 mod=board.modifiers.new('Native 3.2 mm mounting hole','BOOLEAN');mod.operation='DIFFERENCE';mod.object=cut
 bpy.context.view_layer.objects.active=board;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cut,do_unlink=True)
# Native plated pads preserve exact rect/circle/oval sizes. Holes are cut through the board and bounded by plated barrels.
allpads=[(ref,pad) for ref,p in parts.items() for pad in p['pads']]
# One disconnected drill-cutter mesh cuts every native component hole in a single Boolean operation.
verts=[];faces=[]
for ref,pad in allpads:
 base=len(verts);nseg=48;r=pad['drill']/2;x,y=pad['x'],-pad['y']
 for z in [-3,1]:
  for i in range(nseg):
   angle=2*math.pi*i/nseg;verts.append((x+r*math.cos(angle),y+r*math.sin(angle),z))
 faces.append(tuple(base+i for i in range(nseg-1,-1,-1)))
 faces.append(tuple(base+nseg+i for i in range(nseg)))
 for i in range(nseg):j=(i+1)%nseg;faces.append((base+i,base+j,base+nseg+j,base+nseg+i))
drillmesh=bpy.data.meshes.new('Native 71 hole cutters');drillmesh.from_pydata(verts,[],faces)
cut=bpy.data.objects.new('Native 71 hole cutters',drillmesh);scene.collection.objects.link(cut)
mod=board.modifiers.new('Native component drill holes','BOOLEAN');mod.operation='DIFFERENCE';mod.object=cut
bpy.context.view_layer.objects.active=board;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cut,do_unlink=True)
# Check the finished board mesh, rather than merely trusting cutter metadata.
drill_proof=[]
for ref,pad in allpads:
 x,y=pad['x'],-pad['y'];r=pad['drill']/2
 for scale in [0,.99,1.01]:
  for theta in [0,math.pi/2,math.pi,3*math.pi/2]:
   hit,point,normal,index=board.ray_cast(Vector((x+scale*r*math.cos(theta),y+scale*r*math.sin(theta),1)),Vector((0,0,-1)),distance=3)
   assert hit==(scale>1), f'Incorrect native drill mesh: {ref}.{pad["pin"]} radius {scale}'
 drill_proof.append({'ref':ref,'pin':pad['pin'],'inside_hole_ray_tests':8,'outside_hole_ray_tests':4,'passed':True})
(HERE/'drill_geometry_proof.json').write_text(json.dumps(drill_proof,indent=2))
pad_geometry=[]
def native_pad(ref,pad):
 width,height=pad['size_mm'];shape=pad['shape'];angle=math.radians(pad['angle_deg']);x,y=pad['x'],-pad['y'];rin=pad['drill']/2
 assert shape in ['rect','circle','oval']
 angles=sorted(set([2*math.pi*i/128 for i in range(128)]+[math.atan2(sy*height,sx*width)%(2*math.pi) for sx,sy in [(-1,-1),(-1,1),(1,-1),(1,1)]]))
 def radial_radius(theta):
  dx,dy=abs(math.cos(theta)),abs(math.sin(theta))
  if shape=='rect':return min(width/2/dx if dx>1e-12 else 1e12,height/2/dy if dy>1e-12 else 1e12)
  if shape=='circle':
   assert abs(width-height)<1e-9;return width/2
  # A native oval is a true stadium, not an ellipse. Equal dimensions reduce to a circle.
  if width>=height:
   c=(width-height)/2;r=height/2
   top=r/dy if dy>1e-12 else 1e12
   if top*dx<=c+1e-9:return top
   return c*dx+math.sqrt(max(0,r*r-c*c*dy*dy))
  c=(height-width)/2;r=width/2
  side=r/dx if dx>1e-12 else 1e12
  if side*dy<=c+1e-9:return side
  return c*dy+math.sqrt(max(0,r*r-c*c*dx*dx))
 outer=[];inner=[]
 for theta in angles:
  radius=radial_radius(theta);lx,ly=radius*math.cos(theta),radius*math.sin(theta)
  outer.append((x+lx*math.cos(angle)-ly*math.sin(angle),y+lx*math.sin(angle)+ly*math.cos(angle),.035))
  inner.append((x+rin*math.cos(theta+angle),y+rin*math.sin(theta+angle),.035))
 n=len(angles);vs=outer+inner+[(a,b,-1.6) for a,b,z in inner];fs=[]
 for i in range(n):
  j=(i+1)%n;fs.append((i,j,n+j,n+i));fs.append((n+i,n+j,2*n+j,2*n+i))
 mesh=bpy.data.meshes.new(f'Native {ref}.{pad["pin"]} {shape} pad');mesh.from_pydata(vs,[],fs);mesh.materials.append(gold);mesh.materials.append(silver)
 for i,poly in enumerate(mesh.polygons):poly.material_index=i%2
 obj=bpy.data.objects.new(f'Exposed pad {ref}.{pad["pin"]}',mesh);scene.collection.objects.link(obj)
 # Independent numeric outline proof is recorded before raster rendering.
 xs=[(v[0]-x)*math.cos(angle)+(v[1]-y)*math.sin(angle) for v in outer];ys=[-(v[0]-x)*math.sin(angle)+(v[1]-y)*math.cos(angle) for v in outer]
 assert abs(max(xs)-min(xs)-width)<1e-6 and abs(max(ys)-min(ys)-height)<1e-6
 assert rin < min(width,height)/2
 pad_geometry.append({'ref':ref,'pin':pad['pin'],'shape':shape,'native_size_mm':[width,height],'mesh_outer_size_mm':[max(xs)-min(xs),max(ys)-min(ys)],'native_angle_deg':pad['angle_deg'],'native_drill_mm':pad['drill'],'mesh_hole_diameter_mm':rin*2,'position_mm':[pad['x'],pad['y']],'outer_local_vertices_mm':[[a,b] for a,b in zip(xs,ys)],'inner_local_vertices_mm':[[(v[0]-x)*math.cos(angle)+(v[1]-y)*math.sin(angle),-(v[0]-x)*math.sin(angle)+(v[1]-y)*math.cos(angle)] for v in inner]})
for ref,pad in allpads:native_pad(ref,pad)
(HERE/'pad_geometry.json').write_text(json.dumps(pad_geometry,indent=2))
# Body dimensions are independent documentation overrides; native pads remain exact.
for ref,p in parts.items():
 current=[];pads=p['pads'];k=p['kind'];family=geometry['ref_family'][ref];g=geometry['families'][family]
 length,thick,height=g['body_dimensions_mm'];bottom=g['body_bottom_z_mm'];tip=g['lead_tip_z_mm'];body_objects=[];lead_objects=[]
 cx=sum(q['x'] for q in pads)/len(pads);cy=-sum(q['y'] for q in pads)/len(pads)
 if g['shape'] in ['axial','diode']:
  r=thick/2;z=bottom+r
  body_objects.append(cyl(ref+' body',(cx-length/2,cy,z),(cx+length/2,cy,z),r,blue if k=='R' else glass,64))
  for q in pads:
   x=q['x'];sign=1 if x<cx else -1;end=cx-sign*length/2
   obj=wire(ref+' formed lead '+q['pin'],[(x,cy,tip),(x,cy,z-.6),(x+sign*.6,cy,z),(end,cy,z)],g['lead_section_mm'][0]/2,silver)
   lead_objects.append((q,obj))
  if k=='R':
   for i,color in enumerate(p['bands']):
    offset=[-2.1,-1.25,-.4,.45,2.0][i];cyl(ref+' '+color+' band',(cx+offset-.2,cy,z),(cx+offset+.2,cy,z),r+.016,bandmats[color],64)
  else:cyl(ref+' cathode band',(cx-length/2+.35,cy,z),(cx-length/2+.9,cy,z),r+.02,black,64)
 elif g['shape']=='radial_resistor':
  body_objects.append(box(ref+' radial high resistance body',(cx,cy,bottom+height/2),(length,thick,height),blue,.75))
  for q in pads:
   x,y=q['x'],-q['y'];w,t=g['lead_section_mm']
   obj=box(ref+' flat terminal '+q['pin'],(x,y,(tip+bottom+.6)/2),(w,t,bottom+.6-tip),silver,.02)
   lead_objects.append((q,obj))
 elif g['shape']=='coated_radial':
  body_objects.append(box(ref+' compact coated ceramic body',(cx,cy,bottom+height/2),(length,thick,height),beige if ref=='C4' else ceramicblue,min(thick*.40,1.0)))
  for q in pads:
   x,y=q['x'],-q['y'];side=-1 if x<cx else 1;attach=cx+side*min(length*.30,abs(x-cx)*.8)
   # Formed shoulders reach outside the narrow body to the native pad pitch.
   # Lower coating profile and the undimensioned kink are illustrative.
   knee=x+side*.15
   pts=[(x,y,tip),(x,y,.65),(knee,y,.95),(attach,y,bottom+.6)]
   obj=wire(ref+' formed radial lead '+q['pin'],pts,g['lead_section_mm'][0]/2,silver)
   lead_objects.append((q,obj))
 elif g['shape']=='pdip':
  x0=cx-thick/2;x1=cx+thick/2;y0=cy+length/2
  body=box('U1 PDIP14 nominal body',(cx,cy,bottom+height/2),(thick,length,height),black,.22);body_objects.append(body)
  # Index cavity remains at the actual native pin1 end.
  top=bottom+height
  bpy.ops.mesh.primitive_cylinder_add(vertices=64,radius=1.05,depth=1.8,location=(cx,y0+.12,top-.6));cut=bpy.context.object
  mod=body.modifiers.new('Actual notch cavity','BOOLEAN');mod.operation='DIFFERENCE';mod.object=cut
  bpy.context.view_layer.objects.active=body;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cut,do_unlink=True)
  for q in pads:
   x,y=q['x'],-q['y'];inner=x0 if x<cx else x1;w,t=g['lead_section_mm'];wide=g['source_limits']['upper_lead_width_nom']
   sections=[(x,y,tip,w),(x,y,0,w),(x,y,.65,wide),(x,y,1.65,wide),(inner,y,bottom+height/2,wide)]
   obj=stamped_pin('U1 stamped pin '+q['pin'],sections,t,silver);lead_objects.append((q,obj))
  cyl('U1 pin1 index dot',(x0+.9,y0-1.45,top+.01),(x0+.9,y0-1.45,top+.03),.38,mark,40)
  text('Illustrative U1 identity','MCP6024',(cx,cy,top+.02),1.4,-math.pi/2)
  text('Illustrative U1 package','E/P',(cx+1.5,cy,top+.02),.85,-math.pi/2)
 elif g['shape']=='header':
  post_top=g['source_limits']['above_pcb_height'];post_length=post_top-tip
  for q in pads:
   x,y=q['x'],-q['y'];body_objects.append(box(ref+' insulator '+q['pin'],(x,y,height/2),(2.54,2.54,height),black,.10))
   obj=box(ref+' square post '+q['pin'],(x,y,(post_top+tip)/2),(.64,.64,post_length),gold,.045);lead_objects.append((q,obj))
 else:raise ValueError('Unknown documentation package '+family)
 component_bodies[ref]=body_objects;component_leads[ref]=lead_objects
 objects[ref]=list(current);print('Modeled',ref,'using',family,flush=True)
# Verify real evaluated body meshes and real lead sections at both board faces.
def evaluated_vertices(obj):
 depsgraph=bpy.context.evaluated_depsgraph_get();ev=obj.evaluated_get(depsgraph);mesh=ev.to_mesh()
 vertices=[tuple(obj.matrix_world @ v.co) for v in mesh.vertices];edges=[tuple(e.vertices) for e in mesh.edges]
 ev.to_mesh_clear();return vertices,edges

def bounds(vertices):return [min(v[a] for v in vertices) for a in range(3)],[max(v[a] for v in vertices) for a in range(3)]

def cross_section(vertices,edges,z):
 points=set()
 for a,b in edges:
  p,q=vertices[a],vertices[b]
  if abs(p[2]-z)<1e-6:points.add((round(p[0],7),round(p[1],7)))
  if abs(q[2]-z)<1e-6:points.add((round(q[0],7),round(q[1],7)))
  if (p[2]-z)*(q[2]-z)<0:
   t=(z-p[2])/(q[2]-p[2]);points.add((round(p[0]+t*(q[0]-p[0]),7),round(p[1]+t*(q[1]-p[1]),7)))
 return sorted(points)
proof=[]
for ref,p in parts.items():
 family=geometry['ref_family'][ref];g=geometry['families'][family];length,thick,height=g['body_dimensions_mm']
 verts=[v for obj in component_bodies[ref] for v in evaluated_vertices(obj)[0]];lo,hi=bounds(verts);actual=[hi[a]-lo[a] for a in range(3)]
 if g['shape']=='pdip':expected=[thick,length,height]
 elif g['shape']=='header':
  expected=[max(q['x'] for q in p['pads'])-min(q['x'] for q in p['pads'])+2.54,max(q['y'] for q in p['pads'])-min(q['y'] for q in p['pads'])+2.54,height]
 else:expected=[length,thick,height]
 assert max(abs(a-b) for a,b in zip(actual,expected))<2e-5,(ref,actual,expected)
 assert abs(lo[2]-g['body_bottom_z_mm'])<2e-5
 leads=[]
 for q,obj in component_leads[ref]:
  verts,edges=evaluated_vertices(obj);tip=min(v[2] for v in verts);assert abs(tip-g['lead_tip_z_mm'])<2e-5,(ref,q['pin'],tip)
  sections=[]
  for z in [0,-1.6]:
   section=cross_section(verts,edges,z);assert section,(ref,q['pin'],z)
   radius=max(math.hypot(x-q['x'],y+q['y']) for x,y in section)
   assert radius<q['drill']/2-1e-5,(ref,q['pin'],radius,q['drill'])
   sections.append({'plane_z_mm':z,'section_xy_vertices_mm':section})
  leads.append({'pin':q['pin'],'actual_tip_z_mm':tip,'actual_top_z_mm':max(v[2] for v in verts),'expected_tip_z_mm':g['lead_tip_z_mm'],'native_pad_mm':[q['x'],-q['y']],'sections':sections})
 proof.append({'ref':ref,'family':family,'body':{'actual_size_mm':actual,'expected_size_mm':expected,'min_z_mm':lo[2],'max_z_mm':hi[2],'mesh_names':[o.name for o in component_bodies[ref]]},'leads':leads})
(HERE/'component_geometry_proof.json').write_text(json.dumps({'schema_version':1,'source_sha256':{'renderer':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'geometry':hashlib.sha256((HERE/'component_geometry.json').read_bytes()).hexdigest(),'config':hashlib.sha256((HERE/'model_config.json').read_bytes()).hexdigest()},'components':proof,'passed':True},indent=2)+'\n')
# Neutral tabletop and soft studio light.
current=[];box('Backdrop',(42,-30,-4.5),(300,260,1),bg,.2)
for name,loc,power,size in [('Large softbox',(10,-5,110),150000,90),('Fill',(115,-70,80),90000,80)]:
 data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size;o=bpy.data.objects.new(name,data);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=(Vector((42,-30,0))-o.location).to_track_quat('-Z','Y').to_euler()
camdata=bpy.data.cameras.new('Assembly Camera');cam=bpy.data.objects.new('Assembly Camera',camdata);scene.collection.objects.link(cam);scene.camera=cam;camdata.type='ORTHO';camdata.lens=50

def camera(loc,look,scale):cam.location=loc;cam.rotation_euler=(Vector(look)-cam.location).to_track_quat('-Z','Y').to_euler();camdata.ortho_scale=scale

def show(refs):
 for r,objs in objects.items():
  for o in objs:o.hide_render=r not in refs

def render(name):
 if VALIDATE_ONLY or (ONLY_IMAGES is not None and name not in ONLY_IMAGES):return
 scene.render.filepath=str(HERE/name);bpy.ops.render.render(write_still=True)
# Save source scene with all objects; stages are controlled deterministically below.
show(order);camera((128,-125,142),(42.5,-30,0),112);render('assembled_isometric.png')
camera((42.5,-30,150),(42.5,-30,0),94);render('assembled_top.png')
# Top stages maintain a single alignment; selection is supplied as metadata for PDF callouts.
scene.cycles.samples=4;scene.render.resolution_x=1600;scene.render.resolution_y=1200
for i,ref in enumerate(order):
 show(order[:i+1]);render(f'stage_{i+1:02d}_{ref}.png')
# Closeup of actual notch and local C2 area with all components, for an orientation detail.
show(order);scene.render.resolution_x=1500;scene.render.resolution_y=1600;scene.cycles.samples=8
camera((29.8,-27.5,130),(29.8,-27.5,0),25);render('U1_C2_top_detail.png')
camera((65,-68,71),(29.5,-27.6,0),32);render('U1_C2_isometric_detail.png')
# Each isolated full-body model on white, for color code identification alongside real catalog photos.
scene.render.resolution_x=1400;scene.render.resolution_y=600
board.hide_render=True;o=None
for ob in scene.objects:
 if ob.name in ['Native PCB top artwork'] or ob.name.startswith('Exposed pad'):ob.hide_render=True
for ref in (['R1','R5','R6','R7','R10','R12','R3','D1','C2'] if '--include-isolated' in sys.argv else []):
 show([ref]);p=parts[ref];cx=sum(q['x'] for q in p['pads'])/len(p['pads']);cy=-sum(q['y'] for q in p['pads'])/len(p['pads']);span=24 if ref=='U1' else (23 if ref=='R3' else 16)
 camera((cx,cy-8,25),(cx,cy,2),span);render(f'part_{ref}.png')
# Source remains reusable without retaining a large blend cache. Deterministic meshes reconstruct from this script.
(HERE/'renders.json').write_text(json.dumps({'render_engine':'Blender Cycles CPU','blender_version':bpy.app.version_string,'stages':[{'step':i+1,'ref':r,'image':f'stage_{i+1:02d}_{r}.png','installed':order[:i+1]} for i,r in enumerate(order)],'top_camera':{'scale_mm':94,'width_px':1600,'height_px':1200,'center_mm':[42.5,30]},'component_geometry_sha256':hashlib.sha256((HERE/'component_geometry.json').read_bytes()).hexdigest(),'limitations':cfg['notes']+['Physical documentation bodies use sourced overrides independent of the conservative CAD envelopes. Seating and undimensioned coating and bend contours remain illustrative.']},indent=2))
