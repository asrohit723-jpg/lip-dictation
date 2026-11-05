"""Lip shapes (visemes): the sounds that look the same from the outside.

p, b and m all close the lips; f and v put the lip on the teeth; t, d, n, s, z and l happen
behind the teeth and look alike. Words with the same sequence of lip shapes ("homophenes",
like pat / bat / mat) can't be told apart by sight alone, which is where context comes in.
"""
GROUPS = {
    "P": "P B M",                 # lips closed
    "F": "F V",                   # lip on teeth
    "T": "TH DH",                 # tongue between teeth
    "D": "T D N S Z L",           # behind the teeth
    "S": "SH ZH CH JH",           # lips pushed forward
    "K": "K G NG HH Y",           # back of the mouth, barely visible
    "R": "R ER",
    "W": "W",
    "A": "AA AE AH AY AW",        # open vowels
    "E": "EH EY IH IY",           # spread vowels
    "O": "AO OW OY UH UW",        # rounded vowels
}
PHONE_TO_VISEME = {p: v for v, ps in GROUPS.items() for p in ps.split()}


def to_visemes(phones):
    """CMUdict phones (with stress digits) -> a string with one letter per lip shape."""
    out = []
    for p in phones:
        v = PHONE_TO_VISEME.get(p.rstrip("012"))
        if v and (not out or out[-1] != v or v in "AEO"):   # a held consonant looks like one
            out.append(v)
    return "".join(out)
