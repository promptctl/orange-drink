import sys, cv2, numpy as np
src, out = sys.argv[1], sys.argv[2]
img = cv2.imread(src, cv2.IMREAD_COLOR).astype(np.float32) / 255
# Edge map: where the art has real detail. Block seams are far weaker than these edges.
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3); gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
mag = cv2.GaussianBlur(np.sqrt(gx*gx + gy*gy), (0, 0), 3)
detail = np.clip((mag - 0.06) / 0.10, 0, 1)            # 0 = flat background, 1 = edges
detail = cv2.dilate(detail, np.ones((9, 9), np.uint8))
detail = cv2.GaussianBlur(detail, (0, 0), 4)[..., None]
# Flat areas: guided filter with a wide radius dissolves the blocks but keeps band edges.
smooth = cv2.ximgproc.guidedFilter(img, img, radius=24, eps=0.0025)
mixed = smooth * (1 - detail) + img * detail
# Fresh, even grain so the background isn't plasticky.
rng = np.random.default_rng(7)
grain = cv2.GaussianBlur(rng.normal(0, 1, gray.shape).astype(np.float32), (0, 0), 0.7)[..., None]
mixed = np.clip(mixed + grain * 0.012, 0, 1)
cv2.imwrite(out, (mixed * 255 + 0.5).astype(np.uint8))
cv2.imwrite(out.replace('.png', '-mask.png'), ((1 - detail[..., 0]) * 255).astype(np.uint8))
