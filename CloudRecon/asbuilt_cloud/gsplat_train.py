"""Train a 3DGS splat with gsplat's (Apache-2.0) examples/simple_trainer.py, configured programmatically
(no CLI parsing surprises). MCMC densification (Kheradmand et al. 2024), capped Gaussian count.

    python -m asbuilt_cloud.gsplat_train <undist_dir> <result_dir> --steps 30000 --cap 1500000

normalize_world_space is OFF so the exported PLY lives in the COLMAP frame, which the splat->mesh
stage (and the cameras.json we ship) use. Prints "PROGRESS <step> <total>" lines for the status bar.
"""
import argparse
import os
import sys


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("data_dir")
    ap.add_argument("result_dir")
    ap.add_argument("--steps", type=int, default=30000)
    ap.add_argument("--cap", type=int, default=1500000)
    ap.add_argument("--examples", default=os.environ.get("GSPLAT_EXAMPLES", "/opt/gsplat/examples"))
    a = ap.parse_args(argv)
    sys.path.insert(0, a.examples)
    os.chdir(a.examples)
    import simple_trainer as st  # noqa: E402  (gsplat examples)
    from gsplat.strategy import MCMCStrategy

    cfg = st.Config(init_opa=0.5, init_scale=0.1, opacity_reg=0.01, scale_reg=0.01,
                    strategy=MCMCStrategy(verbose=False, cap_max=a.cap))
    cfg.disable_viewer = True
    cfg.disable_video = True
    cfg.data_dir = a.data_dir
    cfg.result_dir = a.result_dir
    cfg.data_factor = 1
    cfg.normalize_world_space = False
    cfg.antialiased = True
    cfg.max_steps = a.steps
    cfg.save_ply = True
    cfg.ply_steps = [a.steps]
    cfg.eval_steps = [a.steps]
    cfg.save_steps = [a.steps]
    # gsplat holds out image indices i % test_every == 0; a huge value holds out only image 0 (a sanity metric).
    cfg.test_every = 1_000_000
    cfg.adjust_steps(cfg.steps_scaler)

    # tqdm drives the progress bar inside Runner.train; mirror it as plain lines for the parent.
    import tqdm as _tqdm
    orig = _tqdm.tqdm

    class _T(orig):
        def update(self, n=1):
            r = super().update(n)
            if self.n % 250 == 0:
                print("PROGRESS %d %d" % (self.n, a.steps), flush=True)
            return r

    st.tqdm.tqdm = _T
    st.main(0, 0, 1, cfg)
    print("PROGRESS %d %d" % (a.steps, a.steps), flush=True)


if __name__ == "__main__":
    main()
