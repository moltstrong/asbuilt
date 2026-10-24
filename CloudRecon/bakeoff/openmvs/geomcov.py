"""Geometry-only coverage of a mesh (COLMAP frame) at the 6 held-out cameras, inside B's object mask
(Apple phone silhouette eroded 4 px). usage: geomcov.py <mesh.ply> <tag>"""
import os
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import binary_erosion

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.environ.get("CLOUDRECON_DIR", os.path.expanduser("~/projects/asbuilt/CloudRecon")))
from crop_mesh import read_ply_mesh as read_ply  # noqa: E402
from asbuilt_cloud import export  # noqa: E402
import open3d as o3d  # noqa: E402

V, F = read_ply(sys.argv[1]); tag = sys.argv[2]
m = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(V), o3d.utility.Vector3iVector(F))
if len(F) > 1500000:
    m = m.simplify_quadric_decimation(1500000)
V, F = np.asarray(m.vertices), np.asarray(m.triangles)
d = os.path.join(HERE, "cov_" + tag); os.makedirs(d, exist_ok=True)
export.write_usdz(d + "/m.usdz", V, F, np.zeros((len(V), 2)) + .5, np.full((4, 4, 3), 200, np.uint8), d + "/usd")
subprocess.check_call([os.path.join(HERE, "..", "b", "meshrender", "meshrender"), d + "/m.usdz",
                       os.path.join(HERE, "check_r1", "cams_held.json"), d + "/r", "constant"], stdout=subprocess.DEVNULL)
out = []
for v in ("IMG_1024", "IMG_1031", "IMG_1038", "IMG_1046", "IMG_1053", "IMG_1060"):
    a = np.asarray(Image.open(os.path.join(HERE, "..", "b", "eval", "apple_phone_constant", v + ".png")).convert("RGBA"))[..., 3] > 127
    mk = binary_erosion(a, iterations=4)
    c = np.asarray(Image.open(d + "/r/%s.png" % v).convert("RGBA"))[..., 3] > 127
    out.append(c[mk].mean())
print(tag, "coverage per view", np.round(out, 3), "mean %.4f" % np.mean(out))
