// Facial expression, read from muscle movements.
//
// The face model reports about fifty "blendshapes": numbers from 0 to 1 for
// movements such as the lip corners pulling up or the brows lowering. Those are
// measurements. Turning them into a word like "happy" is an interpretation, and
// this file keeps the interpretation narrow on purpose:
//
//   * Every movement is judged against the person's own resting face, because
//     resting faces differ (a naturally low brow is not anger).
//   * Four expressions are named, each by the combination of movements the
//     Facial Action Coding System lists for it (Ekman & Friesen):
//       happy      lip corners pulled up
//       surprised  brows raised, with eyes widened or jaw dropped
//       angry      brows lowered (reinforced by pressed lips)
//       sad        inner brows raised alone, with mouth corners or chin pulled down
//   * A name is given only when one of those clearly beats the others. A face
//     that is moving in some other way is reported as "unclear", not guessed at.
//   * Fear and disgust are not attempted. Fear looks like surprise at this
//     resolution, and the model's nose-wrinkle signal (disgust) barely responds.
//
// And always: this reads what a face is doing, not what a person is feeling.

import { quantile } from './dsp.js';

// Per movement: `cap` = the most its resting level is allowed to be (so a person
// who starts out smiling is not taken to have a smiling resting face), `span` =
// how far above rest counts as fully made.
const SPEC = {
  smile: { cap: 0.15, span: 0.6 },
  browsUp: { cap: 0.25, span: 0.5 },
  browInner: { cap: 0.3, span: 0.5 },
  browOuter: { cap: 0.25, span: 0.5 },
  browsDown: { cap: 0.35, span: 0.45 },
  eyesWide: { cap: 0.15, span: 0.35 },
  jawOpen: { cap: 0.1, span: 0.5 },
  lipsPressed: { cap: 0.35, span: 0.4 },
  frown: { cap: 0.12, span: 0.25 },
  chin: { cap: 0.3, span: 0.45 },
};
const KEYS = Object.keys(SPEC);
const DEADBAND = 0.04;        // movement this small above rest is ignored
const SMOOTH_MS = 150;        // smoothing time for the raw movements
const HOLD_MS = 250;          // a new label must last this long before it is shown
const NAME_MIN = 0.25;        // weakest expression that gets a name
const REST_WINDOW_MS = 90000;
const MIN_REST_SAMPLES = 10;  // about a second of face before anything is said
const STALE_MS = 500;

const pair = (b, name) => ((b[name + 'Left'] || 0) + (b[name + 'Right'] || 0)) / 2;

/** The ten movements this file uses, from the face model's blendshape scores. */
export function features(b) {
  const inner = b.browInnerUp || 0, outer = pair(b, 'browOuterUp');
  return {
    smile: pair(b, 'mouthSmile'),
    browsUp: (inner + 2 * outer) / 3,
    browInner: inner,
    browOuter: outer,
    browsDown: pair(b, 'browDown'),
    eyesWide: pair(b, 'eyeWide'),
    jawOpen: b.jawOpen || 0,
    lipsPressed: pair(b, 'mouthPress'),
    frown: pair(b, 'mouthFrown'),
    chin: b.mouthShrugLower || 0,
  };
}

/** Expression scores (0..1) from movement levels measured above rest. */
export function score(a) {
  const widened = Math.max(a.eyesWide, a.jawOpen);
  const innerOnly = Math.max(0, a.browInner - a.browOuter);
  const mouthDown = Math.max(a.frown, a.chin);
  return {
    happy: a.smile,
    surprised: a.browsUp >= 0.25 && widened >= 0.2 ? 0.6 * a.browsUp + 0.4 * widened : 0,
    // A smile bunches the brows down as well, so lowered brows count toward anger only
    // to the extent the lip corners are not pulled up.
    angry: a.browsDown >= 0.3 ? (0.75 * a.browsDown + 0.25 * a.lipsPressed) * (1 - a.smile) : 0,
    sad: innerOnly >= 0.2 && mouthDown >= 0.25 ? 0.5 * innerOnly + 0.5 * mouthDown : 0,
  };
}

export class ExpressionReader {
  constructor() {
    this.smooth = null;       // smoothed movements
    this.rest = null;         // personal resting level per movement
    this.samples = [];        // {t, f} about ten a second, for the resting level
    this.lastT = null;
    this.lastSample = -Infinity;
    this.lastCal = -Infinity;
    this.shown = null;        // label currently shown
    this.pending = null;      // {label, since} waiting out HOLD_MS
    this.out = { state: 'calibrating', label: null, strength: null, movements: null };
  }

  /** One frame: blendshape scores as {name: 0..1}, or null with no face. usable=false if turned away. */
  push(tMs, blend, usable = true) {
    if (!blend || !usable) return;
    const f = features(blend);
    if (!this.smooth || tMs - this.lastT > STALE_MS) {
      this.smooth = { ...f };
    } else {
      const k = 1 - Math.exp(-(tMs - this.lastT) / SMOOTH_MS);
      for (const key of KEYS) this.smooth[key] += (f[key] - this.smooth[key]) * k;
    }
    this.lastT = tMs;
    if (tMs - this.lastSample >= 100) {
      this.lastSample = tMs;
      this.samples.push({ t: tMs, f: { ...this.smooth } });
      while (tMs - this.samples[0].t > REST_WINDOW_MS) this.samples.shift();
    }
    if (tMs - this.lastCal >= 1000 || !this.rest) this._calibrate(tMs);
  }

  _calibrate(tMs) {
    if (this.samples.length < MIN_REST_SAMPLES) return;
    this.lastCal = tMs;
    // A resting face is the most common state, and every movement only ever adds
    // to it, so the low end of what has been seen is the resting level.
    this.rest = {};
    for (const key of KEYS) {
      this.rest[key] = Math.min(SPEC[key].cap, quantile(this.samples.map(s => s.f[key]), 0.2));
    }
  }

  read(nowMs) {
    if (this.lastT == null || nowMs - this.lastT > STALE_MS) {
      this.shown = this.pending = null;
      return (this.out = { state: 'unreadable', label: null, strength: null, movements: null });
    }
    if (!this.rest) return (this.out = { state: 'calibrating', label: null, strength: null, movements: null });

    const a = {};
    for (const key of KEYS) {
      a[key] = Math.min(1, Math.max(0, (this.smooth[key] - this.rest[key] - DEADBAND) / SPEC[key].span));
    }
    const movements = { smile: a.smile, browsUp: a.browsUp, browsDown: a.browsDown, eyesWide: a.eyesWide,
      jawOpen: a.jawOpen, lipsPressed: a.lipsPressed, mouthDown: Math.max(a.frown, a.chin) };

    const ranked = Object.entries(score(a)).sort((x, y) => y[1] - x[1]);
    const [best, second] = ranked;
    let label, strength = null;
    if (best[1] >= NAME_MIN && best[1] - second[1] >= Math.max(0.15, 0.3 * best[1])) {
      label = best[0]; strength = best[1];
    } else if (best[1] < NAME_MIN && Math.max(...Object.values(movements)) < NAME_MIN) {
      label = 'neutral';
    } else {
      label = 'unclear';
    }

    if (this.shown == null) {
      this.shown = label;
    } else if (label !== this.shown) {
      if (!this.pending || this.pending.label !== label) this.pending = { label, since: nowMs };
      else if (nowMs - this.pending.since >= HOLD_MS) { this.shown = label; this.pending = null; }
    } else {
      this.pending = null;
    }
    const shownStrength = this.shown === label ? strength : null;
    return (this.out = { state: 'ready', label: this.shown, strength: shownStrength, movements });
  }
}
