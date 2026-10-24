import sys, os, time, numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import read_cameras_bin, read_images_bin, qvec2rotmat, psnr
import splatrender as sr
ply, evaldir = sys.argv[1], sys.argv[2]
g = sr.load_ply(ply); print("splats", len(g["xyz"]), "sh coeffs", g["rest"].shape[1] + 1)
cam = list(read_cameras_bin("undist/sparse/cameras.bin").values())[0]; fx, fy, cx, cy = cam["params"]
imgs = read_images_bin("undist/sparse/images.bin")
for n in ["IMG_1031.jpg"]:
    im = imgs[n]; t0 = time.time()
    rgb, a = sr.render(g, qvec2rotmat(im["q"]), im["t"], fx, fy, cx, cy, 2000, 1500)
    mine = (rgb * 255 + 0.5).astype(np.uint8)
    Image.fromarray(mine).save("eval/myrender_%s.png" % n[:-4])
    brush = np.array(Image.open(os.path.join(evaldir, n[:-4] + ".png")).convert("RGB"))
    gt = np.array(Image.open("undist/images/" + n).convert("RGB"))
    print(n, "%.1fs" % (time.time() - t0), "mine-vs-brush PSNR %.2f" % psnr(mine, brush), "mine-vs-gt %.2f" % psnr(mine, gt), "brush-vs-gt %.2f" % psnr(brush, gt))
