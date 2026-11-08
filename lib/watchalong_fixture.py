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
player    a headless MPRIS player on the session bus (specs/watchalong.md rules
          8a-8h): it owns org.mpris.MediaPlayer2.<name>, reports a position
          that advances on its own clock while "Playing", names the source in
          its metadata, and is driven by lines appended to a control file —
          pause, resume, seek S, rate R, status S, url U, quit. It opens no
          window and decodes nothing; it is the shape of a real player's
          telemetry so the observer can be proven against scripted pauses,
          seeks, a wrong file, and a player that goes away and comes back.

    lib/watchalong_fixture.py generate --out DIR [--seconds 240] [--scene-seconds 10]
                                       [--voice PATH] [--piper PATH] [--no-speech]
    lib/watchalong_fixture.py decode-frame PNG
    lib/watchalong_fixture.py decode-packet PACKET_DIR PACKET_JSON
    lib/watchalong_fixture.py player --source PATH --control FILE [--name watchalong_fixture]
                                     [--position S] [--paused] [--rate R] [--url URL] [--log FILE]
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


# ---------------------------------------------------------------- the headless player

MPRIS_XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <property name="Identity" type="s" access="read"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Position" type="x" access="read"/>
    <property name="Rate" type="d" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <signal name="Seeked"><arg name="Position" type="x"/></signal>
  </interface>
</node>"""


class FixturePlayer:
    """A player that plays nothing: a position on a clock, a status, a source
    URL, and a control file. CanControl is false — nothing on the bus may drive
    it; only the control file does, which is the test's hand."""

    def __init__(self, source, name, position, paused, rate, url, control, log, length):
        import time
        self.time = time
        self.source = os.path.abspath(source)
        self.name = name
        self.status = "Paused" if paused else "Playing"
        self.rate = float(rate)
        self.url = url or ("file://" + self.source)
        self.control = control
        self.applied = 0
        self.logf = open(log, "a", encoding="utf-8", buffering=1) if log else None
        self.length = float(length) if length else None
        self.base = float(position)
        self.base_t = time.monotonic()
        self.conn = None
        self.loop = None

    def log(self, msg):
        import datetime
        line = "%s mono=%.3f %s" % (datetime.datetime.now().astimezone().isoformat(timespec="milliseconds"),
                                     self.time.monotonic(), msg)
        print(line, flush=True)
        if self.logf:
            self.logf.write(line + "\n")

    def position(self):
        if self.status == "Playing":
            p = self.base + self.rate * (self.time.monotonic() - self.base_t)
        else:
            p = self.base
        if self.length is not None and p >= self.length:
            # the end of the media: a real player stops there
            p = self.length
            if self.status == "Playing":
                self.base = p
                self.base_t = self.time.monotonic()
                self.status = "Stopped"
                self.log("reached the end at %.3f: Stopped" % p)
        return max(0.0, p)

    def set_position(self, p):
        self.base = max(0.0, float(p))
        self.base_t = self.time.monotonic()

    def get_prop(self, conn, sender, path, iface, name):
        from gi.repository import GLib
        v = None
        if iface == "org.mpris.MediaPlayer2":
            v = {"Identity": ("s", "watchalong fixture (plays nothing)"), "CanQuit": ("b", False),
                 "CanRaise": ("b", False), "HasTrackList": ("b", False),
                 "SupportedUriSchemes": ("as", ["file"]), "SupportedMimeTypes": ("as", ["video/mp4"])}.get(name)
        else:
            if name == "PlaybackStatus":
                v = ("s", self.status)
            elif name == "Position":
                v = ("x", int(round(self.position() * 1e6)))
            elif name == "Rate":
                v = ("d", self.rate)
            elif name in ("MinimumRate", "MaximumRate"):
                v = ("d", self.rate)
            elif name == "Metadata":
                md = {"xesam:url": GLib.Variant("s", self.url),
                      "xesam:title": GLib.Variant("s", os.path.basename(self.source)),
                      "mpris:trackid": GLib.Variant("o", "/org/mpris/MediaPlayer2/Track/1")}
                if self.length is not None:
                    md["mpris:length"] = GLib.Variant("x", int(round(self.length * 1e6)))
                return GLib.Variant("a{sv}", md)
            elif name in ("CanSeek", "CanPlay", "CanPause"):
                v = ("b", True)
            elif name in ("CanControl", "CanGoNext", "CanGoPrevious"):
                v = ("b", False)
        if v is None:
            return None
        return GLib.Variant(v[0], v[1])

    def emit_changed(self, props):
        from gi.repository import GLib
        body = GLib.Variant("(sa{sv}as)", ("org.mpris.MediaPlayer2.Player",
                                           {k: self.get_prop(None, None, None, "org.mpris.MediaPlayer2.Player", k)
                                            for k in props}, []))
        try:
            self.conn.emit_signal(None, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties",
                                  "PropertiesChanged", body)
        except Exception as e:  # a signal nobody hears is not the fixture's concern
            self.log("signal failed: %s" % e)

    def apply(self, line):
        from gi.repository import GLib
        words = line.split()
        if not words:
            return
        cmd, arg = words[0].lower(), (words[1] if len(words) > 1 else "")
        before = self.position()
        if cmd == "pause":
            self.set_position(before)
            self.status = "Paused"
            self.emit_changed(["PlaybackStatus"])
        elif cmd in ("resume", "play"):
            self.set_position(before)
            self.status = "Playing"
            self.emit_changed(["PlaybackStatus"])
        elif cmd == "seek":
            self.set_position(float(arg))
            try:
                self.conn.emit_signal(None, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
                                      "Seeked", GLib.Variant("(x)", (int(round(self.position() * 1e6)),)))
            except Exception as e:
                self.log("signal failed: %s" % e)
        elif cmd == "rate":
            self.set_position(before)
            self.rate = float(arg)
            self.emit_changed(["Rate"])
        elif cmd == "status":
            self.set_position(before)
            self.status = arg
            self.emit_changed(["PlaybackStatus"])
        elif cmd == "url":
            self.url = arg
            self.emit_changed(["Metadata"])
        elif cmd == "quit":
            self.log("applied: quit at %.3f" % before)
            self.loop.quit()
            return
        else:
            self.log("ignored: %r" % line)
            return
        self.log("applied: %s at %.3f -> %s %.3f rate %.2f url %s" % (
            line.strip(), before, self.status, self.position(), self.rate, self.url))

    def poll_control(self):
        try:
            with open(self.control, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError:
            return True
        if len(lines) < self.applied:  # truncated: the test started a new script
            self.applied = 0
        while self.applied < len(lines):
            line = lines[self.applied]
            self.applied += 1
            if line.strip() and not line.startswith("#"):
                self.apply(line)
        return True

    def serve(self):
        import warnings
        warnings.filterwarnings("ignore", category=DeprecationWarning)
        import gi
        gi.require_version("Gio", "2.0")
        gi.require_version("GLib", "2.0")
        from gi.repository import Gio, GLib
        info = Gio.DBusNodeInfo.new_for_xml(MPRIS_XML)
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        for iface in info.interfaces:
            self.conn.register_object("/org/mpris/MediaPlayer2", iface, None, self.get_prop, None)
        bus_name = "org.mpris.MediaPlayer2." + self.name
        self.loop = GLib.MainLoop()
        lost = {"n": 0}

        def on_lost(conn, name):
            lost["n"] += 1
            self.log("bus name %s lost" % name)
            self.loop.quit()

        Gio.bus_own_name_on_connection(self.conn, bus_name, Gio.BusNameOwnerFlags.NONE, None, on_lost)
        self.base_t = self.time.monotonic()  # the clock starts when the player is on the bus
        self.log("player up as %s: %s at %.3f, url %s%s" % (
            bus_name, self.status, self.position(), self.url,
            (", length %.1f" % self.length) if self.length is not None else ""))
        GLib.timeout_add(100, self.poll_control)
        self.loop.run()
        self.log("player down")


def run_player(a):
    length = None
    try:
        out = subprocess.run([os.environ.get("DESKCRAB_FFPROBE") or "ffprobe", "-v", "error", "-show_entries",
                              "format=duration", "-of", "csv=p=0", a.source],
                             capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        if out.returncode == 0 and out.stdout.strip():
            length = float(out.stdout.strip().splitlines()[0])
    except (OSError, ValueError, subprocess.TimeoutExpired):
        length = None
    if a.length is not None:
        length = a.length
    FixturePlayer(a.source, a.name, a.position, a.paused, a.rate, a.url, a.control, a.log, length).serve()


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
    pl = sub.add_parser("player")
    pl.add_argument("--source", required=True)
    pl.add_argument("--control", required=True)
    pl.add_argument("--name", default="watchalong_fixture")
    pl.add_argument("--position", type=float, default=0.0)
    pl.add_argument("--paused", action="store_true")
    pl.add_argument("--rate", type=float, default=1.0)
    pl.add_argument("--url", default="")
    pl.add_argument("--length", type=float, default=None)
    pl.add_argument("--log", default="")
    a = ap.parse_args(argv)
    if a.cmd == "player":
        run_player(a)
        return
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
