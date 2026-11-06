"""Face landmarks -> 96x96 grayscale mouth crops, aligned the way the model was trained.

MediaPipe FaceLandmarker gives 478 points per frame. We map them to the 68 dlib points
the model's training crops were made from, smooth them over a short window, warp each
frame onto the training mean face and cut a 96x96 patch around the mouth.

Two alignments are available. "anchors4" (the default) is Auto-AVSR's MediaPipe variant: eye,
nose and mouth centres. "points8" copies the RetinaFace + FAN preprocessing the model was trained
with: eight stable points matched to the mean face. On the subtitled news clips they are within
noise of each other (lips alone 20.6% vs 19.7% WER, with context 18.5% vs 19.3%), so the default
stays; scripts/eval_vsr.py --align compares them on any test set.
"""
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import BaseOptions, vision

DATA = Path(__file__).parent / "data"
CROP = 96
SMOOTH = 12          # frames in the landmark smoothing window

# MediaPipe face-mesh index for each dlib-68 point, in dlib order (jaw, brows, nose, eyes, lips).
DLIB68 = [127, 234, 132, 58, 172, 150, 176, 148, 152, 377, 400, 379, 397, 288, 361, 454, 356,
          70, 63, 105, 66, 107, 336, 296, 334, 293, 300,
          168, 197, 5, 4, 98, 97, 2, 326, 327,
          33, 160, 158, 133, 153, 144, 362, 385, 387, 263, 373, 380,
          61, 39, 37, 0, 267, 269, 291, 405, 314, 17, 84, 181, 78, 82, 13, 312, 308, 317, 14, 87]
STABLE8 = [28, 33, 36, 39, 42, 45, 48, 54]      # nose bridge and tip, eye corners, mouth corners
MOUTH = slice(48, 68)
ALIGN = "anchors4"


def _groups(pts):
    """Eye, eye, nose base and mouth centres: the four anchors of the "anchors4" alignment."""
    return np.vstack([pts[36:42].mean(0), pts[42:48].mean(0), pts[31:36].mean(0), pts[MOUTH].mean(0)])


MEAN_FACE = np.load(DATA / "20words_mean_face.npy")


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
        """(68, 2) dlib-order pixel landmarks for an RGB frame, or None when no face is seen."""
        ts_ms = max(int(ts_ms), self.last_ts + 1)   # MediaPipe needs increasing timestamps
        self.last_ts = ts_ms
        result = self.landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), ts_ms)
        if not result.face_landmarks:
            return None
        h, w = rgb.shape[:2]
        mesh = result.face_landmarks[0]
        return np.array([(mesh[i].x * w, mesh[i].y * h) for i in DLIB68], dtype=np.float32)

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


def mouth_crops(gray_frames, landmarks, align=None):
    """Grayscale frames + per-frame landmarks (None allowed) -> (T, 96, 96) uint8, or None."""
    landmarks = fill_gaps(landmarks)
    if landmarks is None:
        return None
    if (align or ALIGN) == "anchors4":
        landmarks = np.stack([_groups(p) for p in landmarks])
        stable, reference, mouth = slice(None), _groups(MEAN_FACE), [3]
    else:
        stable, reference, mouth = STABLE8, MEAN_FACE[STABLE8], MOUTH
    crops = []
    n = len(landmarks)
    for i, frame in enumerate(gray_frames):
        m = min(SMOOTH // 2, i, n - 1 - i)
        smoothed = landmarks[i - m:i + m + 1].mean(0)
        smoothed += landmarks[i].mean(0) - smoothed.mean(0)
        tform = cv2.estimateAffinePartial2D(smoothed[stable], reference, method=cv2.LMEDS)[0]
        warped = cv2.warpAffine(frame, tform, (256, 256), flags=cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_CONSTANT, borderValue=0)
        centre = (smoothed[mouth] @ tform[:, :2].T + tform[:, 2]).mean(0)
        crops.append(_cut(warped, centre))
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
