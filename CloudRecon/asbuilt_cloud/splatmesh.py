"""Splat -> textured mesh (runs on CPU after GPU training; the cloud worker calls this).

1. render the splat's median depth (where transmittance crosses 0.5) from every training camera,
2. TSDF-fuse those depth maps (Open3D), crop to the object region,
3. clean (largest components), quadric-decimate to the triangle budget,
4. xatlas UV unwrap, bake the *real photos* (not splat colors) into the texture,
5. move into a Y-up frame with the object's foot at the origin.

The same code produced CloudRecon/bakeoff results on the M4 Mac (see README).
"""
import os
import time

import numpy as np

from . import colmap_io, meshing


def splat_to_mesh(ply, undist, work, log, max_tris=250000, texture=8192, depth_scale=0.5, voxel_frac=0.0015,
                  meters_per_unit=None, progress=None, renderer=None):
    from PIL import Image
    if renderer is None:
        from . import splatrender_gpu
        if os.environ.get("SPLAT_DEPTH_GPU", "1") == "1" and splatrender_gpu.available():
            renderer = splatrender_gpu
        else:
            from . import splatrender as renderer
    log("splat->mesh depth renderer: %s" % renderer.__name__)
    t0 = time.time()
    cams = colmap_io.load_pinhole_model(os.path.join(undist, "sparse"))
    xyz, _, _, _ = colmap_io.read_points3d_bin(os.path.join(undist, "sparse", "points3D.bin"))
    reg = meshing.object_region(cams, xyz)
    g = renderer.load_ply(ply)
    log("splat->mesh: %d gaussians, %d cameras, crop radius %.3f" % (len(g["xyz"]), len(cams), reg["radius"]))

    def depth_iter():
        for k, cam in enumerate(cams):
            c = cam.scaled(depth_scale)
            rgb, alpha, dmed, _ = renderer.render(g, c.R, c.t, c.fx, c.fy, c.cx, c.cy, c.width, c.height, want_depth=True)
            d = np.where(alpha > 0.5, dmed, 0).astype(np.float32)
            if os.environ.get("SPLAT_MASK_DEPTH_EDGES") == "1":  # experimental; worse on the bake-off (see README)
                d = meshing.mask_depth_edges(d)
            if progress:
                progress("meshGeneration", 0.8 * (k + 1) / len(cams), "Building mesh")
            yield c, d, (rgb * 255).astype(np.uint8)

    bounds = meshing.region_bounds(reg, xyz)
    voxel = voxel_frac * float(np.linalg.norm(np.subtract(bounds[1], bounds[0])))
    V, F, _ = meshing.tsdf_mesh(cams, depth_iter(), voxel=voxel, bounds=bounds)
    log("tsdf: %d verts %d tris" % (len(V), len(F)))
    V, F = meshing.clean_mesh(V, F, region=reg, target_tris=max_tris)
    log("clean+decimate: %d verts %d tris" % (len(V), len(F)))
    if len(F) < 100:
        from .pipeline import PipelineError
        raise PipelineError("The mesh came out empty. The object may be too thin or too shiny for this method.")
    if progress:
        progress("textureMapping", 0.0, "Painting textures")
    V2, F2, UV, _ = meshing.unwrap(V, F, texture)

    def load_image(cam):
        return np.asarray(Image.open(os.path.join(undist, "images", cam.name)).convert("RGB"), dtype=np.float32) / 255.0

    tex, cov = meshing.bake_texture(V2, F2, UV, F2, cams, load_image, texture)
    log("bake: %dpx, %.1f%% of atlas texels seen by a photo" % (texture, 100 * cov))
    up = reg["up"]
    x = np.cross(up, [0, 0, 1.0]); x /= np.linalg.norm(x); z = np.cross(x, up)
    Rw = np.stack([x, up, z])
    origin = reg["center"] + up * reg["bottom"]
    scale_source = "arbitrary (SfM units)"
    if meters_per_unit is None:
        meters_per_unit = 1.0
    else:
        scale_source = "provided"
    Vout = (V2 - origin) @ Rw.T * meters_per_unit
    # thumbnail camera: first training camera, moved into the output frame
    c0 = cams[0]
    Rt = c0.R @ Rw.T
    tt = c0.t + c0.R @ origin
    thumb = colmap_io.Camera(c0.name, Rt, tt * meters_per_unit, c0.fx, c0.fy, c0.cx, c0.cy, c0.width, c0.height)
    log("splat->mesh done in %.1fs" % (time.time() - t0))
    return {"V": Vout, "F": F2, "UV": UV, "texture": tex, "coverage": cov, "gaussians": int(len(g["xyz"])),
            "metersPerUnit": meters_per_unit, "scaleSource": scale_source, "thumbCam": thumb}
