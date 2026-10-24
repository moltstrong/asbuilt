"""AsBuilt cloud reconstruction pipeline (COLMAP/GLOMAP SfM -> Gaussian splat -> mesh -> USDZ/GLB).

The `build` CLI (python -m asbuilt_cloud build ...) accepts the same arguments as the Mac's
`asbuilt-recon build` and writes the same out/ layout (result.json, model.usdz, obj/, recon-log.txt,
thumbnail.png) plus splat.ply, so MacRecon/server/recon_server.py can drive it unchanged.
"""
__version__ = "0.1.0"
