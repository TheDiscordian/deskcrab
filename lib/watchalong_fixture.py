#!/usr/bin/env python3
"""The private synthetic viewing fixture and its deterministic decoder.
specs/watchalong.md rules 24 and 28.

generate  paints a multi-minute video whose every frame carries the scene
          number and the source second — as text, and as a block code the
          decoder reads from the pixels — over a per-scene colour and shape,
          with a known sentence spoken at each scene's start (synthesised to a
          FILE by piper, never played) and a per-scene tone underneath.
decode    reads those pixels and that audio back. It is a decoder: it proves
          that the actual frame files and audio of a packet reached a reviewer
          and were read, and that what it read then reached the prompt. It
          proves nothing about perception, and its observation says so.

    lib/watchalong_fixture.py generate --out DIR [--seconds 240] [--scene-seconds 10]
                                       [--voice PATH] [--piper PATH] [--no-speech]
    lib/watchalong_fixture.py decode-frame PNG
    lib/watchalong_fixture.py decode-packet PACKET_DIR PACKET_JSON
"""
import argparse
import io
import json
import math
import os
import struct
import subprocess
import sys
import wave

W, H = 320, 240
FPS = 5
CELLS = 24          # 8 bits scene, 12 bits second, 4 bits checksum
CELL_W = 13
STRIP_Y = 222
STRIP_H = 16
PALETTE = [  # (name, rgb) — distinct, nameable, cycled by scene
    ("blue", (30, 60, 200)), ("green", (20, 140, 60)), ("red", (190, 30, 40)),
    ("orange", (230, 130, 20)), ("purple", (120, 40, 160)), ("teal", (20, 150, 150)),
    ("brown", (120, 80, 40)), ("grey", (110, 110, 110)),
]
SHAPES = ["circle", "square", "triangle"]
PHRASES = [
    "The red door opens.", "A dog barks at the gate.", "The kettle starts to whistle.",
    "Rain hits the window.", "Someone drops a plate.", "The lights go out.",
    "A horse walks past the barn.", "The clock strikes nine.", "She reads the letter twice.",
    "The train leaves early.", "A cat sleeps on the chair.", "The bridge is closed today.",
]
TONE_BASE = 400.0
TONE_STEP = 40.0
TONE_START = 5.0    # seconds into a scene when the tone begins (after the sentence)
SR = 16000

FFMPEG = os.environ.get("DESKCRAB_FFMPEG") or "ffmpeg"


def scene_sentence(i):
    return "Scene %d. %s" % (i, PHRASES[i % len(PHRASES)])


def checksum(bits):
    return sum(bits) % 16


def encode_bits(scene, second):
    bits = [(scene >> (7 - i)) & 1 for i in range(8)] + [(second >> (11 - i)) & 1 for i in range(12)]
    c = checksum(bits)
    return bits + [(c >> (3 - i)) & 1 for i in range(4)]


def load_font(size):
    from PIL import ImageFont
    for cand in ("/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
                 "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
                 "/usr/share/fonts/dejavu/DejaVuSansMono.ttf"):
        if os.path.isfile(cand):
            try:
                return ImageFont.truetype(cand, size)
            except OSError:
                continue
    return ImageFont.load_default()


def paint_frame(t, scene_seconds, fonts):
    from PIL import Image, ImageDraw
    second = int(math.floor(t + 1e-6))
    scene = second // scene_seconds
    name, rgb = PALETTE[scene % len(PALETTE)]
    im = Image.new("RGB", (W, H), rgb)
    d = ImageDraw.Draw(im)
    # the shape, drifting left to right across its scene
    frac = (t - scene * scene_seconds) / float(scene_seconds)
    cx = int(40 + frac * (W - 80))
    cy = 150
    shape = SHAPES[scene % len(SHAPES)]
    fill = (250, 230, 40)
    if shape == "circle":
        d.ellipse([cx - 22, cy - 22, cx + 22, cy + 22], fill=fill)
    elif shape == "square":
        d.rectangle([cx - 22, cy - 22, cx + 22, cy + 22], fill=fill)
    else:
        d.polygon([(cx, cy - 26), (cx - 26, cy + 20), (cx + 26, cy + 20)], fill=fill)
    d.text((10, 8), "SCENE %02d" % scene, fill=(255, 255, 255), font=fonts[0])
    d.text((10, 64), "T %02d:%02d  (%d s)" % (second // 60, second % 60, second), fill=(255, 255, 255), font=fonts[1])
    d.text((10, 100), "%s %s" % (name, shape), fill=(255, 255, 255), font=fonts[1])
    # the block code strip
    d.rectangle([0, STRIP_Y - 2, W, STRIP_Y + STRIP_H + 2], fill=(128, 128, 128))
    for i, b in enumerate(encode_bits(scene, second)):
        x0 = 4 + i * CELL_W
        d.rectangle([x0, STRIP_Y, x0 + CELL_W - 2, STRIP_Y + STRIP_H], fill=(255, 255, 255) if b else (0, 0, 0))
    return im


def synth_sentence(text, voice, piper, workdir, idx):
    """Piper to a FILE at 16 kHz mono; returns float samples or None. Nothing is played."""
    import numpy as np
    raw = os.path.join(workdir, "s%03d.wav" % idx)
    try:
        r = subprocess.run([piper, "--model", voice, "--output_file", raw], input=text,
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0 or not os.path.isfile(raw):
        return None
    pcm = os.path.join(workdir, "s%03d.pcm" % idx)
    c = subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-y", "-i", raw, "-ac", "1", "-ar", str(SR),
                        "-f", "s16le", pcm], capture_output=True, stdin=subprocess.DEVNULL)
    if c.returncode != 0:
        return None
    data = np.frombuffer(open(pcm, "rb").read(), dtype=np.int16).astype(np.float32) / 32768.0
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if peak > 0:
        data = data * (0.8 / peak)
    return data


def build_audio(seconds, scene_seconds, voice, piper, workdir, speech):
    import numpy as np
    n = int(seconds * SR)
    audio = np.zeros(n, dtype=np.float32)
    schedule = []
    scenes = int(math.ceil(seconds / float(scene_seconds)))
    for i in range(scenes):
        s0 = i * scene_seconds
        entry = {"scene": i, "start": s0, "end": min(seconds, s0 + scene_seconds),
                 "sentence": scene_sentence(i), "spoken": False, "speech_end": None,
                 "tone_hz": TONE_BASE + TONE_STEP * i,
                 "tone_start": min(seconds, s0 + TONE_START), "tone_end": min(seconds, s0 + scene_seconds),
                 "colour": PALETTE[i % len(PALETTE)][0], "shape": SHAPES[i % len(SHAPES)]}
        if speech:
            samples = synth_sentence(entry["sentence"], voice, piper, workdir, i)
            if samples is not None and samples.size:
                a = int(s0 * SR)
                b = min(n, a + samples.size, int(entry["tone_start"] * SR))
                audio[a:b] += samples[: b - a]
                entry["spoken"] = True
                entry["speech_end"] = s0 + (b - a) / float(SR)
        a = int(entry["tone_start"] * SR)
        b = int(entry["tone_end"] * SR)
        if b > a:
            tt = np.arange(b - a, dtype=np.float32) / SR
            audio[a:b] += 0.3 * np.sin(2 * math.pi * entry["tone_hz"] * tt)
        schedule.append(entry)
    audio = np.clip(audio, -1.0, 1.0)
    path = os.path.join(workdir, "audio.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((audio * 32767.0).astype(np.int16).tobytes())
    return path, schedule


def generate(out, seconds, scene_seconds, voice, piper, speech):
    os.makedirs(out, exist_ok=True)
    work = os.path.join(out, "work")
    os.makedirs(work, exist_ok=True)
    fonts = (load_font(40), load_font(22))
    audio_path, schedule = build_audio(seconds, scene_seconds, voice, piper, work, speech)
    video = os.path.join(out, "fixture.mp4")
    cmd = [FFMPEG, "-nostdin", "-v", "error", "-y",
           "-f", "image2pipe", "-framerate", str(FPS), "-i", "-",
           "-i", audio_path,
           "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-g", str(FPS * 5),
           "-c:a", "aac", "-b:a", "96k", "-shortest", video]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    frames = int(seconds * FPS)
    for k in range(frames):
        im = paint_frame(k / float(FPS), scene_seconds, fonts)
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        proc.stdin.write(buf.getvalue())
    proc.stdin.close()
    err = proc.stderr.read().decode("utf-8", "replace")
    if proc.wait() != 0:
        raise SystemExit("ffmpeg failed: %s" % err[-500:])
    spoken = sum(1 for e in schedule if e["spoken"])
    meta = {"video": video, "seconds": seconds, "scene_seconds": scene_seconds, "fps": FPS,
            "speech": spoken > 0, "spoken_scenes": spoken, "voice": voice if spoken else None,
            "tone_base": TONE_BASE, "tone_step": TONE_STEP, "scenes": schedule,
            "note": "private synthetic fixture; generated to files, never played"}
    with open(os.path.join(out, "fixture.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1)
    return meta


# ---------------------------------------------------------------- decoding

def decode_frame(path):
    """Read the block code off the pixels. Returns dict(scene, second, ok, colour, error)."""
    from PIL import Image
    im = Image.open(path).convert("RGB")
    if im.size != (W, H):
        im = im.resize((W, H))
    px = im.load()
    bits = []
    y = STRIP_Y + STRIP_H // 2
    for i in range(CELLS):
        x = 4 + i * CELL_W + (CELL_W - 2) // 2
        r, g, b = px[x, y]
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        bits.append(1 if lum > 128 else 0)
    scene = int("".join(str(b) for b in bits[0:8]), 2)
    second = int("".join(str(b) for b in bits[8:20]), 2)
    cs = int("".join(str(b) for b in bits[20:24]), 2)
    ok = cs == checksum(bits[0:20])
    # the dominant background colour, sampled away from text and shape
    r, g, b = px[300, 130]
    colour = min(PALETTE, key=lambda p: (p[1][0] - r) ** 2 + (p[1][1] - g) ** 2 + (p[1][2] - b) ** 2)[0]
    return {"scene": scene, "second": second, "ok": ok, "colour": colour,
            "error": None if ok else "checksum mismatch: bits %s" % "".join(str(x) for x in bits)}


def decode_tones(wav_path, a0, window=2.0):
    """Dominant frequency per window of the decoded audio, mapped back to a scene tone."""
    import numpy as np
    with wave.open(wav_path, "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        data = np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768.0
        if w.getnchannels() > 1:
            data = data.reshape(-1, w.getnchannels()).mean(axis=1)
    out = []
    step = int(window * sr)
    for k in range(0, len(data) - step + 1, step):
        seg = data[k:k + step]
        if float(np.max(np.abs(seg))) < 0.02:
            out.append({"start": a0 + k / sr, "end": a0 + (k + step) / sr, "kind": "silence"})
            continue
        spec = np.abs(np.fft.rfft(seg * np.hanning(step)))
        freqs = np.fft.rfftfreq(step, 1.0 / sr)
        band = (freqs >= TONE_BASE - 20) & (freqs <= TONE_BASE + TONE_STEP * 64)
        peak = int(np.argmax(spec * band))
        f = float(freqs[peak])
        total = float(np.sum(spec[band] ** 2)) or 1.0
        share = float(np.sum(spec[max(0, peak - 2):peak + 3] ** 2)) / total
        if share > 0.6:
            scene = int(round((f - TONE_BASE) / TONE_STEP))
            out.append({"start": a0 + k / sr, "end": a0 + (k + step) / sr, "kind": "tone",
                        "hz": round(f, 1), "scene": scene})
        else:
            out.append({"start": a0 + k / sr, "end": a0 + (k + step) / sr, "kind": "speech-or-noise"})
    return out


def decode_packet(pdir, packet):
    """The fixture reviewer: returns (reviewer, modalities, observation)."""
    parts = []
    mismatches = []
    reads = []
    for f in packet.get("frames", []):
        d = decode_frame(os.path.join(pdir, f["file"]))
        pts = float(f["pts"])
        reads.append((pts, d))
        if not d["ok"]:
            mismatches.append("frame at %.1f s: undecodable (%s)" % (pts, d["error"]))
        elif abs(d["second"] - math.floor(pts + 1e-6)) > 1.0:
            mismatches.append("frame at %.1f s reads counter %d s" % (pts, d["second"]))
    if reads:
        parts.append("%d sampled frames at %s read scene counters %s (scenes %s), backgrounds %s" % (
            len(reads), ", ".join("%.1f s" % p for p, _ in reads),
            ", ".join(str(d["second"]) if d["ok"] else "?" for _, d in reads),
            ", ".join(str(d["scene"]) if d["ok"] else "?" for _, d in reads),
            ", ".join(d["colour"] for _, d in reads)))
        parts.append("every counter matches its decoder timestamp within one second" if not mismatches
                     else "MISMATCH: " + "; ".join(mismatches))
    else:
        parts.append("no frames to decode")
    tr = packet.get("transcript") or {}
    wav = os.path.join(pdir, "audio.wav")
    if os.path.isfile(wav):
        try:
            tones = decode_tones(wav, float(tr.get("audio_interval", {}).get("start", packet["interval"]["start"])))
            found = [t for t in tones if t["kind"] == "tone"]
            if found:
                runs = []
                for t in found:
                    if runs and runs[-1]["scene"] == t["scene"] and abs(runs[-1]["end"] - t["start"]) < 0.01:
                        runs[-1]["end"] = t["end"]
                    else:
                        runs.append(dict(t))
                parts.append("audio tones decoded: " + "; ".join(
                    "%.0f Hz = scene %d over %.1f-%.1f s" % (r["hz"], r["scene"], r["start"], r["end"]) for r in runs))
            else:
                parts.append("no scene tone found in the decoded audio")
        except (OSError, ValueError) as e:
            parts.append("audio decode failed: %s" % e)
    segs = tr.get("segments") or []
    if tr.get("status") == "ok":
        parts.append("machine transcript (read, not heard): " + " / ".join(
            "%.1f-%.1f %s" % (x["start"], x["end"], x["text"]) for x in segs))
    else:
        parts.append("machine transcript %s%s" % (tr.get("status"), (": " + tr["error"]) if tr.get("error") else ""))
    parts = [x[0].upper() + x[1:] for x in parts if x]
    obs = ("Deterministic decode by the fixture reader, a decoder and not a viewer. " + ". ".join(parts) +
           ". This is a decoder's report of the files it was handed; it proves carriage, not perception.")
    return "fixture-decoder", ["sampled frames decoded from pixels (block code and colour)",
                               "audio tone decoded by FFT; speech not heard",
                               "machine transcript of decoded audio; not heard"], obs


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--out", required=True)
    g.add_argument("--seconds", type=int, default=240)
    g.add_argument("--scene-seconds", type=int, default=10)
    g.add_argument("--voice", default=os.environ.get("WATCHALONG_FIXTURE_VOICE", ""))
    g.add_argument("--piper", default=os.environ.get("WATCHALONG_PIPER", "/usr/bin/piper-tts"))
    g.add_argument("--no-speech", action="store_true")
    d = sub.add_parser("decode-frame")
    d.add_argument("png")
    p = sub.add_parser("decode-packet")
    p.add_argument("pdir")
    p.add_argument("packet_json")
    a = ap.parse_args(argv)
    if a.cmd == "generate":
        speech = (not a.no_speech) and bool(a.voice) and os.path.isfile(a.voice) and os.path.isfile(a.piper)
        meta = generate(a.out, a.seconds, a.scene_seconds, a.voice, a.piper, speech)
        print(json.dumps({k: meta[k] for k in ("video", "seconds", "scene_seconds", "speech", "spoken_scenes")}))
    elif a.cmd == "decode-frame":
        print(json.dumps(decode_frame(a.png)))
    else:
        with open(a.packet_json, encoding="utf-8") as fh:
            packet = json.load(fh)
        r, m, o = decode_packet(a.pdir, packet)
        print(json.dumps({"reviewer": r, "modalities": m, "observation": o}, indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
