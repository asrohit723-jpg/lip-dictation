import os
from pathlib import Path

import numpy as np
import pytest

from lipdictation import cleanup, face

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = ROOT / "samples" / "2016-03-12.mov"
MODELS = ROOT / "models"


def test_basic_cleanup():
    assert cleanup.basic("HELLO I'M ON MY WAY") == "Hello I'm on my way."
    assert cleanup.basic("WHAT TIME IS IT") == "What time is it?"
    assert cleanup.basic("  ") == ""


def test_resample_to_25_fps():
    stamps = [i / 30 for i in range(31)]            # one second of 30 fps
    out = face.resample(list(range(31)), stamps)
    assert len(out) == 26 and out[0] == 0 and out[-1] == 30


def test_fill_gaps_interpolates_and_extends():
    a, b = np.zeros((4, 2)), np.full((4, 2), 10.0)
    filled = face.fill_gaps([None, a, None, b, None])
    assert np.allclose(filled[0], a) and np.allclose(filled[2], 5.0) and np.allclose(filled[4], b)
    assert face.fill_gaps([None, None]) is None


@pytest.mark.skipif(not (SAMPLE.exists() and (MODELS / "vsr" / "model.pth").exists()),
                    reason="needs models/ and samples/ (scripts/download-models.sh --samples)")
def test_reads_a_real_clip():
    os.environ.setdefault("GLOG_minloglevel", "2")
    from lipdictation import clip
    from lipdictation.vsr import LipReader
    frames, stamps = clip.frames_from_file(SAMPLE, 20, 28)
    anchors = clip.track(face.FaceTracker(MODELS / "face_landmarker.task"), frames, stamps)
    guesses, _ = clip.read(LipReader(MODELS), frames, anchors, stamps)
    assert "NEW YORK CITY" in guesses[0] and "SMITH COLLEGE" in guesses[0]
