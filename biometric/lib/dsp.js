// Small signal-processing toolkit shared by the readouts. No dependencies.

/** In-place radix-2 FFT. re/im lengths must be the same power of two. */
export function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang), half = len >> 1;
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < half; k++) {
        const a = i + k, b = a + half;
        const vr = re[b] * cr - im[b] * ci, vi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - vr; im[b] = im[a] - vi;
        re[a] += vr; im[a] += vi;
        const t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
      }
    }
  }
}

/**
 * Power at each frequency from 0 to half the sample rate (nfft/2+1 values).
 * The average is removed and a Hann taper applied first; nfft > x.length
 * zero-pads, which gives finer frequency steps for locating a peak.
 */
export function powerSpectrum(x, nfft) {
  const n = x.length, re = new Float64Array(nfft), im = new Float64Array(nfft);
  let mean = 0;
  for (let i = 0; i < n; i++) mean += x[i];
  mean /= n || 1;
  for (let i = 0; i < n; i++) re[i] = (x[i] - mean) * (0.5 - 0.5 * Math.cos(2 * Math.PI * i / (n - 1)));
  fft(re, im);
  const p = new Float64Array(nfft / 2 + 1);
  for (let k = 0; k < p.length; k++) p[k] = re[k] * re[k] + im[k] * im[k];
  return p;
}

/** Linear-interpolated quantile, q from 0 to 1. Does not modify the input. */
export function quantile(values, q) {
  const s = Array.from(values).sort((a, b) => a - b);
  if (!s.length) return NaN;
  const pos = (s.length - 1) * q, lo = Math.floor(pos), hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

export const median = values => quantile(values, 0.5);

function biquad(type, fc, fs) {
  const w = 2 * Math.PI * fc / fs, c = Math.cos(w), alpha = Math.sin(w) / Math.SQRT2;
  const a0 = 1 + alpha;
  const b = type === 'low' ? [(1 - c) / 2, 1 - c, (1 - c) / 2] : [(1 + c) / 2, -(1 + c), (1 + c) / 2];
  return { b0: b[0] / a0, b1: b[1] / a0, b2: b[2] / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0 };
}

function run(k, x) {
  const y = new Float64Array(x.length);
  let x1 = x[0] || 0, x2 = x1, y1 = 0, y2 = 0;
  if (k.b0 + k.b1 + k.b2 > 1e-9) y1 = y2 = x1;      // low-pass: start settled on the first value
  for (let i = 0; i < x.length; i++) {
    const v = k.b0 * x[i] + k.b1 * x1 + k.b2 * x2 - k.a1 * y1 - k.a2 * y2;
    x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v;
  }
  return y;
}

/** Zero-phase band-pass (Butterworth high-pass then low-pass, run forward and backward). */
export function bandpass(x, fs, lowHz, highHz) {
  const stages = [biquad('high', lowHz, fs), biquad('low', highHz, fs)];
  let y = Float64Array.from(x);
  for (let pass = 0; pass < 2; pass++) {
    for (const s of stages) y = run(s, y);
    y.reverse();
  }
  return y;
}
