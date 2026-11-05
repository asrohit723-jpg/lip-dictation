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


def test_visemes_group_look_alike_sounds():
    from lipdictation.visemes import to_visemes
    assert to_visemes("P AE1 T".split()) == to_visemes("B AE1 T".split()) == to_visemes("M AE1 T".split())
    assert to_visemes("F AE1 N".split()) == to_visemes("V AE1 N".split())


def test_lexicon_finds_homophenes_and_neighbours():
    from lipdictation.context import Lexicon
    lex = Lexicon()
    assert lex.vis["meal"] == lex.vis["mail"]
    assert lex.vis["story"] in lex.neighbours(lex.vis["glory"])


def test_questions_after_greetings():
    from lipdictation.cleanup import basic
    assert basic("HEY BABY HOW ARE YOU") == "Hey baby how are you?"
    assert basic("OH YOU ARE AWESOME") == "Oh you are awesome."


def test_learns_the_words_you_fixed():
    from lipdictation.learning import extract
    assert extract("I have bought a new PS.", "I have bought a new PS5.") == [("ps", "PS5")]
    assert extract("My name is Luke.", "My name is Rohit. And I live in Chennai") == [("luke", "Rohit")]
    assert extract("See you at the park.", "Completely different sentence here now.") == []   # a rewrite
    assert extract("meet me at the bar", "meet me at the bar tonight") == []                  # typing on


def test_fixes_apply_and_grow_with_use():
    from lipdictation.learning import Fixes, apply_simple
    f = Fixes()
    f.set(personal=[("ps", "PS5", 1), ("luke", "Rohit", 3)])
    assert apply_simple("i got a new ps luke", f) == "i got a new PS5 Rohit"
    bonuses = {fixed: bonus for words, bonus in f.apply("hi luke".split()) for fixed in [words[1]]}
    assert bonuses["Rohit"] > 4.0


def test_collector_reads_only_valid_shared_fixes():
    import importlib.util
    spec = importlib.util.spec_from_file_location("collect", ROOT / "scripts" / "collect-shared-fixes.py")
    collect = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collect)
    body = ('<!-- lip-dictation-fixes v1 -->\n```json\n{"fixes": [{"heard": "ps", "fixed": "PS5"}, '
            '{"heard": "x; rm -rf /", "fixed": "bad"}, {"heard": "the", "fixed": "<script>"}]}\n```')
    assert collect.fixes_in({"body": body}) == [("ps", "PS5")]
    assert collect.fixes_in({"body": "no marker"}) == []
