// Heart rate from the colour of skin (remote photoplethysmography, "rPPG").
//
// Each heartbeat pushes a little more blood into the skin, which changes its
// colour by a fraction of a percent. Averaging a few thousand forehead and cheek
// pixels makes that visible. The colour mix is the published POS method
// (Wang, den Brinker, Stuijk & de Haan, "Algorithmic Principles of Remote PPG",
// IEEE TBME 2017), which is built to cancel plain brightness changes.
//
// The part that matters for honesty is the gate at the end. Random noise always
// has a strongest frequency, and now and then that frequency looks convincing in
// any single stretch of video. What noise does not do is put its strongest
// frequency in the same place in separate stretches. So a rate is shown only
// when it stands clear of the noise AND repeats across independent ten-second
// windows (or stands out overwhelmingly in one). A stronger pulse is confirmed
// sooner; a faint one takes longer; anything else is "no reading" with a reason.

import { powerSpectrum, bandpass, median } from './dsp.js';

export const FS = 30;             // everything is resampled to 30 samples a second
export const WINDOW_S = 10;       // seconds of signal behind each estimate
export const BAND = [0.7, 3.0];   // where a pulse is accepted: 42 to 180 beats a minute
const SEARCH = [0.6, 3.2];        // searched slightly wider so a peak on the edge can be refused
const FLOOR = [0.5, 5.0];         // range used to judge the background noise level
const NFFT = 4096;
const GAP_MS = 400;               // a longer hole in the data means start over
const MAX_MOVING = 0.2;           // tolerated share of "moving" frames in a window
const KEEP_S = WINDOW_S + 4;      // raw samples kept
const HIST_S = 32;                // estimates kept (one a second)

export const DEFAULTS = {
  strongDb: 17,     // one window this clear is enough (with a second look 3 s earlier)
  pairDb: 12,       // two windows 10 s apart, both this clear, same rate
  tripleDb: 9,      // three windows 10 s apart, all this clear, same rate
  holdDb: 7,        // once reading, an estimate this clear at the same rate keeps it
  agreeBpm: 5,      // "same rate" tolerance
  slowBpm: 55,      // below this rate the bars above are raised by slowExtraDb, because
  slowExtraDb: 3,   // slow colour drift lives at the low end and can imitate a slow pulse
  maxMisses: 3,     // seconds a reading survives without support
};

/** Straight-line resample of v(t) onto n evenly spaced points starting at t0 (ms). */
export function resample(t, v, t0, n, fs) {
  const out = new Float64Array(n);
  let j = 0;
  for (let i = 0; i < n; i++) {
    const x = t0 + i * 1000 / fs;
    while (j < t.length - 2 && t[j + 1] < x) j++;
    const span = t[j + 1] - t[j];
    const f = span > 0 ? Math.min(1, Math.max(0, (x - t[j]) / span)) : 0;
    out[i] = v[j] + (v[j + 1] - v[j]) * f;
  }
  return out;
}

/** POS: turn evenly sampled R, G, B skin averages into one pulse signal. */
export function pos(r, g, b, fs) {
  const n = r.length, l = Math.round(1.6 * fs), h = new Float64Array(n);
  const s1 = new Float64Array(l), s2 = new Float64Array(l);
  for (let s = 0; s + l <= n; s++) {
    let mr = 0, mg = 0, mb = 0;
    for (let i = s; i < s + l; i++) { mr += r[i]; mg += g[i]; mb += b[i]; }
    mr /= l; mg /= l; mb /= l;
    if (!(mr > 0 && mg > 0 && mb > 0)) continue;
    let v1 = 0, v2 = 0;
    for (let i = 0; i < l; i++) {
      const rn = r[s + i] / mr, gn = g[s + i] / mg, bn = b[s + i] / mb;
      s1[i] = gn - bn;               // both projections sum to zero across channels,
      s2[i] = gn + bn - 2 * rn;      // so a pure brightness change drops out
      v1 += s1[i] * s1[i]; v2 += s2[i] * s2[i];
    }
    const alpha = v2 > 0 ? Math.sqrt(v1 / v2) : 0;
    for (let i = 0; i < l; i++) h[s + i] += s1[i] + alpha * s2[i];
  }
  return h;
}

/**
 * Background noise level across the spectrum, as a smooth curve.
 * Two things make up the background: camera noise, which is the same at every
 * frequency, and slow colour drift (white balance, shifting light), which grows
 * steeply toward low frequencies. So the level is modelled as a + b/f^2 and
 * fitted to the median power in a dozen frequency cells. Medians ignore a
 * narrow spike, so a real pulse barely moves the fit; `skip(f)` lets the caller
 * leave a known peak out altogether on a second pass.
 */
export function noiseFloor(p, df, skip = null) {
  const cells = [];
  const ratio = Math.pow(FLOOR[1] / FLOOR[0], 1 / 12);
  for (let lo = FLOOR[0]; lo < FLOOR[1] * 0.999; lo *= ratio) {
    const vals = [];
    for (let i = Math.ceil(lo / df); i < Math.ceil(lo * ratio / df); i++) if (!skip || !skip(i * df)) vals.push(p[i]);
    if (vals.length >= 6) cells.push({ g: 1 / (lo * lo * ratio), m: median(vals), n: vals.length });
  }
  let a = 0, b = 0;
  if (cells.length >= 3) {
    let fit = cells.map(c => c.m);
    for (let pass = 0; pass < 3; pass++) {                 // weight by relative error; refine twice
      let sw = 0, sg = 0, sgg = 0, sm = 0, sgm = 0;
      cells.forEach((c, j) => {
        const w = c.n / Math.max(fit[j] * fit[j], 1e-300);
        sw += w; sg += w * c.g; sgg += w * c.g * c.g; sm += w * c.m; sgm += w * c.g * c.m;
      });
      const det = sw * sgg - sg * sg;
      a = det > 0 ? (sm * sgg - sgm * sg) / det : sm / sw;
      b = det > 0 ? (sw * sgm - sg * sm) / det : 0;
      if (b < 0) { b = 0; a = sm / sw; }
      if (a < 0) { a = 0; b = sgm / sgg; }
      fit = cells.map(c => Math.max(a + b * c.g, 1e-300));
    }
  } else if (cells.length) {
    a = median(cells.map(c => c.m));
  }
  return f => a + b / (f * f);
}

/**
 * Strongest rhythm in the pulse band and how far it stands above the background.
 * The spectrum is first divided by the fitted background (see noiseFloor), so
 * that drift cannot pose as a slow pulse, and only then searched for its peak.
 * Returns clearDb = peak over background in dB, and edge = true if the strongest
 * rhythm sits outside the accepted range (so there is no real peak to report).
 */
export function analyse(h, fs) {
  const p = powerSpectrum(h, NFFT), df = fs / NFFT;
  const lo = Math.round(SEARCH[0] / df), hi = Math.round(SEARCH[1] / df);
  let floor = noiseFloor(p, df), hz = 0, k = lo;
  for (let pass = 0; pass < 2; pass++) {
    k = lo;
    for (let i = lo; i <= hi; i++) if (p[i] / floor(i * df) > p[k] / floor(k * df)) k = i;
    hz = k * df;
    const f0 = hz;
    if (pass === 0) floor = noiseFloor(p, df, f => Math.abs(f - f0) <= 0.25 || Math.abs(f - 2 * f0) <= 0.3);
  }
  if (k > lo && k < hi) {                          // refine between bins
    const d = p[k - 1] - 2 * p[k] + p[k + 1];
    if (d < 0) hz += 0.5 * (p[k - 1] - p[k + 1]) / d * df;
  }
  const edge = hz < BAND[0] || hz > BAND[1] || !(p[k] > 0);
  let sig = 0, nsig = 0;
  for (let i = Math.round((hz - 0.1) / df); i <= Math.round((hz + 0.1) / df); i++) { sig += p[i] / floor(i * df); nsig++; }
  sig /= nsig || 1;
  const clearDb = sig > 0 && isFinite(sig) ? 10 * Math.log10(sig) : -60;
  return { hz, bpm: hz * 60, clearDb, edge };
}

function blank() {
  return { state: 'measuring', bpm: null, clearDb: null, reason: null, secondsLeft: WINDOW_S,
    confirmedBy: null, wave: new Float64Array(0) };
}

export class PulseTracker {
  constructor(opts = {}) {
    this.o = { ...DEFAULTS, ...opts };
    this.reset();
  }

  reset() {
    this.buf = [];            // {t, r, g, b, moving}
    this.hist = [];           // one estimate a second: {t, bpm, clearDb, ok, why}
    this.lastCalc = -Infinity;
    this.locked = null;       // {bpm, misses, by} while a reading is being shown
    this.out = blank();
  }

  /** One video frame: mean skin colour {r,g,b}, or null when no skin could be sampled. */
  push(tMs, rgb, moving = false) {
    const lastT = this.buf.length ? this.buf[this.buf.length - 1].t : null;
    if (!rgb) {
      if (lastT !== null && tMs - lastT > GAP_MS) this.reset();
      return;
    }
    if (lastT !== null) {
      if (tMs <= lastT) return;
      if (tMs - lastT > GAP_MS) this.reset();
    }
    this.buf.push({ t: tMs, r: rgb.r, g: rgb.g, b: rgb.b, moving: !!moving });
    while (tMs - this.buf[0].t > KEEP_S * 1000) this.buf.shift();
  }

  /** The estimate made closest to `ago` seconds before the newest one. */
  _at(ago) {
    const now = this.hist[this.hist.length - 1].t;
    let best = null, bestD = 0.75;
    for (const e of this.hist) {
      const d = Math.abs((now - e.t) / 1000 - ago);
      if (d <= bestD) { best = e; bestD = d; }
    }
    return best;
  }

  /** Has a rate been confirmed by the newest estimate? Returns {bpm, by} or null. */
  _confirm() {
    const o = this.o, cur = this.hist[this.hist.length - 1];
    if (!cur.ok) return null;
    const same = (a, b) => a && b && a.ok && b.ok && Math.abs(a.bpm - b.bpm) <= o.agreeBpm;
    const clear = (e, db) => e.clearDb >= db + (e.bpm < o.slowBpm ? o.slowExtraDb : 0);
    const e3 = this._at(3), e10 = this._at(10), e20 = this._at(20);
    if (clear(cur, o.strongDb) && same(cur, e3) && clear(e3, o.pairDb)) {
      return { bpm: cur.bpm, by: 'strong' };
    }
    if (clear(cur, o.pairDb) && same(cur, e10) && clear(e10, o.pairDb)) {
      return { bpm: (cur.bpm + e10.bpm) / 2, by: 'pair' };
    }
    if (clear(cur, o.tripleDb) && same(cur, e10) && same(cur, e20) && same(e10, e20)
      && clear(e10, o.tripleDb) && clear(e20, o.tripleDb)) {
      return { bpm: median([cur.bpm, e10.bpm, e20.bpm]), by: 'triple' };
    }
    return null;
  }

  /** Current answer. Recomputed at most once a second; cheap to call every frame. */
  read(nowMs) {
    const buf = this.buf, o = this.o;
    if (buf.length < 2) return this.out;
    const end = buf[buf.length - 1].t, span = (end - buf[0].t) / 1000;
    if (span < WINDOW_S) {
      this.out = { ...this.out, state: 'measuring', bpm: null, reason: null, secondsLeft: WINDOW_S - span };
      return this.out;
    }
    if (nowMs - this.lastCalc < 1000) return this.out;
    this.lastCalc = nowMs;

    const t0 = end - WINDOW_S * 1000, n = WINDOW_S * FS;
    const win = buf.filter(s => s.t >= t0 - 100);
    const t = win.map(s => s.t);
    const h = pos(resample(t, win.map(s => s.r), t0, n, FS), resample(t, win.map(s => s.g), t0, n, FS),
      resample(t, win.map(s => s.b), t0, n, FS), FS);
    const est = analyse(h, FS);
    const movingShare = win.filter(s => s.moving).length / win.length;
    const why = movingShare > MAX_MOVING ? 'movement' : est.edge || est.clearDb < o.holdDb ? 'weak' : null;
    this.hist.push({ t: nowMs, bpm: est.bpm, clearDb: est.clearDb, ok: !why, why });
    while (nowMs - this.hist[0].t > HIST_S * 1000) this.hist.shift();
    const cur = this.hist[this.hist.length - 1];
    const wave = bandpass(h, FS, BAND[0], BAND[1]);

    if (this.locked) {
      const near = e => e.ok && Math.abs(e.bpm - this.locked.bpm) <= o.agreeBpm + 1;
      if (near(cur)) {
        this.locked.misses = 0;
        this.locked.bpm = median(this.hist.slice(-5).filter(near).map(e => e.bpm));
      } else if (++this.locked.misses > o.maxMisses || why === 'movement') {
        this.locked = null;
      }
    }
    if (!this.locked) {
      const c = this._confirm();
      if (c) this.locked = { bpm: c.bpm, misses: 0, by: c.by };
    }

    if (this.locked) {
      this.out = { state: 'reading', bpm: this.locked.bpm, clearDb: est.clearDb, reason: null, secondsLeft: 0,
        confirmedBy: this.locked.by, wave };
    } else {
      // Enough signal to be worth waiting on? Then it is still being confirmed.
      const hopeful = cur.ok && cur.clearDb >= o.tripleDb;
      this.out = { state: hopeful ? 'confirming' : 'noread', bpm: null, clearDb: est.clearDb,
        reason: hopeful ? null : (why || 'weak'), secondsLeft: 0, confirmedBy: null, wave };
    }
    return this.out;
  }
}
