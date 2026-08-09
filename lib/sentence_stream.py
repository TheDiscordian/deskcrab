"""Sentence chunking over a streaming reply — the one implementation.

Factored out of lib/tts-streamer so the phone server can speak sentences the
same way the desk does (specs/phone.md rule 17) instead of growing a second
chunker that drifts. The desk streamer feeds piper; the phone server feeds
`crab synth` clips; both walk text deltas through Block.add and hand the
completed block to Block.close, which voices only what the deltas had not
already said — so a stream WITHOUT partial messages behaves exactly as it
always did, one utterance per block.

Nothing in here speaks or decides whether text is worth voicing
(specs/speech-output.md's standing rule): this file only splits and dedupes,
and the `say` callback it is built with does the speaking.
"""

import os
import re

DELIM = "---DISPLAY---"
# Hold back any trailing text that could still turn out to be the delimiter.
DELIM_PREFIXES = [DELIM[:i] for i in range(len(DELIM), 0, -1)]

# Flush an unpunctuated buffer once it gets this long rather than holding a
# sentence that may never end.
MAX_HOLD = int(os.environ.get("DESKCRAB_TTS_MAX_HOLD", "320"))

# Each chunk becomes one utterance, so a boundary here is a full
# sentence-final fall in the voice. Only real sentence enders qualify — a colon
# or a semicolon mid-thought would land as a full stop and sound wrong. A
# decimal ("3.5") is already safe: the lookahead requires whitespace after the
# dot. Abbreviations are not, hence _ABBREV below.
_SENT = re.compile(r".*?[.!?…](?=[\s\"')\]]|$)|.*?\n", re.S)
_ABBREV = re.compile(r"(?:^|[\s(\"'])(?:[A-Za-z]|e\.g|i\.e|etc|vs|approx"
                     r"|[Mm]r|[Mm]rs|[Mm]s|[Dd]r|[Pp]rof|[Ss]t|[Ff]ig)\.$")


def hold_back(buf):
    """How many trailing characters must not be spoken yet, because they may
    still turn out to be the ---DISPLAY--- delimiter or an unclosed `code`
    span (both of which are stripped, and stripping half of one is wrong)."""
    hold = 0
    for pre in DELIM_PREFIXES:
        if buf.endswith(pre):
            hold = len(pre)
            break
    head = buf[:len(buf) - hold] if hold else buf
    if head.count("\x60") % 2:
        hold = len(buf) - head.rindex("\x60")
    return hold


def sentences(buf):
    """Split off every complete sentence. Returns (chunks, remainder)."""
    hold = hold_back(buf)
    head, rest = (buf[:len(buf) - hold], buf[len(buf) - hold:]) if hold else (buf, "")
    chunks, pos, carry = [], 0, ""
    for m in _SENT.finditer(head):
        cand = carry + m.group(0)
        pos = m.end()
        # "e.g." is not the end of a sentence; hold it and keep going, or the
        # voice comes to a full stop in the middle of a clause.
        if _ABBREV.search(cand.rstrip()):
            carry = cand
            continue
        carry = ""
        chunks.append(cand)
    remainder = carry + head[pos:] + rest
    # Never hold a runaway buffer forever — say it at the last space.
    if not chunks and len(remainder) >= MAX_HOLD:
        cut = remainder.rfind(" ", 0, MAX_HOLD)
        if cut > 0:
            chunks.append(remainder[:cut])
            remainder = remainder[cut:]
    return chunks, remainder


class Block:
    """One streaming text block: what has arrived, and what has been said.

    `say` is handed each complete raw chunk, in order, and owns everything
    downstream of the split — the desk wraps it in its markdown strip and the
    piper queue, the phone in a whitespace collapse and the synth queue. A
    chunk the callback judges empty is the callback's own business; the block
    never speaks and never withholds."""

    def __init__(self, say):
        self.say = say
        self.raw = ""        # everything received for this block
        self.consumed = 0    # how much of self.raw has been handed to the voice
        self.pending = ""    # received, not yet a complete sentence
        self.done = False    # ---DISPLAY--- reached: nothing further is spoken
        self.fed = 0         # replay cursor: how far a re-read has walked back
                             # through bytes this block already processed

    def replay(self):
        """This message is about to stream again — a truncation re-read, or
        the CLI re-emitting the same message — and identical bytes are coming
        back through add(). Point the cursor at the start of what is already
        known so they are recognised instead of spoken a second time; the
        completed-half dedup (closed / spoken_texts) cannot reach this half."""
        self.fed = 0

    def add(self, delta):
        if self.fed < len(self.raw):
            overlap = min(len(delta), len(self.raw) - self.fed)
            if delta[:overlap] == self.raw[self.fed:self.fed + overlap]:
                self.fed += overlap
                delta = delta[overlap:]
                if not delta:
                    return
            else:
                # Different bytes where the replay expected its own: this is
                # a NEW reply in this slot (a real truncation put another
                # run's stream here), not a re-read. Start the block over.
                self.__init__(self.say)
        self.raw += delta
        self.fed = len(self.raw)
        if self.done:
            return
        self.pending += delta
        head, sep, _tail = self.pending.partition(DELIM)
        if sep:
            self.pending = head
            self.done = True
        chunks, self.pending = sentences(self.pending)
        for c in chunks:
            self.consumed += len(c)
            self.say(c)
        if self.done:
            self.consumed = len(self.raw)

    def close(self, full_text):
        """The completed assistant event for this block. Speak whatever the
        streaming half did not already say — which is everything, when the CLI
        was run without --include-partial-messages."""
        rest = full_text[self.consumed:] if len(full_text) >= self.consumed else full_text
        self.consumed = len(full_text)
        if self.done:
            return
        head, sep, _tail = rest.partition(DELIM)
        if sep:
            self.done = True
        self.say(head)


class BlockRegistry:
    """Every block of every message in one tail, and the replay protection
    over them. `blocks` is the message in flight; `messages` keeps every
    message's blocks for the whole tail, because a truncation re-read or a
    re-emitted message_start walks the same bytes back through add() and the
    replay cursor (Block.fed) is what keeps them off the speakers.

    The current message's map is only ever REBOUND, by message_start, to the
    next message's own dict — never reset and never cleared. Rebinding it
    anywhere else orphans the map (blocks opened afterwards are unreachable
    from `messages`) and clearing destroys the replay cursors; the completed
    branch used to do exactly that, and a message reaches that branch more
    than once — the CLI emits a completed assistant event per content block —
    so the whole finished reply was spoken a second time on the next re-read."""

    def __init__(self, say):
        self.say = say
        self.blocks = {}         # stream index -> Block, for the message in flight
        self.messages = {}       # message id -> that message's blocks
        self.anon = 0            # message_start events with no id still get
                                 # distinct slots
        self.closed = set()      # (message id, block idx) already spoken to
                                 # completion — the stream can hand us the same
                                 # finished message twice, and the second copy
                                 # must not be spoken again
        self.spoken_texts = set()  # whitespace-normalized text of every block
                                   # spoken this turn — catches the re-emit that
                                   # arrives under a NEW message id, which the
                                   # id-keyed set cannot

    def replay_all(self):
        """A truncation sent the tail back down the file: identical bytes are
        about to walk back through stream_event, and every known block must
        recognise them instead of speaking them again."""
        for mb in self.messages.values():
            for b in mb.values():
                b.replay()

    def stream_event(self, ev):
        """One `stream_event` payload (the CLI event object) from the tail."""
        et = ev.get("type")
        if et == "message_start":
            mid = (ev.get("message") or {}).get("id")
            if not mid:
                self.anon += 1
                mid = "anon-%d" % self.anon
            self.blocks = self.messages.setdefault(mid, {})
            # A message id seen before means these bytes have been here
            # before — the CLI re-emitted the message, or a truncation sent
            # the tail back down the file. Its blocks replay instead of
            # speaking again.
            for b in self.blocks.values():
                b.replay()
        elif et == "content_block_start":
            if (ev.get("content_block") or {}).get("type") == "text":
                idx = ev.get("index")
                if idx not in self.blocks:
                    self.blocks[idx] = Block(self.say)
        elif et == "content_block_delta":
            delta = ev.get("delta") or {}
            if delta.get("type") == "text_delta":
                b = self.blocks.get(ev.get("index"))
                if b is None:
                    b = self.blocks[ev.get("index")] = Block(self.say)
                b.add(delta.get("text") or "")

    def close_text(self, mid, idx, text):
        """A completed text block: voice only what the deltas did not.

        Deduped by content as well as id — a retried or re-emitted reply
        arrives under a fresh message id, which the (mid, idx) guard cannot
        catch. And the block is found by its CONTENT, never by position: the
        event's content list is not the stream's index space. A thinking
        block holds stream index 0 and the CLI then emits the finished text
        block ALONE, at position 0 of its own event; looked up by position,
        every streamed reply behind a thinking block found a fresh Block with
        nothing consumed and was spoken a second time — the all-day doubling
        of 2026-08-07."""
        fingerprint = " ".join(text.split())
        if (mid, idx) in self.closed or fingerprint in self.spoken_texts:
            return
        self.closed.add((mid, idx))
        if fingerprint:
            self.spoken_texts.add(fingerprint)
        b = None
        for cand in self.blocks.values():
            if (cand.raw and text
                    and (text.startswith(cand.raw)
                         or cand.raw.startswith(text))
                    and (b is None or len(cand.raw) > len(b.raw))):
                b = cand
        b = b or Block(self.say)
        b.close(text)
