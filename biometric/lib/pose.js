// Head angle, movement, and the checks that decide whether each readout is
// allowed to speak. A readout that is blocked here shows the reason, never a number.

const deg = r => r * 180 / Math.PI;

/**
 * Head angles in degrees from the face model's 4x4 pose matrix (16 numbers,
 * column by column). The camera looks down its -z axis with +x to its right and
 * +y up, so the face's z axis is the direction the nose points.
 *   yaw    positive = turned toward the person's own left
 *   pitch  positive = looking up
 *   roll   positive = top of the head tilted toward the person's own right
 */
export function headAngles(m) {
  if (!m || m.length < 16) return null;
  // R[row][col] = m[col * 4 + row]
  const r02 = m[8], r12 = m[9], r22 = m[10], r10 = m[1], r11 = m[5];
  return {
    yaw: deg(Math.atan2(r02, r22)),
    pitch: deg(Math.asin(Math.max(-1, Math.min(1, r12)))),
    roll: deg(Math.atan2(r10, r11)),
  };
}

const MOVE_BASELINE_MS = 200;   // speed is measured over this long, so tracker jitter averages out
const MOVE_SMOOTH_MS = 200;
export const MAX_SPEED = 0.35;  // eye-distances per second (roughly 2 cm a second)
export const MAX_TURN = 12;     // degrees per second

/**
 * Is the head moving too much for a pulse reading? Speed is measured in units of
 * the distance between the eyes, so it means the same thing near or far.
 */
export class MotionMeter {
  constructor() { this.h = []; this.speed = 0; this.turn = 0; this.lastT = null; }

  push(tMs, centre, eyeDistPx, angles) {
    if (this.lastT != null && tMs - this.lastT > 500) { this.h = []; this.speed = 0; this.turn = 0; }
    this.h.push({ t: tMs, x: centre.x, y: centre.y, a: angles });
    while (this.h.length > 2 && tMs - this.h[1].t >= MOVE_BASELINE_MS) this.h.shift();
    const old = this.h[0], dt = (tMs - old.t) / 1000;
    if (dt >= 0.05) {
      const speed = Math.hypot(centre.x - old.x, centre.y - old.y) / Math.max(1, eyeDistPx) / dt;
      const turn = angles && old.a
        ? Math.max(Math.abs(angles.yaw - old.a.yaw), Math.abs(angles.pitch - old.a.pitch), Math.abs(angles.roll - old.a.roll)) / dt
        : 0;
      const k = this.lastT == null ? 1 : 1 - Math.exp(-(tMs - this.lastT) / MOVE_SMOOTH_MS);
      this.speed += (speed - this.speed) * k;
      this.turn += (turn - this.turn) * k;
    }
    this.lastT = tMs;
    return { moving: this.speed > MAX_SPEED || this.turn > MAX_TURN, speed: this.speed, turn: this.turn };
  }
}

export const LIMITS = {
  minEyeDistPx: 40,     // smaller than this and there are too few skin pixels for a pulse
  minLuma: 55,          // mean skin brightness, 0-255
  maxLuma: 225,
  maxClipped: 0.12,     // share of skin pixels blown out to white
  minFpsPulse: 12,
  minFpsEyes: 15,       // blinks last about a tenth of a second
  maxYaw: 30,
  maxPitch: 25,
};

/**
 * Can the camera see well enough? Returns the individual checks for display,
 * plus for each readout either null (go ahead) or the plain-language reason it
 * cannot be read right now.
 *
 * input: { face, eyeDistPx, luma, clipped, fps, moving, angles }
 */
export function conditions(c) {
  const L = LIMITS, fps = Math.round(c.fps || 0), frames = fps === 1 ? 'frame' : 'frames';
  if (!c.face) {
    const why = 'No face in view';
    return {
      checks: [{ key: 'face', ok: false, label: 'Face', detail: 'not found' }],
      pulse: why, eyes: why, expression: why,
    };
  }
  const dark = c.luma < L.minLuma, glare = c.luma > L.maxLuma || c.clipped > L.maxClipped;
  const small = c.eyeDistPx < L.minEyeDistPx;
  const a = c.angles;
  const turned = !a || Math.abs(a.yaw) > L.maxYaw || Math.abs(a.pitch) > L.maxPitch;
  const checks = [
    { key: 'face', ok: true, label: 'Face', detail: 'locked' },
    { key: 'size', ok: !small, label: 'Distance', detail: small ? 'too far' : 'good' },
    { key: 'light', ok: !dark && !glare, label: 'Light', detail: dark ? 'too dark' : glare ? 'glare' : 'good' },
    { key: 'still', ok: !c.moving, label: 'Stillness', detail: c.moving ? 'moving' : 'steady' },
    { key: 'facing', ok: !turned, label: 'Facing', detail: turned ? 'turned away' : 'camera' },
    { key: 'fps', ok: fps >= L.minFpsEyes, label: 'Camera', detail: `${fps} ${frames}/s` },
  ];
  const slow = `Camera is too slow (${fps} ${frames} a second), usually from low light`;
  const away = 'Face turned away: look toward the camera';
  return {
    checks,
    pulse: small ? 'Move closer: the face is too small in the frame'
      : dark ? 'Too dark: put more light on your face'
        : glare ? 'Too bright: there is glare on the skin'
          : fps < L.minFpsPulse ? slow
            : c.moving ? 'Hold still: movement drowns out the pulse'
              : null,
    eyes: turned ? away : fps < L.minFpsEyes ? slow : null,
    expression: turned ? away : null,
  };
}
