# phone-3d-scanning

**ObjectScan**, an iPhone app that scans objects with the LiDAR sensor and measures them: a live 3D mesh, a reticle that snaps to the scanned surface, point-to-point distances in cm or inches, and OBJ export. Python tools for checking scans on the Mac live alongside it.

## Install the app on your iPhone

```bash
./install-on-iphone.sh   # plug in and unlock the phone first
```

Or open `ObjectScan.xcodeproj` in Xcode (beta), pick your iPhone, and press Run. Needs an iPhone Pro with LiDAR.

**Using it:** move the phone slowly around the object until the mesh covers it. Aim the dot at one end and tap **+**, then aim at the other end and tap **+** again. Export saves the scan as `.obj` (metres) to share or AirDrop.

Vault hub: `Personal/Phone 3D Scanning/Phone 3D Scanning.md` (Obsidian).

## Python tools (optional, for checking scans on the Mac)

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
