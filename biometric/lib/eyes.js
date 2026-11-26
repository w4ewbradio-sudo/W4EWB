// Signs of tiredness that a camera can actually see.
//
// What is measured, all from the eyelids and jaw:
//   blink rate       blinks per minute
//   PERCLOS          share of time the eyes are at least 80% closed. This is the
//                    standard drowsiness measure from driver-monitoring research
//                    (Wierwille & Ellsworth 1994; Dinges & Grace 1998).
//   long closures    lids shut for half a second or more - slow blinks, nodding off
//   yawns            mouth held wide open for a second and a half or more
//
// What is NOT claimed: how tired someone feels, or how much sleep they got. These
// are visible signs over the last minute, nothing more.
//
// Eyelid closure comes from the face model as a number from 0 (open) to 1 (shut),
// but the usable range differs from person to person (glasses, eye shape), so it
// is rescaled to each person's own open and shut levels as they are observed.

import { quantile, median } from './dsp.js';

const WINDOW_MS = 60000;     // judged over the last minute
const NEED_MS = 30000;       // ...once at least half of it had readable eyes
const LONG_MS = 500;         // closure this long is not a normal blink
const MIN_BLINK_MS = 60;     // shorter than this is jitter, not a blink
const MAX_DT_MS = 100;       // a frame never stands for more time than this
const SLOW_DT_MS = 80;       // slower than ~12 frames a second cannot time a blink
const SHUT_FLOOR = 0.4;      // "shut" is never taken to be lower than this raw value
const SHUT_DEFAULT = 0.5;    // assumed until real blinks have been seen

export class EyeTracker {
  constructor() {
    this.s = [];             // usable frames: {t, c, dt, closed}
    this.events = [];        // finished closures: {t, ms}
    this.peaks = [];         // peak raw closure of recent blinks, for the personal "shut" level
    this.open = 0.1;         // personal "open" level (raw)
    this.shut = SHUT_DEFAULT;
    this.calibrated = false;
    this.cur = null;         // closure in progress: {start, peak}
    this.lastUsable = null;
    this.lastCal = -Infinity;
    this.n = 0;              // current closure on the personal 0..1 scale
    this.lastSeen = null;
  }

  /** One frame: raw closure 0..1 (null if no face); usable=false when the eyes cannot be trusted. */
  push(tMs, closure, usable = true) {
    while (this.s.length && tMs - this.s[0].t > WINDOW_MS) this.s.shift();
    while (this.events.length && tMs - this.events[0].t > WINDOW_MS) this.events.shift();
    if (closure == null || !usable) {
      this.cur = null;                       // a closure cut off by a gap is discarded
      this.lastUsable = null;
      return;
    }
    if (tMs - this.lastCal >= 1000) this._calibrate(tMs);
    const dt = this.lastUsable == null ? 33 : Math.min(MAX_DT_MS, tMs - this.lastUsable);
    this.lastUsable = tMs;
    this.lastSeen = tMs;
    const n = Math.min(1.2, Math.max(0, (closure - this.open) / Math.max(0.05, this.shut - this.open)));
    this.n = n;
    this.s.push({ t: tMs, c: closure, dt, closed: n >= 0.8 });

    if (!this.cur) {
      if (n >= 0.5) this.cur = { start: tMs, peak: closure };
    } else if (n < 0.3) {
      const ms = tMs - this.cur.start;
      if (ms >= MIN_BLINK_MS) {
        this.events.push({ t: tMs, ms });
        this.peaks.push(this.cur.peak);
        if (this.peaks.length > 20) this.peaks.shift();
      }
      this.cur = null;
    } else {
      this.cur.peak = Math.max(this.cur.peak, closure);
    }
  }

  _calibrate(tMs) {
    this.lastCal = tMs;
    if (this.s.length >= 30) {
      // Eyes are open most of the time, so the low end of what was seen is "open".
      // Only ever move toward more open: drooping lids must not become the new normal.
      const p10 = quantile(this.s.map(x => x.c), 0.1);
      this.open = this.calibrated ? Math.min(this.open, p10) : p10;
      this.calibrated = true;
    }
    if (this.peaks.length >= 3) this.shut = Math.max(SHUT_FLOOR, quantile(this.peaks, 0.75));
  }

  read(nowMs) {
    const s = this.s.filter(x => nowMs - x.t <= WINDOW_MS);
    const usableMs = s.reduce((a, x) => a + x.dt, 0);
    const seen = this.lastSeen != null && nowMs - this.lastSeen < 500;
    const base = {
      state: 'collecting', reason: null, secondsLeft: Math.max(0, (NEED_MS - usableMs) / 1000),
      blinksPerMin: null, perclos: null, longClosures: null, meanBlinkMs: null, blinks: null,
      openness: seen ? Math.max(0, Math.min(1, 1 - this.n)) : null,
      usableSeconds: usableMs / 1000,
    };

    const recent = s.filter(x => nowMs - x.t <= 5000);
    if (recent.length >= 10 && median(recent.map(x => x.dt)) > SLOW_DT_MS) {
      return { ...base, state: 'unreadable', reason: 'slow-camera' };
    }
    if (this.lastSeen == null || nowMs - this.lastSeen > 3000) {
      return { ...base, state: 'unreadable', reason: 'no-eyes' };
    }
    const ev = this.events.filter(e => nowMs - e.t <= WINDOW_MS);
    const blinks = ev.filter(e => e.ms < LONG_MS);
    if (usableMs < NEED_MS) return { ...base, blinks: ev.length };

    const closedMs = s.reduce((a, x) => a + (x.closed ? x.dt : 0), 0);
    return {
      ...base, state: 'ready', secondsLeft: 0, blinks: ev.length,
      blinksPerMin: Math.round(ev.length * 60000 / usableMs * 10) / 10,
      perclos: closedMs / usableMs,
      longClosures: ev.length - blinks.length,
      meanBlinkMs: blinks.length ? blinks.reduce((a, e) => a + e.ms, 0) / blinks.length : null,
    };
  }
}

const YAWN_OPEN = 0.55, YAWN_SHUT = 0.35, YAWN_MS = 1500;

/** Counts yawns: jaw opening (0..1 from the face model) held wide for 1.5 s or more. */
export class YawnDetector {
  constructor() { this.start = null; this.last = null; this.yawns = []; this.active = false; }

  push(tMs, jawOpen) {
    if (jawOpen == null || (this.last != null && tMs - this.last > 500)) { this.start = null; this.active = false; }
    this.last = tMs;
    if (jawOpen == null) return;
    if (this.start == null) {
      if (jawOpen >= YAWN_OPEN) this.start = tMs;
    } else if (jawOpen < YAWN_SHUT) {
      this.start = null; this.active = false;
    } else if (!this.active && tMs - this.start >= YAWN_MS) {
      this.active = true;
      this.yawns.push(tMs);
      if (this.yawns.length > 50) this.yawns.shift();
    }
  }

  /** Yawns in the `windowMs` before `nowMs`. */
  count(nowMs, windowMs) { return this.yawns.filter(t => nowMs - t <= windowMs && t <= nowMs).length; }
  get yawningNow() { return this.active; }
}

/**
 * Overall verdict from the evidence. Bands for PERCLOS follow the drowsiness
 * literature: under 8% is alert, 8-15% is questionable, 15% and over is drowsy.
 */
export function tiredness({ perclos, longClosures, yawns }) {
  const signs = [];
  if (perclos >= 0.08) signs.push({ key: 'perclos', text: `eyes closed ${Math.round(perclos * 100)}% of the time` });
  if (longClosures >= 1) signs.push({ key: 'long', text: `${longClosures} slow eye closure${longClosures === 1 ? '' : 's'}` });
  if (yawns >= 1) signs.push({ key: 'yawn', text: `${yawns} yawn${yawns === 1 ? '' : 's'}` });
  const level = perclos >= 0.15 || longClosures >= 3 ? 'strong' : signs.length ? 'some' : 'none';
  return { level, signs };
}
