"""Camera capture with live face tracking.

The camera opens on the first dictation and stays open for `idle_close` seconds
after the last one, so back-to-back dictations start instantly while the camera
light is off the rest of the time. While recording, every frame goes through
the face tracker straight away, so nothing is left to detect after release.
"""
import threading
import time

import cv2

from .face import FaceTracker


class Camera:
    def __init__(self, index, landmarker_path, idle_close=60.0):
        self.index = index
        self.idle_close = idle_close
        self.tracker = FaceTracker(landmarker_path)
        self.lock = threading.Lock()
        self.cap = None
        self.thread = None
        self.running = False
        self.recording = False
        self.last_used = 0.0
        self.frames, self.anchors, self.stamps = [], [], []
        self.first_frame = threading.Event()

    # -- lifecycle -------------------------------------------------------------
    def _open(self):
        if self.thread:
            self.thread.join()          # the previous capture thread is releasing the camera
        if isinstance(self.index, str):          # a video file standing in for the camera, for tests
            cap = cv2.VideoCapture(self.index)
            self.pace = 1.0 / (cap.get(cv2.CAP_PROP_FPS) or 30.0)
        else:
            cap = cv2.VideoCapture(self.index, cv2.CAP_AVFOUNDATION)
            self.pace = 0.0
        if not cap.isOpened():
            self.running = False
            raise RuntimeError(f"Camera {self.index} did not open. Allow Camera access for this app "
                               "in System Settings > Privacy & Security > Camera.")
        if not self.pace:
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            cap.set(cv2.CAP_PROP_FPS, 30)
        self.cap = cap
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        next_at = time.monotonic()
        while self.running:
            if self.pace:                         # play a file in real time
                next_at += self.pace
                time.sleep(max(0.0, next_at - time.monotonic()))
            ok, bgr = self.cap.read()
            if not ok:
                time.sleep(0.01)
                continue
            now = time.monotonic()
            with self.lock:
                recording = self.recording
                if not recording and now - self.last_used > self.idle_close:
                    self.running = False
                    break
            if recording:
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                anchors = self.tracker.anchors(rgb, now * 1000)
                with self.lock:
                    if self.recording:
                        self.frames.append(rgb)
                        self.anchors.append(anchors)
                        self.stamps.append(now)
                        self.first_frame.set()
        self.cap.release()
        self.cap = None

    def close(self):
        self.running = False
        if self.thread:
            self.thread.join(timeout=2)

    # -- recording -------------------------------------------------------------
    def start(self):
        """Begin recording; opens the camera if it is closed."""
        with self.lock:
            self.frames, self.anchors, self.stamps = [], [], []
            self.first_frame.clear()
            self.recording = True
            self.last_used = time.monotonic()
            closed = not self.running
            if closed:
                self.running = True     # claim it, so the idle check cannot close it under us
        if closed:
            self._open()

    def stop(self):
        """Stop recording and return (frames, anchors, stamps)."""
        with self.lock:
            self.recording = False
            self.last_used = time.monotonic()
            out = self.frames, self.anchors, self.stamps
            self.frames, self.anchors, self.stamps = [], [], []
        return out

    def cancel(self):
        self.stop()
