"""Model export on Linux: OBJ(+MTL+JPEG) and USDZ written with Pixar's `usd-core` (pip), no Apple tools.

The USDZ uses UsdPreviewSurface with the diffuse texture (unlit-friendly, opens in AR Quick Look /
SceneKit / RealityKit). Up axis Y, meters (we rescale to metric when the caller knows the scale).
"""
import os
import shutil
import zipfile

import numpy as np


def write_obj(out_dir, V, F, UV, texture_rgb, name="model", jpeg_quality=90):
    """V (n,3), F (m,3) int, UV (n,2) per-vertex (seams already split), texture HxWx3 uint8."""
    from PIL import Image
    os.makedirs(out_dir, exist_ok=True)
    tex_name = name + "_diffuse.jpg"
    Image.fromarray(texture_rgb).save(os.path.join(out_dir, tex_name), quality=jpeg_quality)
    with open(os.path.join(out_dir, name + ".mtl"), "w") as f:
        f.write("newmtl material0\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nillum 1\nmap_Kd %s\n" % tex_name)
    with open(os.path.join(out_dir, name + ".obj"), "w") as f:
        f.write("# asbuilt-cloud\nmtllib %s.mtl\nusemtl material0\n" % name)
        np.savetxt(f, V, fmt="v %.6f %.6f %.6f")
        np.savetxt(f, UV, fmt="vt %.6f %.6f")
        Fi = F + 1
        np.savetxt(f, np.stack([Fi[:, 0], Fi[:, 0], Fi[:, 1], Fi[:, 1], Fi[:, 2], Fi[:, 2]], 1), fmt="f %d/%d %d/%d %d/%d")
    return os.path.join(out_dir, name + ".obj")


def zip_dir(src_dir, dest_zip):
    with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_STORED) as z:
        for n in sorted(os.listdir(src_dir)):
            z.write(os.path.join(src_dir, n), n)
    return dest_zip


def write_usdz(dest, V, F, UV, texture_rgb, work_dir, jpeg_quality=90, meters_per_unit=1.0, title="model"):
    """Writes a single-mesh USDZ with a UsdPreviewSurface + diffuse JPEG. Returns path."""
    from PIL import Image
    from pxr import Gf, Kind, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt
    os.makedirs(work_dir, exist_ok=True)
    tex_rel = "textures/diffuse.jpg"
    os.makedirs(os.path.join(work_dir, "textures"), exist_ok=True)
    Image.fromarray(texture_rgb).save(os.path.join(work_dir, tex_rel), quality=jpeg_quality)
    usdc = os.path.join(work_dir, "model.usdc")
    stage = Usd.Stage.CreateNew(usdc)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    UsdGeom.SetStageMetersPerUnit(stage, meters_per_unit)
    root = UsdGeom.Xform.Define(stage, "/Root")
    Usd.ModelAPI(root.GetPrim()).SetKind(Kind.Tokens.component)
    stage.SetDefaultPrim(root.GetPrim())
    root.GetPrim().SetDocumentation(title)
    mesh = UsdGeom.Mesh.Define(stage, "/Root/Geom")
    mesh.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(V.astype(np.float32)))
    mesh.CreateFaceVertexCountsAttr(Vt.IntArray.FromNumpy(np.full(len(F), 3, np.int32)))
    mesh.CreateFaceVertexIndicesAttr(Vt.IntArray.FromNumpy(F.astype(np.int32).ravel()))
    mesh.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    mesh.CreateDoubleSidedAttr(False)
    lo, hi = V.min(0), V.max(0)
    mesh.CreateExtentAttr(Vt.Vec3fArray([Gf.Vec3f(*map(float, lo)), Gf.Vec3f(*map(float, hi))]))
    pv = UsdGeom.PrimvarsAPI(mesh).CreatePrimvar("st", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.vertex)
    pv.Set(Vt.Vec2fArray.FromNumpy(UV.astype(np.float32)))
    # normals (smooth, per vertex)
    from .meshing import vertex_normals
    mesh.CreateNormalsAttr(Vt.Vec3fArray.FromNumpy(vertex_normals(V, F).astype(np.float32)))
    mesh.SetNormalsInterpolation(UsdGeom.Tokens.vertex)

    mat = UsdShade.Material.Define(stage, "/Root/Materials/Mat")
    shader = UsdShade.Shader.Define(stage, "/Root/Materials/Mat/Surface")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.9)
    shader.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    reader = UsdShade.Shader.Define(stage, "/Root/Materials/Mat/stReader")
    reader.CreateIdAttr("UsdPrimvarReader_float2")
    reader.CreateInput("varname", Sdf.ValueTypeNames.String).Set("st")
    tex = UsdShade.Shader.Define(stage, "/Root/Materials/Mat/Diffuse")
    tex.CreateIdAttr("UsdUVTexture")
    tex.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(tex_rel)
    tex.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(reader.ConnectableAPI(), "result")
    tex.CreateInput("wrapS", Sdf.ValueTypeNames.Token).Set("clamp")
    tex.CreateInput("wrapT", Sdf.ValueTypeNames.Token).Set("clamp")
    tex.CreateInput("sourceColorSpace", Sdf.ValueTypeNames.Token).Set("sRGB")
    tex.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(tex.ConnectableAPI(), "rgb")
    mat.CreateSurfaceOutput().ConnectToSource(shader.ConnectableAPI(), "surface")
    UsdShade.MaterialBindingAPI.Apply(mesh.GetPrim()).Bind(mat)
    stage.GetRootLayer().Save()
    if os.path.exists(dest):
        os.remove(dest)
    ok = UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(usdc), dest)
    if not ok:
        raise RuntimeError("UsdUtils.CreateNewUsdzPackage failed")
    return dest


def check_usdz(path):
    """Validate with usd-core's UsdValidation framework (USD >= 24.11 replaced UsdUtils.ComplianceChecker):
    every registered validator (USDZ packaging, root package, file extensions, missing references,
    material bindings, shader compliance, stage metadata, ...). Returns (passed, messages).
    Note: Apple's `usdchecker --arkit` adds ARKit-only rules on top; run it on a Mac for the final word."""
    from pxr import Usd, UsdValidation
    reg = UsdValidation.ValidationRegistry()
    validators = reg.GetOrLoadAllValidators()
    ctx = UsdValidation.ValidationContext(validators)
    stage = Usd.Stage.Open(path)
    errs = ctx.Validate(stage)
    msgs = ["%s: %s" % (e.GetName(), e.GetMessage()) for e in errs]
    hard = [e for e in errs if e.GetType() == UsdValidation.ValidationErrorType.Error]
    return len(hard) == 0, msgs


def thumbnail(dest, V, F, UV, texture_rgb, cam, size=512):
    """Unlit textured render of the mesh from `cam` (a colmap_io.Camera), letterboxed to a square PNG."""
    from PIL import Image
    from .meshing import _zbuffer  # noqa: F401  (ensures numba compiled)
    W = size; H = int(round(size * cam.height / cam.width))
    s = W / cam.width
    c = cam.scaled(s)
    Xc = V @ c.R.T + c.t
    z = np.maximum(Xc[:, 2], 1e-9)
    px = c.fx * Xc[:, 0] / z + c.cx; py = c.fy * Xc[:, 1] / z + c.cy
    img = np.full((H, W, 3), 245, np.uint8)
    # painter's algorithm per triangle centroid at low res is enough for a thumbnail
    order = np.argsort(-z[F].mean(1))
    from PIL import ImageDraw
    canvas = Image.fromarray(img)
    d = ImageDraw.Draw(canvas)
    th, tw = texture_rgb.shape[:2]
    uvc = UV[F].mean(1)
    cols = texture_rgb[np.clip(((1 - uvc[:, 1]) * th).astype(int), 0, th - 1), np.clip((uvc[:, 0] * tw).astype(int), 0, tw - 1)]
    for fi in order:
        tri = F[fi]
        if (Xc[tri, 2] <= 0).any():
            continue
        d.polygon([(px[k], py[k]) for k in tri], fill=tuple(int(x) for x in cols[fi]))
    sq = Image.new("RGB", (size, size), (245, 245, 245))
    sq.paste(canvas, (0, (size - H) // 2))
    sq.save(dest)
    return dest


def copy_tree_files(src, dst):
    os.makedirs(dst, exist_ok=True)
    for n in os.listdir(src):
        shutil.copy2(os.path.join(src, n), os.path.join(dst, n))
