"""Check that the 3D vision toolchain works, not just imports."""
import numpy as np, cv2, open3d as o3d, pycolmap, scipy, trimesh, matplotlib

print("numpy", np.__version__, "| scipy", scipy.__version__, "| opencv", cv2.__version__,
      "| open3d", o3d.__version__, "| pycolmap", pycolmap.__version__, "| trimesh", trimesh.__version__)

# 1. OpenCV SIFT on a random-texture image
img = (np.random.default_rng(0).random((480, 640)) * 255).astype(np.uint8)
img = cv2.GaussianBlur(img, (5, 5), 0)
kp, des = cv2.SIFT_create().detectAndCompute(img, None)
assert len(kp) > 50, len(kp)
print(f"SIFT: {len(kp)} keypoints")

# 2. Project points with two cameras, triangulate them back
K = np.array([[1500., 0, 960], [0, 1500., 540], [0, 0, 1]])
X = np.random.default_rng(1).uniform([-1, -1, 4], [1, 1, 6], (50, 3))
R2, _ = cv2.Rodrigues(np.array([0, 0.1, 0]))
P1 = K @ np.hstack([np.eye(3), np.zeros((3, 1))])
P2 = K @ np.hstack([R2, np.array([[-0.5], [0], [0]])])
def proj(P, X):
    x = P @ np.hstack([X, np.ones((len(X), 1))]).T
    return x[:2] / x[2]
Xh = cv2.triangulatePoints(P1, P2, proj(P1, X), proj(P2, X))
err = np.abs((Xh[:3] / Xh[3]).T - X).max()
assert err < 1e-6, err
print(f"Triangulation round-trip max error: {err:.1e}")

# 3. Open3D point cloud + plane fit
pts = np.c_[np.random.rand(1000, 2), np.zeros(1000)]
pcd = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(pts))
plane, inliers = pcd.segment_plane(0.01, 3, 100)
assert len(inliers) == 1000
print("Open3D plane fit:", np.round(plane, 3))

# 4. pycolmap rotation
r = pycolmap.Rotation3d(np.array([0, 0, 0, 1.0]))  # identity, [x,y,z,w]
assert np.allclose(r.matrix(), np.eye(3))
print("pycolmap Rotation3d OK")
print("ALL CHECKS PASSED")
