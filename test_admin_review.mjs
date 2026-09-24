// Cover /admin/review: the approve half of a day review, and the one thing that
// makes a mark worth anything -- that it stops being true when the day changes.
//
// A stale approval is the failure worth testing for. Every other way this can
// go wrong is visible on the page in front of the reviewer, but a day marked
// reviewed, then rejected out of, reads as looked-at on every surface while one
// of its five is a round nobody has ever seen. That is precisely the state the
// mark exists to rule out, so it is asserted from the reject path rather than
// from this route.
import assert from 'node:assert/strict';

import { d1, post, schema } from './_d1.mjs';
import { onRequestPost } from './functions/admin/review.js';
import { onRequestGet as day, onRequestPost as reject } from './functions/admin/day.js';

const assets = tier => ({
  async fetch() {
    // 'missing' stands for a deployment with no version.json at all, which is
    // the other way this question comes back unanswerable.
    if (tier === 'missing') return new Response('nope', { status: 404 });
    return new Response(JSON.stringify({ label: 'test', tier }));
  },
});

const PAST = '2026-08-01';
const FUTURE = '2099-06-01';
const LATER = '2099-06-02';

function seeded() {
  const answers = d1(schema());
  let n = 0;
  const insert = (image, status, slug) => answers.db
    .prepare(`INSERT INTO rounds
                (image, median_km, mean_cos, batch, status, slug, source_ts_sec,
                 clip_ts_sec, radius_m)
              VALUES (?, ?, 0.07, 'test', ?, ?, 20.5, 20.5, 61.2)`)
    .run(image, ++n, status, slug);
  const seed = date => {
    for (let i = 1; i <= 5; i++) {
      const image = `clips/${date.replaceAll('-', '')}_${i}-0${i}0000.mp4`;
      insert(image, 'scheduled', `20180612_${i}`);
      answers.db
        .prepare('INSERT INTO round_days (date, position, image) VALUES (?, ?, ?)')
        .run(date, i, image);
      answers.db
        .prepare('INSERT INTO answers (image, lat, lng, state, filmed) VALUES (?, ?, ?, ?, ?)')
        .run(image, 41.5 + i, -87.5 - i, 'Indiana', '2018-06-12');
    }
  };
  seed(PAST);
  seed(FUTURE);
  seed(LATER);
  return answers;
}

const url = 'https://stage.guessr.dana.lol/admin/review';
const review = (answers, body, tier = 'staging') => onRequestPost({
  request: Object.assign(post(body), { url }),
  env: { ANSWERS: answers, ASSETS: assets(tier) },
});
const mark = (answers, date) => day({
  request: new Request(`https://stage.guessr.dana.lol/admin/day?date=${date}`),
  env: { ANSWERS: answers, ASSETS: assets('staging') },
}).then(res => res.json()).then(b => b.reviewed_at);

// The same gate as the rest of the directory. This one writes, so a tier this
// code cannot name reaching it would be a write from a deployment nobody can
// vouch for.
{
  const answers = seeded();
  for (const tier of ['broken-tier', 'missing']) {
    assert.equal((await review(answers, { date: FUTURE, reviewed: true }, tier)).status, 403,
      `a ${tier} deployment recorded a review`);
  }
  assert.equal(await mark(answers, FUTURE), null, 'a refused review was still written');
}

{
  const answers = seeded();

  // A day starts unreviewed, and stays that way for every day scheduled before
  // this route existed -- which is the same answer, on purpose.
  assert.equal(await mark(answers, FUTURE), null);

  const first = await review(answers, { date: FUTURE, reviewed: true });
  assert.equal(first.status, 200);
  const { reviewed_at } = await first.json();
  assert.ok(reviewed_at, 'a review recorded no timestamp');
  assert.equal(await mark(answers, FUTURE), reviewed_at,
    'the day preview does not show the review that was just written');

  // Marking twice is not an error and not a second row: the page offers the
  // button again after a reload, and a double-press must not 500.
  assert.equal((await review(answers, { date: FUTURE, reviewed: true })).status, 200);
  assert.equal(
    answers.db.prepare('SELECT COUNT(*) AS n FROM day_reviews').get().n, 1,
    'a re-review wrote a second row');

  // And it comes off again. Un-reviewing is the same button, so a reviewer who
  // marked the wrong day is one press from correcting it.
  assert.equal((await review(answers, { date: FUTURE, reviewed: false })).status, 200);
  assert.equal(await mark(answers, FUTURE), null, 'an un-review left the mark in place');
}

// A date nothing plays, and bodies that do not say what they mean. Without the
// schedule check a typo'd date is recorded as reviewed and counts toward a
// horizon nobody looked at.
{
  const answers = seeded();
  assert.equal((await review(answers, { date: '2099-12-25', reviewed: true })).status, 404);
  for (const body of [
    undefined, null, {}, { date: FUTURE }, { date: FUTURE, reviewed: 'yes' },
    { date: 'tomorrow', reviewed: true }, { reviewed: true },
  ]) {
    assert.equal((await review(answers, body)).status, 400,
      `a malformed review body was accepted: ${JSON.stringify(body)}`);
  }
}

// An opened date. Its schedule is frozen, so a review of it could not have
// withheld anything -- marking one would be approval of something nobody could
// have stopped.
{
  const answers = seeded();
  assert.equal((await review(answers, { date: PAST, reviewed: true })).status, 409);
  assert.equal(await mark(answers, PAST), null);
}

// THE ONE THAT MATTERS. A reject swaps in a round nobody has seen, so the
// review of that day has to go with it -- otherwise the day reads as reviewed
// while one of its five is unreviewed by construction, which is the exact state
// the mark exists to rule out.
{
  const answers = seeded();
  await review(answers, { date: FUTURE, reviewed: true });
  assert.ok(await mark(answers, FUTURE));

  const image = answers.db
    .prepare('SELECT image FROM round_days WHERE date = ? AND position = 3').get(FUTURE).image;
  const out = await reject({
    request: Object.assign(post({ date: FUTURE, image }),
      { url: 'https://stage.guessr.dana.lol/admin/day' }),
    env: { ANSWERS: answers, ASSETS: assets('staging') },
  });
  assert.equal(out.status, 200);
  const { unscheduled_day } = await out.json();
  assert.equal(unscheduled_day, LATER,
    'the fixture stopped paying for a reject out of the tail, so this proves less than it reads');

  assert.equal(await mark(answers, FUTURE), null,
    'a rejected-from day still reads as reviewed');
}

// The day given up to pay for that replacement is unscheduled entirely, so its
// review describes nothing at all. Left behind, it would come back the moment
// a regeneration scheduled that date again -- as an approval of five rounds
// nobody had seen.
{
  const answers = seeded();
  await review(answers, { date: LATER, reviewed: true });
  const image = answers.db
    .prepare('SELECT image FROM round_days WHERE date = ? AND position = 1').get(FUTURE).image;
  await reject({
    request: Object.assign(post({ date: FUTURE, image }),
      { url: 'https://stage.guessr.dana.lol/admin/day' }),
    env: { ANSWERS: answers, ASSETS: assets('staging') },
  });
  assert.equal(
    answers.db.prepare('SELECT COUNT(*) AS n FROM day_reviews WHERE date = ?').get(LATER).n, 0,
    'the unscheduled day kept its review');
}

console.log('ok: a review is recorded, repeatable, reversible and gated by tier');
console.log('ok: only a scheduled day that has not opened can be reviewed');
console.log('ok: rejecting out of a reviewed day takes the review with it');
