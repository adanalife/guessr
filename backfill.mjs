// Reconstruct the round set production is *currently* serving, as rows, so the
// switch to the D1 schedule can happen without changing anybody's game.
//
// THE PROBLEM THIS EXISTS FOR. Production still runs the pre-#83 build, where a
// date's five rounds were drawn in the browser by a seeded shuffle over a
// committed manifest. On the D1 schedule they are rows in `round_days` instead,
// and the two disagree: the same date yields five different clips. Up to three
// dates are open at once and there is no instant when none is -- a date runs from
// 10:00 UTC the day before to 12:00 UTC the day after, which is 50 hours against
// a 24-hour cadence -- so there is no deploy time at which nobody is mid-game.
// Cut over without this and every player with a game in progress has its
// remaining rounds swapped underneath them, and can re-score the day under the
// new clips because `plays` is keyed on the image.
//
// So the open dates are seeded with exactly what the old draw would have handed
// out, and the new set begins at the first date that has not opened yet. The
// cutover then lands on a day boundary rather than mid-game.
//
// THE DRAW IS READ OUT OF THE TAG, not reimplemented. `web/daily.js` at v1.0.1
// still has `dailyRounds`, `rampEasyToHard` and the mulberry32 seeding; main
// deleted them when the schedule became data. A second copy written from memory
// would be a second chance to get the shuffle subtly wrong, and the failure mode
// is five plausible clips that are not the five being played.
//
// Verified against ground truth rather than against itself: `--verify` compares
// the reconstruction to the images real players were actually served, which
// `plays` records. Four dates matched 5/5 when this was written.
//
// ONE-SHOT. Nothing needs this once production is on the D1 schedule; it is here
// rather than in a scratch directory because it has to be rehearsed against
// staging before it is run against production with players live, and because it
// is the only written record of what the legacy round set was.
//
//   node backfill.mjs --verify 2026-08-03 2026-08-04   # against recorded plays
//   node backfill.mjs 2026-08-09 2026-08-10            # media to R2, rows to a file
//
// It does not write a database. The SQL lands in backfill.sql and the command to
// push it is printed -- production is not somewhere a script arrives at by
// default, which is the same posture publish.sh takes.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const TAG = 'v1.0.1';
const BUCKET = process.env.BUCKET ?? 'adanalife-guessr-clips';
const PROD_DB = 'adanalife-guessr-answers';

const run = (cmd, args, opts = {}) =>
  execFileSync(cmd, args, { encoding: 'utf8', maxBuffer: 1 << 28, ...opts });

// The tag's copies, on disk so they can be imported and hashed. daily.js at
// v1.0.1 is dependency-free, which is what makes importing it from a temp
// directory work at all.
function legacy() {
  const dir = mkdtempSync(join(tmpdir(), 'guessr-legacy-'));
  for (const f of ['web/daily.js', 'web/rounds.json']) {
    writeFileSync(join(dir, f.replace('web/', '')), run('git', ['show', `${TAG}:${f}`]));
  }
  return dir;
}

// The five a date would have been served, in the order the page showed them.
// rampEasyToHard is applied because the old page applied it -- position in
// round_days is the order the player sees, so dropping the ramp would reproduce
// the right rounds in the wrong order.
async function draws(dir, dates) {
  const { dailyRounds, dayFromDate, rampEasyToHard, ROUNDS_PER_GAME } =
    await import(join(dir, 'daily.js'));
  const pool = JSON.parse(readFileSync(join(dir, 'rounds.json'), 'utf8'));
  return dates.map(date => ({
    date,
    rounds: rampEasyToHard(dailyRounds(pool, dayFromDate(date), ROUNDS_PER_GAME)),
  }));
}

const d1 = (db, sql) => JSON.parse(run('npx', [
  'wrangler', 'd1', 'execute', db, '--remote', '--json', `--command=${sql}`,
]))[0].results;

// Against what players were actually served. The reconstruction can only be
// trusted if something outside it agrees, and `plays` is the one record of the
// old draw that was not produced by this code.
async function verify(dir, dates) {
  let bad = 0;
  for (const { date, rounds } of await draws(dir, dates)) {
    const want = rounds.map(r => r.image).sort();
    const got = d1(PROD_DB,
      `SELECT DISTINCT image FROM plays WHERE date='${date}' ORDER BY image`)
      .map(r => r.image);
    if (!got.length) { console.log(`${date}  no plays recorded, nothing to check against`); continue; }
    const same = want.length === got.length && want.every((w, i) => w === got[i]);
    console.log(`${date}  ${same ? 'MATCH' : 'MISMATCH'} (${got.length} played)`);
    if (!same) { bad++; console.log(`  reconstructed: ${want.join(' ')}\n  served:        ${got.join(' ')}`); }
  }
  if (bad) throw new Error(`${bad} date(s) did not reproduce what was served`);
}

// The media, which production serves as deployed static files today and will
// serve out of R2 the moment the new build lands. At v1.0.1 `clips.sh` pushed
// ONE tarball keyed on a hash of the manifest, so none of these clips exists in
// the bucket as an object -- and a schedule naming clips nobody pushed is a game
// of black panes on a deploy that had nothing to get wrong.
function media(dir, images) {
  const digest = createHash('sha256')
    .update(readFileSync(join(dir, 'rounds.json'))).digest('hex');
  const key = `clips-${digest.slice(0, 16)}.tar`;
  const tar = join(dir, 'clips.tar');

  console.log(`fetching ${key}`);
  run('npx', ['wrangler', 'r2', 'object', 'get', `${BUCKET}/${key}`, '--file', tar, '--remote']);
  run('tar', ['-xf', tar, '-C', dir, ...images]);

  // One object per clip, keyed exactly as the round names it, which is what
  // functions/clips/[[path]].js streams back.
  for (const image of images) {
    run('npx', ['wrangler', 'r2', 'object', 'put', `${BUCKET}/${image}`,
      '--file', join(dir, image), '--content-type', 'video/mp4', '--remote']);
    console.log(`  pushed ${image}`);
  }
}

const q = s => `'${String(s).replaceAll("'", "''")}'`;

// A legacy round played the whole clip from its start, so there is no moment
// within it and no measured radius -- 0 rather than an invented number, and the
// batch says where the row came from. Nothing reads any of the three on the tier
// these rows are for: /api/day projects `image` alone, /api/score reads
// `answers`, and /admin/day refuses to answer on production at all.
const roundRow = r => `INSERT OR IGNORE INTO rounds
  (image, median_km, mean_cos, batch, status, slug, source_ts_sec, clip_ts_sec, radius_m)
  VALUES (${q(r.image)}, ${r.median_km}, ${r.mean_cos}, 'legacy-${TAG}', 'scheduled',
          ${q(r.image.replace(/^clips\//, '').replace(/\.mp4$/, ''))}, 0, 0, 0);`;

async function backfill(dir, dates) {
  const days = await draws(dir, dates);
  const images = days.flatMap(d => d.rounds.map(r => r.image));

  // Every round needs its coordinates or the day looks perfect and answers
  // "unknown round" on every guess. These were seeded by an earlier
  // `answers:prod:push` and are checked rather than assumed.
  const have = new Set(d1(PROD_DB,
    `SELECT image FROM answers WHERE image IN (${images.map(q).join(',')})`).map(r => r.image));
  const missing = images.filter(i => !have.has(i));
  if (missing.length) throw new Error(`no answer row in production for:\n  ${missing.join('\n  ')}`);
  console.log(`ok: all ${images.length} rounds have answers in production`);

  // Media before rows, the same order publish.sh pushes in and for the same
  // reason: a scheduled date whose clips are missing is visible to players, and
  // media nothing points at is visible to nobody.
  media(dir, images);

  const sql = [
    `-- The round set production served before the D1 schedule, reconstructed`,
    `-- from ${TAG} by backfill.mjs so these dates play identically across the`,
    `-- cutover. Re-runnable: every statement ignores a row that is already there.`,
    ...days.flatMap(({ date, rounds }) => [
      ``,
      `-- ${date}`,
      ...rounds.map(roundRow),
      ...rounds.map((r, i) =>
        `INSERT OR IGNORE INTO round_days (date, position, image) VALUES (${q(date)}, ${i + 1}, ${q(r.image)});`),
    ]),
    ``,
  ].join('\n');
  writeFileSync('backfill.sql', sql);

  console.log(`\nwrote backfill.sql -- ${days.length} days, ${images.length} rounds`);
  console.log(`push it with:\n  npx wrangler d1 execute ${PROD_DB} --remote --file backfill.sql --yes`);
}

const args = process.argv.slice(2);
const dates = args.filter(a => /^\d{4}-\d{2}-\d{2}$/.test(a));
if (!dates.length || dates.length !== args.length - (args.includes('--verify') ? 1 : 0)) {
  console.error('usage: node backfill.mjs [--verify] <YYYY-MM-DD>...');
  process.exit(2);
}
const dir = legacy();
await (args.includes('--verify') ? verify(dir, dates) : backfill(dir, dates));
