"""Turn recorded frames (from the camera or a video file) into lip-read text."""
import time

import cv2

from . import face


def frames_from_file(path, start=0.0, end=None):
    """RGB frames and timestamps (seconds) from a video file."""
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000)
    frames, stamps = [], []
    while True:
        ok, bgr = cap.read()
        if not ok:
            break
        t = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if end is not None and t > end:
            break
        frames.append(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        stamps.append(t)
    cap.release()
    return frames, stamps


def track(tracker, frames, stamps):
    """Anchors for every frame, None where no face was found."""
    return [tracker.anchors(f, t * 1000) for f, t in zip(frames, stamps)]


def crops_for(frames, anchors, stamps):
    """Resample to 25 fps and cut mouth crops. None if no face was seen."""
    keep = face.resample(list(range(len(frames))), stamps)
    gray = [cv2.cvtColor(frames[i], cv2.COLOR_RGB2GRAY) for i in keep]
    return face.mouth_crops(gray, [anchors[i] for i in keep])


def read(reader, frames, anchors, stamps, nbest=5):
    t0 = time.perf_counter()
    crops = crops_for(frames, anchors, stamps)
    if crops is None:
        return [], {"error": "no face"}
    t1 = time.perf_counter()
    guesses, timing = reader.read(crops, nbest=nbest)
    timing["crop"] = t1 - t0
    return guesses, timing
