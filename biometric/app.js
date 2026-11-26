// Biometric demo: wires the camera and the face tracker to the readouts.
// All measuring logic lives in ./lib (and is unit tested); this file only
// collects per-frame inputs, asks each readout for its answer, and draws it.
//
// Rule for everything shown here: a readout either has a value its own checks
// accept, or it shows "No reading" and the reason. There is no demo mode and no
// placeholder number.

import { PulseTracker } from './lib/pulse.js';
import { EyeTracker, YawnDetector, tiredness } from './lib/eyes.js';
import { ExpressionReader } from './lib/expression.js';
import { headAngles, MotionMeter, conditions } from './lib/pose.js';

const MEDIAPIPE = 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.21';
const MODEL = 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task';
const YAWN_WINDOW_MS = 5 * 60 * 1000;
const DEBUG = new URLSearchParams(location.search).has('debug');

const $ = id => document.getElementById(id);
const video = $('video'), overlay = $('overlay'), octx = overlay.getContext('2d');
const scratch = document.createElement('canvas');
const sctx = scratch.getContext('2d', { willReadFrequently: true });

let landmarker = null, FaceLandmarker = null, stream = null, running = false;
let pulse, eyes, yawns, expr, motion;
let frameTimes = [], lastT = 0, lastText = 0, lastFrameWall = 0, lastGood = null, dbg = {};

function resetTrackers() {
  pulse = new PulseTracker(); eyes = new EyeTracker(); yawns = new YawnDetector();
  expr = new ExpressionReader(); motion = new MotionMeter();
  frameTimes = []; lastGood = null;
}

/* ---------- start / stop ---------- */

function status(text, live) {
  $('statT').textContent = text;
  $('stat').className = 'stat ' + (live ? 'g' : 'off');
}

function intro(text, { problem = false, button = 'Start camera' } = {}) {
  $('intro').hidden = false;
  $('intro').style.display = '';
  $('introText').textContent = text;
  $('introText').className = problem ? 'problem' : '';
  $('start').textContent = button;
  $('start').disabled = false;
}

function cameraProblem(e) {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    return 'This browser will not give a web page the camera here. Open the page over https in a current browser.';
  }
  switch (e && e.name) {
    case 'NotAllowedError': case 'SecurityError':
      return 'Camera access was blocked. Allow the camera for this page in the address bar, then try again.';
    case 'NotFoundError': case 'OverconstrainedError':
      return 'No camera was found on this device.';
    case 'NotReadableError': case 'AbortError':
      return 'The camera is busy. Close any other app or tab that is using it, then try again.';
    default:
      return 'The camera could not be started (' + ((e && (e.message || e.name)) || 'unknown error') + ').';
  }
}

async function loadModel() {
  if (landmarker) return;
  const vision = await import(MEDIAPIPE + '/vision_bundle.mjs');
  FaceLandmarker = vision.FaceLandmarker;
  const files = await vision.FilesetResolver.forVisionTasks(MEDIAPIPE + '/wasm');
  const options = delegate => ({
    baseOptions: { modelAssetPath: MODEL, delegate },
    runningMode: 'VIDEO', numFaces: 1,
    outputFaceBlendshapes: true, outputFacialTransformationMatrixes: true,
  });
  try {
    landmarker = await FaceLandmarker.createFromOptions(files, options('GPU'));
  } catch (e) {
    landmarker = await FaceLandmarker.createFromOptions(files, options('CPU'));
  }
}

async function start() {
  $('start').disabled = true;
  $('introText').className = '';
  $('introText').textContent = 'Starting the camera and loading the face tracker (about 14 MB the first time).';
  status('Starting', false);
  try {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('no camera API');
    stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 30 } },
    });
  } catch (e) {
    status('Camera off', false);
    return intro(cameraProblem(e), { problem: true, button: 'Try again' });
  }
  try {
    video.srcObject = stream;
    await video.play();
    await loadModel();
  } catch (e) {
    stop();
    return intro('The face tracker could not be loaded (' + (e.message || e) + '). Check the connection and try again.',
      { problem: true, button: 'Try again' });
  }
  $('stage').style.aspectRatio = video.videoWidth + ' / ' + video.videoHeight;
  overlay.width = video.videoWidth; overlay.height = video.videoHeight;
  $('intro').style.display = 'none';
  $('stop').hidden = false;
  resetTrackers();
  running = true;
  lastFrameWall = performance.now();
  status('Tracking', true);
  nextFrame();
}

function stop() {
  running = false;
  if (stream) stream.getTracks().forEach(t => t.stop());
  stream = null;
  video.srcObject = null;
  octx.clearRect(0, 0, overlay.width, overlay.height);
  $('stop').hidden = true;
  status('Camera off', false);
  showOff();
  intro('Camera stopped. Nothing was saved.', { button: 'Start camera' });
}

/* ---------- per-frame work ---------- */

function nextFrame() {
  if (!running) return;
  if (video.requestVideoFrameCallback) video.requestVideoFrameCallback(onFrame);
  else requestAnimationFrame(now => onFrame(now, null));
}

let lastMediaTime = -1;
function onFrame(now, meta) {
  if (!running) return;
  if (!meta && video.currentTime === lastMediaTime) return nextFrame();   // no new picture yet
  lastMediaTime = video.currentTime;
  // Time the frame was captured when the browser says, else when it reached us.
  let t = meta && meta.captureTime ? meta.captureTime : now;
  if (t <= lastT) t = lastT + 1;
  lastT = t;
  lastFrameWall = performance.now();
  try {
    process(t);
  } catch (e) {
    console.error(e);
    stop();
    return intro('The face tracker stopped with an error (' + (e.message || e) + ').', { problem: true, button: 'Start again' });
  }
  nextFrame();
}

const px = (p, w, h) => ({ x: p.x * w, y: p.y * h });

/** Mean colour of forehead and cheek skin, plus how bright and how blown-out it is. */
function sampleSkin(lm, w, h, eyeDist) {
  const boxes = [
    { c: px(lm[151], w, h), bw: 0.55 * eyeDist, bh: 0.22 * eyeDist },   // forehead
    { c: px(lm[205], w, h), bw: 0.28 * eyeDist, bh: 0.28 * eyeDist },   // cheek
    { c: px(lm[425], w, h), bw: 0.28 * eyeDist, bh: 0.28 * eyeDist },   // other cheek
  ];
  let r = 0, g = 0, b = 0, n = 0, total = 0, clipped = 0, lumaSum = 0;
  const drawn = [];
  for (const box of boxes) {
    const bw = Math.min(160, Math.round(box.bw)), bh = Math.min(120, Math.round(box.bh));
    const x = Math.round(box.c.x - bw / 2), y = Math.round(box.c.y - bh / 2);
    if (bw < 6 || bh < 6 || x < 0 || y < 0 || x + bw > w || y + bh > h) continue;
    if (scratch.width < bw) scratch.width = bw;
    if (scratch.height < bh) scratch.height = bh;
    sctx.drawImage(video, x, y, bw, bh, 0, 0, bw, bh);
    const d = sctx.getImageData(0, 0, bw, bh).data;
    for (let i = 0; i < d.length; i += 4) {
      const R = d[i], G = d[i + 1], B = d[i + 2], luma = 0.299 * R + 0.587 * G + 0.114 * B;
      total++; lumaSum += luma;
      if (R >= 250 || G >= 250 || B >= 250) { clipped++; continue; }   // blown out: carries no colour
      if (luma < 20) continue;                                          // hair, shadow, glasses frame
      r += R; g += G; b += B; n++;
    }
    drawn.push({ x, y, w: bw, h: bh });
  }
  return {
    rgb: n >= 200 ? { r: r / n, g: g / n, b: b / n } : null,
    luma: total ? lumaSum / total : 0,
    clipped: total ? clipped / total : 0,
    boxes: drawn,
  };
}

function process(t) {
  const w = video.videoWidth, h = video.videoHeight;
  const res = landmarker.detectForVideo(video, t);
  frameTimes.push(t);
  while (frameTimes.length > 2 && t - frameTimes[0] > 2000) frameTimes.shift();
  const fps = frameTimes.length > 1 ? (frameTimes.length - 1) * 1000 / (t - frameTimes[0]) : 0;

  const lm = res.faceLandmarks && res.faceLandmarks[0];
  let cond, skin = null, angles = null;
  if (!lm) {
    cond = conditions({ face: false });
    pulse.push(t, null); eyes.push(t, null, false); yawns.push(t, null); expr.push(t, null, false);
  } else {
    const a = px(lm[33], w, h), b = px(lm[263], w, h), bridge = px(lm[6], w, h), top = px(lm[10], w, h);
    const eyeDist = Math.hypot(a.x - b.x, a.y - b.y);
    const centre = { x: (a.x + b.x + bridge.x + top.x) / 4, y: (a.y + b.y + bridge.y + top.y) / 4 };
    const mat = res.facialTransformationMatrixes && res.facialTransformationMatrixes[0];
    angles = headAngles(mat && mat.data);
    const mv = motion.push(t, centre, eyeDist, angles);
    skin = sampleSkin(lm, w, h, eyeDist);
    cond = conditions({ face: true, eyeDistPx: eyeDist, luma: skin.luma, clipped: skin.clipped, fps, moving: mv.moving, angles });

    const blend = {};
    const shapes = res.faceBlendshapes && res.faceBlendshapes[0];
    if (shapes) for (const c of shapes.categories) blend[c.categoryName] = c.score;

    // Movement is passed along with the sample (the tracker decides); any other
    // blocker means the skin colour itself cannot be trusted, so nothing is fed.
    const pulseOk = skin.rgb && (cond.pulse === null || mv.moving && blockersExceptMoving(cond) === null);
    pulse.push(t, pulseOk ? skin.rgb : null, mv.moving);
    const lids = shapes ? ((blend.eyeBlinkLeft || 0) + (blend.eyeBlinkRight || 0)) / 2 : null;
    eyes.push(t, lids, cond.eyes === null);
    yawns.push(t, shapes && cond.expression === null ? (blend.jawOpen || 0) : null);
    expr.push(t, shapes ? blend : null, cond.expression === null);
    if (DEBUG) dbg = { fps: fps.toFixed(1), eyeDist: eyeDist.toFixed(0), luma: skin.luma.toFixed(0), clipped: skin.clipped.toFixed(3),
      speed: mv.speed.toFixed(2), turn: mv.turn.toFixed(1), lids: lids == null ? null : lids.toFixed(2), jaw: (blend.jawOpen || 0).toFixed(2),
      // geometric cross-check of the yaw sign: nose tip right of the eye midline in the raw picture = turned to own left
      noseOffset: ((px(lm[1], w, h).x - (a.x + b.x) / 2) / eyeDist).toFixed(3),
      // depth cross-checks: turned to own left puts the left eye (263) farther away (larger z);
      // looking up puts the forehead (10) farther away than the chin (152)
      zYaw: (lm[263].z - lm[33].z).toFixed(3), zPitch: (lm[10].z - lm[152].z).toFixed(3),
      angles: angles && [angles.yaw, angles.pitch, angles.roll].map(v => +v.toFixed(1)) };
  }

  const p = pulse.read(t);
  if (p.state === 'reading') lastGood = { bpm: p.bpm, t };
  drawOverlay(lm, skin, p.state === 'reading', w, h);
  if (t - lastText >= 200) {
    lastText = t;
    status(lm ? 'Tracking' : 'No face', !!lm);
    showChecks(cond);
    showPulse(p, lm ? cond.pulse : 'No face in view', t);
    showExpression(expr.read(t), cond.expression);
    showTiredness(eyes.read(t), cond.eyes, t);
    showHead(angles);
    if (DEBUG) showDebug(p);
  }
}

/** The pulse blocker ignoring "moving", which the tracker handles itself. */
function blockersExceptMoving(cond) {
  return /^Hold still/.test(cond.pulse || '') ? null : cond.pulse;
}

/* ---------- drawing ---------- */

function drawOverlay(lm, skin, locked, w, h) {
  octx.clearRect(0, 0, w, h);
  if (!lm) return;
  octx.lineWidth = Math.max(1, w / 640);
  octx.strokeStyle = 'rgba(153,204,255,.55)';
  const sets = ['FACE_LANDMARKS_FACE_OVAL', 'FACE_LANDMARKS_LEFT_EYE', 'FACE_LANDMARKS_RIGHT_EYE',
    'FACE_LANDMARKS_LEFT_EYEBROW', 'FACE_LANDMARKS_RIGHT_EYEBROW', 'FACE_LANDMARKS_LIPS'];
  octx.beginPath();
  for (const name of sets) {
    for (const c of (FaceLandmarker && FaceLandmarker[name]) || []) {
      octx.moveTo(lm[c.start].x * w, lm[c.start].y * h);
      octx.lineTo(lm[c.end].x * w, lm[c.end].y * h);
    }
  }
  octx.stroke();
  if (skin) {
    // Where the pulse is read: solid gold once a heart rate is confirmed.
    octx.lineWidth = Math.max(1.5, w / 400);
    octx.strokeStyle = locked ? '#ffcc66' : 'rgba(204,153,204,.8)';
    octx.setLineDash(locked ? [] : [5, 4]);
    for (const b of skin.boxes) octx.strokeRect(b.x, b.y, b.w, b.h);
    octx.setLineDash([]);
  }
}

function drawWave(wave, trusted) {
  const c = $('hrWave'), g = c.getContext('2d'), W = c.width, H = c.height;
  g.clearRect(0, 0, W, H);
  g.strokeStyle = '#2b2b45'; g.lineWidth = 1;
  g.beginPath(); g.moveTo(0, H / 2); g.lineTo(W, H / 2); g.stroke();
  if (!wave || wave.length < 2) return;
  let peak = 0;
  for (const v of wave) peak = Math.max(peak, Math.abs(v));
  if (!(peak > 0)) return;
  g.strokeStyle = trusted ? '#ffcc66' : '#6a5a7a';
  g.lineWidth = 2.5; g.lineJoin = 'round';
  g.beginPath();
  for (let i = 0; i < wave.length; i++) {
    const x = i / (wave.length - 1) * W, y = H / 2 - wave[i] / peak * (H * 0.42);
    if (i) g.lineTo(x, y); else g.moveTo(x, y);
  }
  g.stroke();
}

/* ---------- readouts ---------- */

function value(el, text, isValue) {
  el.textContent = text;
  el.classList.toggle('na', !isValue);
}

function showChecks(cond) {
  $('checks').innerHTML = cond.checks.map(c =>
    '<div class="chk ' + (c.ok ? 'ok' : 'bad') + '"><b>' + c.label + '</b><span>' + c.detail + '</span></div>').join('');
  const bad = cond.checks.filter(c => !c.ok).length;
  $('checksNote').textContent = bad ? 'Readouts that depend on a failed check say so instead of guessing' : 'Good conditions for every readout';
}

function showPulse(p, blocker, t) {
  const el = $('hrVal');
  let sub, trusted = false;
  if (blocker && p.state !== 'reading') {
    value(el, 'No reading', false); sub = blocker + '.';
  } else if (p.state === 'reading') {
    el.innerHTML = Math.round(p.bpm) + ' <span>beats a minute</span>'; el.classList.remove('na');
    sub = 'The same rhythm was found in separate stretches of video.'; trusted = true;
  } else if (p.state === 'measuring') {
    value(el, 'Measuring', false);
    sub = 'Hold still. First look at the signal in ' + Math.ceil(p.secondsLeft) + ' s.';
  } else if (p.state === 'confirming') {
    value(el, 'Checking', false);
    sub = 'Possible rhythm. Waiting for it to repeat before trusting it, because noise can look like this too.';
  } else {
    value(el, 'No reading', false);
    sub = p.reason === 'movement' ? 'Hold still: movement drowns out the pulse.'
      : 'No steady pulse found in the skin colour yet. Even light on your face helps most; keep still.';
  }
  if (!trusted && lastGood && t - lastGood.t < 60000) {
    sub += ' Last reading: ' + Math.round(lastGood.bpm) + ', ' + Math.round((t - lastGood.t) / 1000) + ' s ago.';
  }
  $('hrSub').textContent = sub;
  const bars = $('hrMeter').children, db = p.clearDb;
  [7, 10, 13, 16, 19].forEach((min, i) => bars[i].classList.toggle('on', (trusted || !blocker) && db != null && db >= min));
  drawWave(blocker && !trusted ? null : p.wave, trusted);
  $('hrCap').textContent = trusted ? 'Skin colour signal, filtered to the range of a pulse'
    : 'Skin colour signal, filtered to the range of a pulse (not trusted yet)';
}

const EX = {
  neutral: ['Neutral', 'Face at rest.'],
  happy: ['Happy', 'lip corners pulled up.'],
  surprised: ['Surprised', 'brows raised, with eyes widened or jaw dropped.'],
  angry: ['Angry', 'brows pulled down. Concentration looks the same.'],
  sad: ['Sad', 'inner brows raised and mouth pulled down.'],
  unclear: ['Unclear', 'The face is moving, but not in a pattern this page will put a name to.'],
};

function showExpression(x, blocker) {
  const el = $('exVal');
  if (blocker || x.state === 'unreadable') {
    value(el, 'No reading', false); $('exSub').textContent = (blocker || 'No face in view') + '.';
  } else if (x.state === 'calibrating') {
    value(el, 'Starting', false); $('exSub').textContent = 'Learning what this face looks like at rest.';
  } else {
    const [name, basis] = EX[x.label];
    const named = x.label !== 'neutral' && x.label !== 'unclear';
    value(el, name, x.label !== 'unclear');
    const strength = x.strength == null ? '' : x.strength < 0.45 ? 'Slight: ' : x.strength < 0.75 ? 'Clear: ' : 'Strong: ';
    $('exSub').textContent = named ? strength + basis : basis;
  }
  for (const bar of $('exBars').querySelectorAll('i')) {
    const v = !blocker && x.movements ? x.movements[bar.dataset.m] : 0;
    bar.style.width = Math.round((v || 0) * 100) + '%';
  }
}

function showTiredness(e, blocker, t) {
  const el = $('tiVal'), y = yawns.count(t, YAWN_WINDOW_MS);
  const set = (id, text) => { $(id).textContent = text; };
  set('tiYawn', String(y));
  $('tiOpen').style.width = (e.openness == null || blocker ? 0 : Math.round(e.openness * 100)) + '%';
  if (blocker || e.state === 'unreadable') {
    value(el, 'No reading', false);
    $('tiSub').textContent = (blocker || (e.reason === 'slow-camera'
      ? 'The camera is too slow to time blinks, usually from low light' : 'The eyes are not in view')) + '.';
  } else if (e.state === 'collecting') {
    value(el, 'Watching', false);
    $('tiSub').textContent = 'Needs 30 s of seeing your eyes before judging. ' + Math.ceil(e.secondsLeft) + ' s to go.'
      + (e.blinks ? ' Blinks so far: ' + e.blinks + '.' : '');
  } else {
    const v = tiredness({ perclos: e.perclos, longClosures: e.longClosures, yawns: y });
    value(el, v.level === 'none' ? 'No signs' : v.level === 'some' ? 'Some signs' : 'Strong signs', true);
    $('tiSub').textContent = v.signs.length
      ? 'In the last minute: ' + v.signs.map(s => s.text).join(', ') + '.'
      : 'Eyes open, blinks short, no yawning. Nothing here points to drowsiness.';
  }
  const ready = !blocker && e.state === 'ready';
  set('tiBlink', ready ? Math.round(e.blinksPerMin) + ' a minute' : '–');
  set('tiPerclos', ready ? Math.round(e.perclos * 100) + '% of the time' : '–');
  set('tiLong', ready ? String(e.longClosures) : '–');
}

function showHead(a) {
  const el = $('hdVal'), dash = '–';
  if (!a) {
    value(el, 'No reading', false);
    for (const id of ['hdYaw', 'hdPitch', 'hdRoll']) $(id).textContent = dash;
    return;
  }
  const side = (v, pos, neg) => Math.abs(v) < 1.5 ? 'level' : Math.round(Math.abs(v)) + '° ' + (v > 0 ? pos : neg);
  const big = Math.abs(a.yaw) >= Math.abs(a.pitch) ? ['yaw', a.yaw] : ['pitch', a.pitch];
  value(el, Math.abs(big[1]) < 10 ? 'Facing camera'
    : big[0] === 'yaw' ? 'Turned ' + (a.yaw > 0 ? 'left' : 'right') : 'Looking ' + (a.pitch > 0 ? 'up' : 'down'), true);
  $('hdYaw').textContent = side(a.yaw, 'to your left', 'to your right').replace('level', 'straight');
  $('hdPitch').textContent = side(a.pitch, 'up', 'down');
  $('hdRoll').textContent = side(a.roll, 'toward your right', 'toward your left').replace('level', 'upright');
}

function showOff() {
  for (const id of ['hrVal', 'exVal', 'tiVal', 'hdVal']) value($(id), 'No reading', false);
  for (const id of ['hrSub', 'exSub', 'tiSub']) $(id).textContent = 'Camera is off.';
  for (const id of ['hdYaw', 'hdPitch', 'hdRoll', 'tiBlink', 'tiPerclos', 'tiLong', 'tiYawn']) $(id).textContent = '–';
  for (const bar of document.querySelectorAll('.bar i')) bar.style.width = '0';
  for (const b of $('hrMeter').children) b.classList.remove('on');
  $('checks').innerHTML = '';
  $('checksNote').textContent = 'Starts when the camera does';
  drawWave(null, false);
}

function showDebug(p) {
  const h = pulse.hist.slice(-6).map(e => e.bpm.toFixed(0) + '@' + e.clearDb.toFixed(1) + (e.ok ? '' : '!' + e.why)).join('  ');
  $('debug').style.display = 'block';
  $('debug').textContent = JSON.stringify(dbg) + '\npulse ' + p.state + (p.confirmedBy ? ' by ' + p.confirmedBy : '')
    + ' | estimates (bpm@dB): ' + h + '\neyes open/shut level ' + eyes.open.toFixed(2) + '/' + eyes.shut.toFixed(2)
    + ' | expression rest ' + JSON.stringify(expr.rest, (k, v) => typeof v === 'number' ? +v.toFixed(2) : v);
}

/* ---------- wiring ---------- */

$('start').addEventListener('click', start);
$('stop').addEventListener('click', stop);
// If the camera stops delivering pictures, say so rather than leaving stale readouts up.
setInterval(() => {
  if (running && performance.now() - lastFrameWall > 3000 && !document.hidden) {
    status('No video', false);
    showOff();
    for (const id of ['hrSub', 'exSub', 'tiSub']) $(id).textContent = 'The camera has stopped sending pictures.';
  }
}, 1000);
showOff();
