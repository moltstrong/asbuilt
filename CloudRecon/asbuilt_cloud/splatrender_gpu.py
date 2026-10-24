"""GPU splat renderer via gsplat.rasterization (CUDA), same interface as splatrender.render.

Used by splatmesh on the cloud GPU: ~1.5M Gaussians x 41 views of depth takes seconds here vs ~15 min
with the numba CPU renderer. Returns expected depth (alpha-normalized) as both depth outputs, since
gsplat's 3DGS rasterizer has no median-depth mode; TSDF fusion averages it out.
NOT exercised on the Mac (no CUDA): splatmesh falls back to the CPU renderer if this raises.
"""
import numpy as np

_cache = {}


def _to_torch(g):
    import torch
    key = id(g)
    if key in _cache:
        return _cache[key]
    dev = "cuda"
    sh = np.concatenate([g["dc"][:, None, :], g["rest"]], axis=1)  # [N, K, 3]
    k = sh.shape[1]
    deg = {1: 0, 4: 1, 9: 2, 16: 3}[k]
    t = dict(means=torch.tensor(g["xyz"], dtype=torch.float32, device=dev),
             quats=torch.tensor(g["quat"], dtype=torch.float32, device=dev),
             scales=torch.tensor(g["scales"], dtype=torch.float32, device=dev),
             opacities=torch.tensor(g["opacity"], dtype=torch.float32, device=dev),
             colors=torch.tensor(sh, dtype=torch.float32, device=dev), sh_degree=deg)
    _cache.clear()
    _cache[key] = t
    return t


def render(g, R, t, fx, fy, cx, cy, W, H, bg=(0, 0, 0), want_depth=False):
    import torch
    from gsplat.rendering import rasterization
    T = _to_torch(g)
    view = torch.eye(4, device="cuda")
    view[:3, :3] = torch.tensor(R, dtype=torch.float32, device="cuda")
    view[:3, 3] = torch.tensor(t, dtype=torch.float32, device="cuda")
    K = torch.tensor([[fx, 0, cx], [0, fy, cy], [0, 0, 1]], dtype=torch.float32, device="cuda")
    with torch.no_grad():
        out, alpha, _ = rasterization(T["means"], T["quats"], T["scales"], T["opacities"], T["colors"],
                                      view[None], K[None], int(W), int(H), sh_degree=T["sh_degree"],
                                      render_mode="RGB+ED", rasterize_mode="antialiased",
                                      backgrounds=torch.tensor([bg], dtype=torch.float32, device="cuda"))
    out = out[0].float().cpu().numpy()
    a = alpha[0, ..., 0].float().cpu().numpy()
    rgb = np.clip(out[..., :3], 0, 1)
    d = out[..., 3]
    return rgb, a, d, d


def load_ply(path):
    from .splatrender import load_ply as _l
    return _l(path)


def available():
    try:
        import torch
        import gsplat  # noqa: F401
        return torch.cuda.is_available()
    except Exception:  # noqa: BLE001
        return False
