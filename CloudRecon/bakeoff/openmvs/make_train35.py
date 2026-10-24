"""Build c/train35/ = COLMAP dense workspace (images/ symlinks + sparse/*.txt) with the 6 held-out photos REMOVED:
their images, poses and every track observation (points left with < 2 observations are dropped).
Poses/intrinsics are B's (b/undist, PINHOLE 2000x1500): exactly what the splat and splat->mesh used.
Text processing of COLMAP's own text export (pycolmap 4.x writes cameras/images/points3D/frames/rigs .txt).
"""
import os
import shutil

import pycolmap

HERE = os.path.dirname(os.path.abspath(__file__))
B = os.path.join(HERE, "..", "b")
held = {l.strip().replace(".JPG", ".jpg") for l in open(os.path.join(B, "heldout.txt")) if l.strip()}
out = os.path.join(HERE, "train35")
shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "images"))
full = os.path.join(out, "sparse_full")
os.makedirs(full)
sp = os.path.join(out, "sparse")
os.makedirs(sp)
pycolmap.Reconstruction(os.path.join(B, "undist", "sparse")).write_text(full)

# images.txt: header lines (#), then 2 lines per image
lines = open(os.path.join(full, "images.txt")).read().splitlines()
hdr = [l for l in lines if l.startswith("#")]
body = [l for l in lines if not l.startswith("#")]
keep, drop_ids, names = [], set(), []
for i in range(0, len(body), 2):
    f = body[i].split()
    iid, name = int(f[0]), f[9]
    if name in held:
        drop_ids.add(iid)
        continue
    names.append(name)
    # drop 2D points that observe a 3D point we may delete later -> simpler: keep 2D list, set point3D id -1 if needed
    keep.append((iid, body[i], body[i + 1]))
assert len(drop_ids) == 6 and len(names) == 35

# points3D.txt: ID X Y Z R G B ERR (IMAGE_ID POINT2D_IDX)*
pts_out, kept_pts = [], set()
for l in open(os.path.join(full, "points3D.txt")).read().splitlines():
    if l.startswith("#"):
        continue
    f = l.split()
    track = [(int(f[k]), int(f[k + 1])) for k in range(8, len(f), 2)]
    track = [(a, b) for a, b in track if a not in drop_ids]
    if len(track) < 2:
        continue
    kept_pts.add(int(f[0]))
    pts_out.append(" ".join(f[:8] + ["%d %d" % t for t in track]))

with open(os.path.join(sp, "images.txt"), "w") as fo:
    fo.write("\n".join(hdr) + "\n")
    for iid, l1, l2 in keep:
        f2 = l2.split()
        for k in range(2, len(f2), 3):
            if f2[k] != "-1" and int(f2[k]) not in kept_pts:
                f2[k] = "-1"
        fo.write(l1 + "\n" + " ".join(f2) + "\n")
with open(os.path.join(sp, "points3D.txt"), "w") as fo:
    fo.write("# 3D point list\n" + "\n".join(pts_out) + "\n")
shutil.copy(os.path.join(full, "cameras.txt"), os.path.join(sp, "cameras.txt"))
shutil.rmtree(full)
for n in names:
    os.symlink(os.path.realpath(os.path.join(B, "undist", "images", n)), os.path.join(out, "images", n))
txt = open(os.path.join(sp, "images.txt")).read()
assert not any(h in txt for h in held), "held-out image still referenced"
print("ok: %d images, %d points (held-out images and their observations removed)" % (len(names), len(pts_out)))
