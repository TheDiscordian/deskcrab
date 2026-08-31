"""Mouth cue tracks derived from the synthesiser's own phoneme record.

piper logs, per synthesised sentence, the exact eSpeak IPA phoneme string it
spoke and the seconds of audio it produced. This module turns that pair into
a timed viseme track: which mouth shape stands at which offset from the
clip's playback start. It is deliberately a pure function of (phonemes,
duration) — no audio analysis at runtime, no model, no guessing from the
delivered words — so the same inputs always give the same track and a test
can hold the whole thing still.

The shapes speak the compact family of specs/face.md rule 20:

  rest    — the expression's own mouth (lip closures land here too: p b m)
  slight  — barely parted, neutral consonants and reduced vowels
  open    — open vowels (father, cup, cat)
  wide    — spread lips (ee, ay, s, sh)
  round   — rounded lips (oh, oo, w)
  teeth   — upper teeth on lower lip (f, v)

Timing is proportional: each phoneme carries a relative weight, punctuation
carries a fixed pause, and the weights are scaled so the track fills the
clip's measured duration. That is an approximation of piper's internal
alignment, not a readout of it; the measured error of the whole path is
recorded in the portrait drawer's review sheets, and the honest bound is
"phoneme-proportional, anchored to real clip starts", not "frame-exact".
"""

# Multi-character IPA sequences first, longest match wins.
_MULTI = (
    "aɪə", "aʊə",
    "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ", "əʊ", "ɪə", "eə", "ʊə",
    "iː", "uː", "ɜː", "ɑː", "ɔː", "ɒː", "æː", "ʌː",
    "tʃ", "dʒ",
)

_VOWEL_VISEME = {
    "i": "wide", "iː": "wide", "ɪ": "wide", "eɪ": "wide", "ɪə": "wide",
    "e": "slight", "ɛ": "slight", "ə": "slight", "ɐ": "slight",
    "ɜ": "slight", "ɜː": "slight", "eə": "slight",
    "a": "open", "æ": "open", "æː": "open", "ʌ": "open", "ʌː": "open",
    "ɑ": "open", "ɑː": "open", "aɪ": "open", "aɪə": "open",
    "ɒ": "round", "ɒː": "round", "ɔ": "round", "ɔː": "round",
    "ɔɪ": "round", "o": "round", "oʊ": "round", "əʊ": "round",
    "u": "round", "uː": "round", "ʊ": "round", "ʊə": "round",
    "aʊ": "round", "aʊə": "round",
}

_CONS_VISEME = {
    "p": "rest", "b": "rest", "m": "rest",
    "f": "teeth", "v": "teeth",
    "s": "wide", "z": "wide", "ʃ": "wide", "ʒ": "wide",
    "tʃ": "wide", "dʒ": "wide", "j": "wide",
    "w": "round",
    "t": "slight", "d": "slight", "n": "slight", "l": "slight",
    "k": "slight", "ɡ": "slight", "g": "slight", "ŋ": "slight",
    "h": "slight", "ɹ": "slight", "r": "slight", "ɾ": "slight",
    "θ": "slight", "ð": "slight", "x": "slight", "ʔ": "slight",
}

# Relative time weights. Long vowels and diphthongs hold the mouth longest;
# stops barely register.
_WEIGHT = {"vowel": 1.6, "long_vowel": 2.3, "consonant": 0.7, "h": 0.45}
_PAUSE = {",": 0.22, ";": 0.28, ":": 0.28,
          ".": 0.34, "!": 0.34, "?": 0.34, "…": 0.4}

_IGNORE = set("ˈˌː ‍͡()")   # stress, length alone, ties

MIN_CUE = 0.045   # cues shorter than this merge into their neighbour


def _tokens(ipa):
    """Greedy longest-match tokenisation of an eSpeak IPA string."""
    out, i = [], 0
    while i < len(ipa):
        ch = ipa[i]
        matched = None
        for m in _MULTI:
            if ipa.startswith(m, i):
                matched = m
                break
        if matched:
            out.append(matched)
            i += len(matched)
            continue
        if ch in _PAUSE:
            out.append(ch)
        elif ch in _IGNORE:
            pass
        elif ch.strip():
            out.append(ch)
        else:
            out.append(" ")
        i += 1
    return out


def _classify(tok):
    """(viseme, weight) for one token; None for word gaps."""
    if tok in _VOWEL_VISEME:
        weight = (_WEIGHT["long_vowel"]
                  if len(tok) > 1 or tok.endswith("ː")
                  else _WEIGHT["vowel"])
        return _VOWEL_VISEME[tok], weight
    if tok in _CONS_VISEME:
        weight = _WEIGHT["h"] if tok == "h" else _WEIGHT["consonant"]
        return _CONS_VISEME[tok], weight
    # An IPA character this table does not know: treat as a neutral
    # consonant rather than dropping time on the floor.
    return "slight", _WEIGHT["consonant"]


def cue_track(ipa, duration):
    """[[offset_seconds, viseme], ...] for one clip of `duration` seconds.

    The track always begins at 0 and always ends with a `rest` cue, so a
    viewer that plays it to the end has closed the mouth without needing
    any further message.
    """
    duration = max(float(duration), 0.0)
    if duration <= 0 or not (ipa or "").strip():
        return [[0.0, "rest"]]

    toks = _tokens(ipa)
    segs = []          # (viseme, weight) speech segments
    pause_total = 0.0
    for tok in toks:
        if tok == " ":
            continue
        if tok in _PAUSE:
            segs.append(("rest", ("pause", _PAUSE[tok])))
            pause_total += _PAUSE[tok]
            continue
        segs.append(_classify(tok))

    weight_total = sum(w for _v, w in segs if not isinstance(w, tuple))
    speech_time = max(duration - pause_total, duration * 0.5)
    scale = (speech_time / weight_total) if weight_total else 0.0
    # If punctuation pauses alone would overflow the clip, shrink them too.
    pause_scale = 1.0
    if pause_total and speech_time + pause_total > duration:
        pause_scale = max(duration - speech_time, 0.0) / pause_total

    cues, t = [], 0.0
    for viseme, w in segs:
        dt = w[1] * pause_scale if isinstance(w, tuple) else w * scale
        if dt <= 0:
            continue
        if cues and (cues[-1][1] == viseme or dt < MIN_CUE):
            # Merge into the standing cue rather than flickering.
            t += dt
            continue
        cues.append([round(t, 3), viseme])
        t += dt
    if not cues or cues[0][0] > 0:
        cues.insert(0, [0.0, cues[0][1] if cues else "rest"])
    if cues[-1][1] != "rest":
        cues.append([round(min(t, duration), 3), "rest"])
    return cues


if __name__ == "__main__":
    import json
    import sys
    ipa = sys.argv[1] if len(sys.argv) > 1 else "həlˈoʊ wˈɜːld"
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 1.4
    print(json.dumps(cue_track(ipa, dur)))
