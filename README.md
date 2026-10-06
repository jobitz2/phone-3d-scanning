# phone-3d-scanning

3D reconstruction from an iPhone Pro (video structure-from-motion and LiDAR), then measuring real objects from the scans. A learning project: implement the geometry in NumPy first, then check it against OpenCV, COLMAP and Open3D.

Vault hub: `Personal/Phone 3D Scanning/Phone 3D Scanning.md` (Obsidian).

## Setup

```bash
brew install colmap          # sparse SfM (CPU on Apple Silicon; dense MVS needs CUDA)
uv sync                      # Python 3.12 + numpy, scipy, opencv, open3d, pycolmap 4.2.1, trimesh, jupyterlab
uv run python smoke_test.py  # should end with "ALL CHECKS PASSED"
```

`pycolmap` is pinned to 4.2.1 because hloc still calls `pycolmap.Sift`, which was removed after 4.2.

## Layout

- `src/`: your own implementations (projection, triangulation, essential matrix, back-projection)
- `notebooks/`: experiments (`uv run jupyter lab`)
- `data/`: captures, extracted frames, COLMAP outputs (git-ignored)

## Frame extraction

```bash
ffmpeg -i IMG_1234.MOV -vf "fps=2,scale=1920:-2" -q:v 2 data/<scan>/frames/%04d.jpg
```

Record SDR (HDR off), at 1x, with stabilization off (Blackmagic Camera or Final Cut Camera).
