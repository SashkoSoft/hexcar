// Гексагональная плитка Труше (как на hexcar.jpg):
//  - 1 "уголок": дуга между СОСЕДНИМИ гранями (малый радиус, центр в вершине)  [синяя]
//  - 2 большие пологие дуги между гранями ЧЕРЕЗ ОДНУ, которые пересекаются     [красная/зелёная]
// Все 6 середин рёбер задействованы ровно один раз -> плитки стыкуются.

const s     = 100;                 // длина стороны
const band  = 20;                  // толщина ленты
const ANGLE = 0;                   // угол поворота одиночной плитки (град)
const EXT   = 6;                   // на сколько затирка дороги выходит за грань наружу (px)
const INS   = 5;                   // насколько внутрь от стенок идёт inset-заливка (стирает стенки в развязке)
const a     = s * Math.sqrt(3) / 2; // апофема
const D2R   = Math.PI / 180;
const hw    = band / 2;

// flat-top: вершина k под углом 60k, середина ребра k под углом 60k+30 (+ поворот ang)
const V = (k, cx = 0, cy = 0, ang = ANGLE) => { const t = (60 * k + ang) * D2R; return [cx + s * Math.cos(t), cy + s * Math.sin(t)]; };
const M = (k, cx = 0, cy = 0, ang = ANGLE) => { const t = (60 * k + 30 + ang) * D2R; return [cx + a * Math.cos(t), cy + a * Math.sin(t)]; };
const hexPoints = (cx, cy, ang = ANGLE) => Array.from({ length: 6 }, (_, k) => V(k, cx, cy, ang).map(n => n.toFixed(2)).join(',')).join(' ');

function circumcenter(A, B, C) {
  const d = 2 * (A[0] * (B[1] - C[1]) + B[0] * (C[1] - A[1]) + C[0] * (A[1] - B[1]));
  const a2 = A[0] * A[0] + A[1] * A[1], b2 = B[0] * B[0] + B[1] * B[1], c2 = C[0] * C[0] + C[1] * C[1];
  const ux = (a2 * (B[1] - C[1]) + b2 * (C[1] - A[1]) + c2 * (A[1] - B[1])) / d;
  const uy = (a2 * (C[0] - B[0]) + b2 * (A[0] - C[0]) + c2 * (B[0] - A[0])) / d;
  return [ux, uy];
}

// Лента вдоль дуги окружности через p1 -> via -> p2.
// Возвращает { wallOut, wallIn } — стенки дороги (открытые пути, точно до края)
//           и { erase } — замкнутая заливка, продлённая за края на EXT (вдоль дороги),
//           ширина строго = band, чтобы грань резалась ровно по стенкам.
// C, R — центр и радиус дуги (передаются явно из arcRoad, стабильны);
// via задаёт, через какую сторону вести дугу (apex у центра плитки).
function ribbonArc(C, R, p1, via, p2, N = 26, ext = EXT) {
  const ang = p => Math.atan2(p[1] - C[1], p[0] - C[0]);
  const norm = x => { while (x < 0) x += 2 * Math.PI; while (x >= 2 * Math.PI) x -= 2 * Math.PI; return x; };
  const a1 = ang(p1), a2 = ang(p2), av = ang(via);
  const up = norm(a2 - a1), dv = norm(av - a1);
  const delta = (dv <= up) ? up : up - 2 * Math.PI; // направление, проходящее через via
  const sgn = Math.sign(delta), da = ext / R;

  const f = p => `${p[0].toFixed(2)} ${p[1].toFixed(2)}`;
  const sample = (aStart, aEnd, halfw) => {
    const outer = [], inner = [];
    for (let i = 0; i <= N; i++) {
      const t = aStart + (aEnd - aStart) * (i / N);
      const c = Math.cos(t), sn = Math.sin(t);
      outer.push([C[0] + (R + halfw) * c, C[1] + (R + halfw) * sn]);
      inner.push([C[0] + (R - halfw) * c, C[1] + (R - halfw) * sn]);
    }
    return { outer, inner };
  };
  const poly = pts => 'M ' + pts.map(f).join(' L ');
  const closed = ({ outer, inner }) => poly(outer) + ' L ' + inner.slice().reverse().map(f).join(' L ') + ' Z';

  const a2d = a1 + delta;                                       // конец дуги В НАПРАВЛЕНИИ delta (через via)
  const base = sample(a1, a2d, hw);                            // строго от края до края
  const extd = sample(a1 - sgn * da, a2d + sgn * da, hw);      // с выносом за края наружу
  const inset = sample(a1 - sgn * da, a2d + sgn * da, hw - INS);// узкая заливка (стирает стенки в развязке)
  return { fillBase: closed(base), fillExt: closed(extd), fillInset: closed(inset),
           wallOut: poly(base.outer), wallIn: poly(base.inner) };
}

// Пересечение прямых (P+t*d) и (Q+u*e).
function lineIntersect(P, d, Q, e) {
  const det = d[0] * (-e[1]) - (-e[0]) * d[1];
  const t = ((Q[0] - P[0]) * (-e[1]) - (-e[0]) * (Q[1] - P[1])) / det;
  return [P[0] + t * d[0], P[1] + t * d[1]];
}

// Дорога между серединами граней ei и ej, входящая в ОБЕ грани перпендикулярно:
// центр дуги = пересечение линий этих граней -> бесшовная стыковка при любом повороте.
function arcRoad(ei, ej, cx, cy, ang, ext = EXT) {
  const Mi = M(ei, cx, cy, ang), Mj = M(ej, cx, cy, ang);
  const th = k => (60 * k + 30 + ang) * D2R;                 // направление нормали грани k
  const di = [-Math.sin(th(ei)), Math.cos(th(ei))];          // направление самой грани (вдоль ребра)
  const dj = [-Math.sin(th(ej)), Math.cos(th(ej))];
  const C = lineIntersect(Mi, di, Mj, dj);
  const R = Math.hypot(Mi[0] - C[0], Mi[1] - C[1]);
  const dO = [cx - C[0], cy - C[1]], L = Math.hypot(dO[0], dO[1]);
  const apex = [C[0] + R * dO[0] / L, C[1] + R * dO[1] / L]; // вершина дуги (ближняя к центру плитки)
  return ribbonArc(C, R, Mi, apex, Mj, 26, ext);
}

// Три дороги плитки: уголок (соседние грани) + две длинные (через одну), все перпендикулярны граням.
function tileRibbons(cx, cy, ang = ANGLE, ext = EXT) {
  return [
    arcRoad(0, 1, cx, cy, ang, ext),   // уголок (грани 0 и 1)
    arcRoad(2, 4, cx, cy, ang, ext),   // длинная дуга 2->4 (мимо 3)
    arcRoad(3, 5, cx, cy, ang, ext),   // длинная дуга 3->5 (мимо 4)
  ];
}

function svg(w, h, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w.toFixed(0)}" height="${h.toFixed(0)}" viewBox="0 0 ${w.toFixed(2)} ${h.toFixed(2)}">\n` +
         `  <rect width="${w.toFixed(2)}" height="${h.toFixed(2)}" fill="#ffffff"/>\n${body}</svg>`;
}

// Отрисовка одной плитки в режиме:
//  'fence' — грань целиком + дороги с торцами
//  'roads' — только дороги, без граней
//  'gaps'  — грань с проёмами в местах дорог; дороги без торцов (стенки стыкуются с краем проёма)
// Части одной плитки (для пофазной отрисовки всего поля):
//  fence — грань; fills — белые заливки дорог (продлены за грань, прорезают грань);
//  walls — стенки дорог (открытые, строго до края). Без clipPath.
function tileParts(cx, cy, sw, ang = ANGLE) {
  const ribs = tileRibbons(cx, cy, ang);
  const fence = `  <polygon points="${hexPoints(cx, cy, ang)}" fill="none" stroke="#000" stroke-width="${sw}"/>\n`;
  // каждая дорога целиком (заливка + стенки) — рисуются по очереди, поэтому на пересечении
  // последующая дорога перекрывает предыдущую («переход», одна над другой).
  const roads = ribs.map(r =>
    `  <path d="${r.fillExt}" fill="#fff" stroke="none"/>\n` +
    `  <path d="${r.wallOut}" fill="none" stroke="#000" stroke-width="${sw}" stroke-linecap="butt"/>\n` +
    `  <path d="${r.wallIn}"  fill="none" stroke="#000" stroke-width="${sw}" stroke-linecap="butt"/>\n`);
  return { fence, roads };
}

// ---- одиночная плитка (ang — поворот плитки, град) ----
function singleTile(ang = ANGLE) {
  const pad = band + 6;
  const w = 2 * s + 2 * pad, h = 2 * a + 2 * pad;
  const p = tileParts(w / 2, h / 2, 4, ang);
  return svg(w, h, p.fence + p.roads.join(''));
}

// ПСЧ с сидом (для воспроизводимой раскладки; меняй SEED для другого варианта)
const SEED = 12345;
function makeRng(seed) {
  return () => { seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}

// ---- поле cols x rows: одна и та же плитка hex_tile по сетке ----
// ext=0 -> дороги целиком внутри своего шестиугольника (за грань не вылезают),
// поэтому обрезка не нужна и каждая ячейка идентична. Порядок: ВСЕ грани -> ВСЕ заливки ->
// ВСЕ стенки (стенки последними, чтобы заливки соседей их не затирали).
function field(cols = 5, rows = 5, rand = false) {
  const sw = 3.5;
  const dx = 1.5 * s, dy = 2 * a, pad = band + 8;
  const w = (cols - 1) * dx + 2 * s + 2 * pad;
  const h = (rows - 1) * dy + 3 * a + 2 * pad;
  const x0 = pad + s, y0 = pad + a;
  const rng = makeRng(SEED);
  const cells = [];
  for (let c = 0; c < cols; c++) for (let r = 0; r < rows; r++) {
    const cx = x0 + c * dx, cy = y0 + r * dy + (c % 2 ? a : 0);
    const ang = ANGLE + (rand ? 60 * Math.floor(rng() * 6) : 0);
    cells.push({ hp: hexPoints(cx, cy, ang), ribs: tileRibbons(cx, cy, ang, 0) });
  }
  const fences = cells.map(c => `  <polygon points="${c.hp}" fill="none" stroke="#000" stroke-width="${sw}"/>`).join('\n');
  const fills = cells.map(c => c.ribs.map(r => `  <path d="${r.fillBase}" fill="#fff" stroke="none"/>`).join('\n')).join('\n');
  const walls = cells.map(c => c.ribs.map(r =>
    `  <path d="${r.wallOut}" fill="none" stroke="#000" stroke-width="${sw}"/>` +
    `<path d="${r.wallIn}" fill="none" stroke="#000" stroke-width="${sw}"/>`).join('\n')).join('\n');
  return svg(w, h, `${fences}\n${fills}\n${walls}\n`);
}

const fs = require('fs');
fs.writeFileSync('hex_tile.svg', singleTile(ANGLE));
// 6 повёрнутых версий плитки для штамповки поля со случайным поворотом
for (let k = 0; k < 6; k++) fs.writeFileSync(`hex_tile_a${k}.svg`, singleTile(60 * k));
// индексы поворота (0..5) с сидом — для воспроизводимой раскладки (100 для 10x10)
const rng = makeRng(SEED), idx = [];
for (let i = 0; i < 25; i++) idx.push(Math.floor(rng() * 6));
fs.writeFileSync('rot_idx.txt', idx.join(' '));
console.log('written: hex_tile.svg, hex_tile_a0..a5.svg, rot_idx.txt');
