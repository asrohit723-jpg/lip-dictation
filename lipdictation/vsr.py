"""Visual speech recognition: 88x88 mouth crops -> ranked English guesses.

Wraps the Auto-AVSR LRS3 visual-only model (19.1% WER on LRS3) and its subword
Transformer language model, using the ESPnet code vendored in ../espnet.
The encoder runs on the Apple GPU when available; the beam search stays on the
CPU, which is faster for its thousands of tiny steps.
"""
import argparse
import copy
import json
import time
from pathlib import Path

import numpy as np
import torch

from espnet.asr.asr_utils import get_model_conf, torch_load
from espnet.nets.batch_beam_search import BatchBeamSearch
from espnet.nets.lm_interface import dynamic_import_lm
from espnet.nets.pytorch_backend.e2e_asr_transformer import E2E
from espnet.nets.scorers.length_bonus import LengthBonus

DATA = Path(__file__).parent / "data"
MEAN, STD = 0.421, 0.165    # pixel statistics the model was trained with
CROP = 88                   # model input; mouth crops arrive as 96x96


def load_tokens():
    units = (DATA / "unigram5000_units.txt").read_text().splitlines()
    return ["<blank>"] + [u.split()[0] for u in units] + ["<eos>"]


class LipReader:
    def __init__(self, models_dir, beam_size=10, ctc_weight=0.1, lm_weight=0.3, use_lm=True):
        models_dir = Path(models_dir)
        self.tokens = load_tokens()
        confs = json.loads((models_dir / "vsr" / "model.json").read_text())
        args = argparse.Namespace(**(confs if isinstance(confs, dict) else confs[2]))

        self.model = E2E(len(self.tokens), args)
        self.model.load_state_dict(torch.load(models_dir / "vsr" / "model.pth",
                                              map_location="cpu", weights_only=True))
        self.model.eval()

        self.gpu = torch.device("mps") if torch.backends.mps.is_available() else None
        self.encoder = copy.deepcopy(self.model.encoder).to(self.gpu).eval() if self.gpu else None

        lm = None
        if use_lm:
            lm_path = str(models_dir / "lm" / "model.pth")
            lm_args = get_model_conf(lm_path, str(models_dir / "lm" / "model.json"))
            lm_class = dynamic_import_lm(getattr(lm_args, "model_module", "default"), lm_args.backend)
            lm = lm_class(len(self.tokens), lm_args)
            torch_load(lm_path, lm)
            lm.eval()

        scorers = self.model.scorers()
        scorers["lm"] = lm
        scorers["length_bonus"] = LengthBonus(len(self.tokens))
        eos = len(self.tokens) - 1
        self.beam = BatchBeamSearch(
            beam_size=beam_size, vocab_size=len(self.tokens), scorers=scorers,
            weights=dict(decoder=1.0 - ctc_weight, ctc=ctc_weight, lm=lm_weight if lm else 0.0,
                         length_bonus=0.0),
            sos=eos, eos=eos, token_list=self.tokens, pre_beam_score_key="decoder",
        ).eval()
        self.encode(np.zeros((25, 96, 96), np.uint8))   # warm up, so the first dictation isn't slow

    @staticmethod
    def prepare(crops):
        """(T, 96, 96) uint8 grayscale mouth crops -> (1, T, 88, 88) normalised tensor."""
        x = torch.from_numpy(np.asarray(crops, dtype=np.float32) / 255.0)
        top = (x.shape[1] - CROP) // 2
        left = (x.shape[2] - CROP) // 2
        x = x[:, top:top + CROP, left:left + CROP]
        return ((x - MEAN) / STD).unsqueeze(0)

    @torch.no_grad()
    def encode(self, crops):
        x = self.prepare(crops).unsqueeze(0)     # (B=1, C=1, T, H, W)
        if self.encoder is not None:
            feats, _ = self.encoder(x.to(self.gpu), None)
            return feats.squeeze(0).float().cpu()
        feats, _ = self.model.encoder(x, None)
        return feats.squeeze(0)

    def _text(self, hyp):
        ids = [int(t) for t in hyp.yseq[1:]]
        pieces = [self.tokens[i] for i in ids if self.tokens[i] not in ("<eos>", "<blank>")]
        return "".join(pieces).replace("▁", " ").strip()

    @torch.no_grad()
    def read(self, crops, nbest=5):
        """Returns (guesses, timings). Guesses are distinct texts, best first."""
        t0 = time.perf_counter()
        feats = self.encode(crops)
        t1 = time.perf_counter()
        hyps = self.beam(feats)
        t2 = time.perf_counter()
        guesses = []
        for h in hyps:
            text = self._text(h)
            if text and text not in guesses:
                guesses.append(text)
            if len(guesses) == nbest:
                break
        return guesses, {"encode": t1 - t0, "search": t2 - t1, "frames": len(crops)}
