import fs from "node:fs";
const NEAR = 150,
  DEEP = 1800,
  HOLD = 400;
const file = process.argv[2];
const d = JSON.parse(fs.readFileSync(file, "utf8"));
const F = d.frames.map(([t, st, sh, ch]) => ({
  t,
  st,
  sh,
  ch,
  dist: sh - st - ch,
}));

// mark frames where the content height changed (pagination / reflow) — a
// scrollTop delta across such a frame is not reader-visible motion.
for (let i = 1; i < F.length; i++) {
  F[i].dSt = F[i].st - F[i - 1].st;
  F[i].dSh = F[i].sh - F[i - 1].sh;
  F[i].dCh = F[i].ch - F[i - 1].ch;
  F[i].geomChanged = F[i].dSh !== 0 || F[i].dCh !== 0;
}
// a prepend lands its scrollTop correction on the frame AFTER the height change
for (let i = F.length - 1; i > 0; i--) {
  if (F[i - 1].geomChanged) F[i].geomChanged = true;
}

// boolean flips exactly as _reportDistance computes them
let lastAway = null,
  lastDeep = null;
const flips = [];
for (const f of F) {
  const away = f.dist > NEAR,
    deep = f.dist > DEEP;
  if (lastAway !== null && (away !== lastAway || deep !== lastDeep)) {
    flips.push({
      t: f.t,
      away,
      deep,
      dist: f.dist,
      which: away !== lastAway ? "away" : "deep",
    });
  }
  lastAway = away;
  lastDeep = deep;
}

function windowStats(t0, t1, label) {
  const w = F.filter((f) => f.t >= t0 && f.t < t1 && f.dSt !== undefined);
  const moving = w.filter((f) => !f.geomChanged);
  // gesture is upward => expected sign of dSt is negative
  const rev = moving.filter((f) => f.dSt > 0);
  const stall = moving.filter((f) => f.dSt === 0);
  const mags = rev.map((f) => f.dSt);
  return {
    label,
    t0: +t0.toFixed(1),
    t1: +t1.toFixed(1),
    frames: w.length,
    cleanFrames: moving.length,
    geomChangedFrames: w.length - moving.length,
    reversals: rev.length,
    reversalPct: moving.length
      ? +((100 * rev.length) / moving.length).toFixed(1)
      : null,
    reversalMagMax: mags.length ? Math.max(...mags) : 0,
    reversalMagMean: mags.length
      ? +(mags.reduce((a, b) => a + b, 0) / mags.length).toFixed(1)
      : 0,
    reversalMagSum: mags.reduce((a, b) => a + b, 0),
    grossTravel: moving.reduce((a, f) => a + Math.abs(f.dSt), 0),
    netTravel: moving.reduce((a, f) => a + f.dSt, 0),
    progressRatio: (() => {
      const g = moving.reduce((a, f) => a + Math.abs(f.dSt), 0);
      return g
        ? +(Math.abs(moving.reduce((a, f) => a + f.dSt, 0)) / g).toFixed(3)
        : null;
    })(),
    stallFrames: stall.length,
    stallPct: moving.length
      ? +((100 * stall.length) / moving.length).toFixed(1)
      : null,
    netScrollTop: w.length ? +(w[w.length - 1].st - w[0].st).toFixed(0) : 0,
  };
}

const out = {
  file,
  viewport: d.viewport,
  frames: F.length,
  span: [F[0]?.t.toFixed(0), F.at(-1)?.t.toFixed(0)],
  distRange: [
    Math.min(...F.map((f) => f.dist)),
    Math.max(...F.map((f) => f.dist)),
  ],
  geomChangeFrames: F.filter((f) => f.geomChanged).length,
  flips: flips.map((f) => ({ ...f, t: +f.t.toFixed(1) })),
  windows: [],
};

for (const fl of flips)
  out.windows.push(
    windowStats(
      fl.t,
      fl.t + HOLD,
      `FLIP ${fl.which}->${fl.away}/${fl.deep} @${fl.t.toFixed(0)}ms`,
    ),
  );

// control windows: 400ms spans containing no flip and no flip-window overlap
const banned = flips.flatMap((f) => [[f.t - 50, f.t + HOLD + 50]]);
const free = (a, b) => !banned.some(([x, y]) => a < y && b > x);
let controls = 0;
for (let s = F[0].t; s + HOLD < F.at(-1).t && controls < 3; s += 50) {
  if (free(s, s + HOLD)) {
    const st = windowStats(s, s + HOLD, `CONTROL @${s.toFixed(0)}ms`);
    if (st.cleanFrames >= 15 && Math.abs(st.netScrollTop) > 100) {
      out.windows.push(st);
      controls++;
      s += HOLD;
    }
  }
}
console.log(JSON.stringify(out, null, 2));
