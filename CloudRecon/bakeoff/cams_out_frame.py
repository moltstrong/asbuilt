"""Write meshrender cameras for a mesh in splat2mesh's output frame: the 6 held-out cams + 2 hero views."""
import json, sys, os, numpy as np
sys.path.insert(0, '/Users/moltstrong/projects/asbuilt/CloudRecon')
from asbuilt_cloud import colmap_io
mdir = sys.argv[1]
info = json.load(open(os.path.join(mdir, 'splat2mesh.json')))
Rw = np.array(info['toOutput']['R']); origin = np.array(info['toOutput']['origin']); s = info['toOutput']['scale']
cams = {c.name: c for c in colmap_io.load_pinhole_model('undist/sparse')}
held = [l.strip().replace('.JPG', '.jpg') for l in open('heldout.txt') if l.strip()]
flip = np.diag([1, -1, -1.0])  # OpenCV cam axes -> SceneKit cam axes
out = []
for n in held:
    c = cams[n]
    C = (c.center - origin) @ Rw.T * s
    Rc2w = Rw @ c.R.T @ flip
    T = np.eye(4); T[:3, :3] = Rc2w; T[:3, 3] = C
    out.append({"name": n[:-4], "c2w": T.flatten().tolist(), "fovY": float(np.degrees(2 * np.arctan(c.height / 2 / c.fy))), "width": c.width, "height": c.height})
json.dump(out, open(os.path.join(mdir, 'cams_held.json'), 'w'))
print(len(out))
