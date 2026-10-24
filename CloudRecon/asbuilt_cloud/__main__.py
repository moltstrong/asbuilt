"""`python -m asbuilt_cloud build ...`: local CLI with the same flags as the Mac's `asbuilt-recon build`.

Runs the whole pipeline in this process/machine (needs CUDA for real use). The Modal deployment does
not call this directly; see ../cloud_build.py.
"""
import argparse
import json
import sys

from .pipeline import build


def parse_build_args(argv):
    ap = argparse.ArgumentParser(prog="asbuilt-cloud build")
    ap.add_argument("input", help="photos .zip or folder")
    ap.add_argument("--detail", default="full", choices=["full", "raw", "custom", "phone", "preview", "reduced", "medium"])
    ap.add_argument("--texture", default="8k", choices=["4k", "8k"])
    ap.add_argument("--max-polys", type=int, default=None)
    ap.add_argument("--maps", default="diffuse")
    ap.add_argument("--texture-format", default="jpeg:0.9")
    ap.add_argument("--out", required=True)
    ap.add_argument("--status-file", default=None)
    ap.add_argument("--title", default=None)
    ap.add_argument("--checkpoint", default=None, help="accepted for CLI compatibility (unused)")
    ap.add_argument("--obj", action="store_true")
    ap.add_argument("--steps", type=int, default=None, help="splat training steps (default $SPLAT_STEPS or 30000)")
    return ap.parse_args(argv)


def detail_from_args(a):
    """The Mac server sends the phone preset as `--detail custom --max-polys 250000 --texture 8k`."""
    d = a.detail
    if d in ("preview", "reduced", "medium"):
        d = "full"
    return d


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] != "build":
        print("usage: python -m asbuilt_cloud build <photos.zip|dir> --out DIR [--detail ...]", file=sys.stderr)
        return 2
    a = parse_build_args(argv[1:])
    r = build(a.input, a.out, detail=detail_from_args(a), texture=a.texture, max_polys=a.max_polys, obj=a.obj,
              status_file=a.status_file, title=a.title, steps=a.steps)
    print(json.dumps({k: r.get(k) for k in ("ok", "polygons", "totalSeconds", "errorMessage")}))
    return 0 if r.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
