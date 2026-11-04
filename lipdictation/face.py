"""Face landmarks -> 96x96 grayscale mouth crops, aligned the way the model was trained.

MediaPipe FaceLandmarker gives 478 points per frame. We reduce them to the four
anchors the Auto-AVSR crop uses (right eye, left eye, nose base, mouth centre),
smooth them over a short window, warp each frame onto the training mean face
and cut a 96x96 patch around the mouth.
"""
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import BaseOptions, vision

DATA = Path(__file__).parent / "data"
CROP = 96
SMOOTH = 12          # frames in the landmark smoothing window

# MediaPipe face-mesh indices for the dlib-68 groups the mean face is built from.
EYE_A = [33, 160, 158, 133, 153, 144]
EYE_B = [362, 385, 387, 263, 373, 380]
NOSE_BASE = [98, 97, 2, 326, 327]
MOUTH = [61, 39, 37, 0, 267, 269, 291, 405, 314, 17, 84, 181,
         78, 82, 13, 312, 308, 317, 14, 87]


def _reference():
    ref = np.load(DATA / "20words_mean_face.npy")
    return np.vstack([ref[36:42].mean(0), ref[42:48].mean(0), ref[31:36].mean(0), ref[48:68].mean(0)])


REFERENCE = _reference()


class FaceTracker:
    """Finds the four anchors in each frame. Feed frames in time order."""

    def __init__(self, model_path):
        self.landmarker = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(model_path)),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            min_face_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        ))
        self.last_ts = -1

    def anchors(self, rgb, ts_ms):
        """(4, 2) pixel anchors for an RGB frame, or None when no face is seen."""
        ts_ms = max(int(ts_ms), self.last_ts + 1)   # MediaPipe needs increasing timestamps
        self.last_ts = ts_ms
        result = self.landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), ts_ms)
        if not result.face_landmarks:
            return None
        h, w = rgb.shape[:2]
        pts = np.array([(p.x * w, p.y * h) for p in result.face_landmarks[0]], dtype=np.float32)
        eye_a, eye_b = pts[EYE_A].mean(0), pts[EYE_B].mean(0)
        if eye_a[0] > eye_b[0]:                      # the reference's first eye is on the image left
            eye_a, eye_b = eye_b, eye_a
        return np.vstack([eye_a, eye_b, pts[NOSE_BASE].mean(0), pts[MOUTH].mean(0)])

    def close(self):
        self.landmarker.close()


def fill_gaps(anchors):
    """Interpolate frames with no face; None if no frame had one."""
    seen = [i for i, a in enumerate(anchors) if a is not None]
    if not seen:
        return None
    out = list(anchors)
    for a, b in zip(seen, seen[1:]):
        for i in range(a + 1, b):
            out[i] = out[a] + (out[b] - out[a]) * (i - a) / (b - a)
    out[:seen[0]] = [out[seen[0]]] * seen[0]
    out[seen[-1] + 1:] = [out[seen[-1]]] * (len(out) - seen[-1] - 1)
    return np.stack(out)


def mouth_crops(gray_frames, anchors):
    """Grayscale frames + per-frame anchors (None allowed) -> (T, 96, 96) uint8, or None."""
    anchors = fill_gaps(anchors)
    if anchors is None:
        return None
    crops = []
    n = len(anchors)
    for i, frame in enumerate(gray_frames):
        m = min(SMOOTH // 2, i, n - 1 - i)
        smoothed = anchors[i - m:i + m + 1].mean(0)
        smoothed += anchors[i].mean(0) - smoothed.mean(0)
        tform = cv2.estimateAffinePartial2D(smoothed, REFERENCE, method=cv2.LMEDS)[0]
        warped = cv2.warpAffine(frame, tform, (256, 256), flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        mouth = smoothed[3] @ tform[:, :2].T + tform[:, 2]
        crops.append(_cut(warped, mouth))
    return np.stack(crops)


def _cut(img, centre, half=CROP // 2):
    cx, cy = centre
    y0 = int(round(np.clip(cy - half, 0, img.shape[0] - CROP)))
    x0 = int(round(np.clip(cx - half, 0, img.shape[1] - CROP)))
    return img[y0:y0 + CROP, x0:x0 + CROP].copy()


def resample(items, timestamps, fps=25.0):
    """Pick the item nearest each 1/fps tick, so any camera rate becomes the model's 25 fps."""
    if not items:
        return []
    ts = np.asarray(timestamps, dtype=np.float64)
    ticks = np.arange(ts[0], ts[-1] + 1e-9, 1.0 / fps)
    idx = np.clip(np.searchsorted(ts, ticks), 0, len(ts) - 1)
    prev = np.clip(idx - 1, 0, len(ts) - 1)
    idx = np.where(np.abs(ts[prev] - ticks) < np.abs(ts[idx] - ticks), prev, idx)
    return [items[i] for i in idx]
