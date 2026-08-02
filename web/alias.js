// The name a player wears on a leaderboard: two words, drawn from these lists.
//
// A generated alias rather than a text box, because the board's destination is a
// live Twitch overlay and a stranger-typed string reaching one cannot be undone.
// Moderating typed names means a review queue, an approval state, and a way to
// blank the overlay in a hurry -- all before a single row is worth showing. A
// curated wordlist is that same allowlist, applied at the point the name is made
// instead of after, and it needs no queue because there is nothing to review.
//
// So the lists are the safety boundary and the bar for a word is higher than
// "inoffensive on its own": every adjective meets every noun, so a word is only
// in here if all 2,401 pairings read as a place you might drive past. Anything
// with a second meaning, anatomical or crude, is out however innocent the first
// meaning is -- which is why there is no Bush, Crack, Beaver or Hole in the
// nouns, and no Dirty, Hard, Wet or Blue in the adjectives.
//
// Both lists are the road trip: weather, light, distance and pace on one side,
// landscape and roadside on the other.

export const ADJECTIVES = [
  'Amber', 'Ancient', 'Autumn', 'Bright', 'Bronze', 'Calm', 'Cedar', 'Copper',
  'Crimson', 'Distant', 'Drifting', 'Dusty', 'Eastern', 'Emerald', 'Endless',
  'Fading', 'Foggy', 'Frozen', 'Gentle', 'Gilded', 'Golden', 'Granite', 'Hazy',
  'Hidden', 'Humming', 'Idle', 'Lonesome', 'Lucky', 'Marbled', 'Midnight',
  'Northern', 'Open', 'Painted', 'Patient', 'Quiet', 'Rambling', 'Restless',
  'Rolling', 'Rusted', 'Scenic', 'Silent', 'Silver', 'Slanting', 'Southern',
  'Sunlit', 'Twilight', 'Wandering', 'Western', 'Winding',
];

export const NOUNS = [
  'Arroyo', 'Badlands', 'Basin', 'Bluff', 'Boulder', 'Butte', 'Canyon',
  'Cascade', 'Causeway', 'Cedar', 'Compass', 'Coulee', 'Crossing', 'Delta',
  'Diner', 'Dunes', 'Foothill', 'Freeway', 'Glacier', 'Harbour', 'Highway',
  'Junction', 'Lantern', 'Lookout', 'Meadow', 'Mesa', 'Milepost', 'Odometer',
  'Overlook', 'Overpass', 'Pinewood', 'Plateau', 'Prairie', 'Ridgeline',
  'Roadside', 'Sagebrush', 'Sandstone', 'Shoreline', 'Signpost', 'Switchback',
  'Timberline', 'Trailhead', 'Turnout', 'Underpass', 'Valley', 'Viaduct',
  'Wayside', 'Wildflower', 'Windmill',
];

// 49 x 49 = 2,401 aliases. Collisions are cosmetic rather than a correctness
// problem -- `player_id` is what tells two players apart, and the handle is a
// label carried beside it -- but they are common enough at this size to be worth
// knowing about: a day with 50 players has a coin-flip chance of one pair
// sharing a name. A discriminator only needs adding when two of them land on the
// same rendered board, which is five rows.
export const ALIAS_COUNT = ADJECTIVES.length * NOUNS.length;

// `rand` is injectable so the test can pin exact pairs rather than assert on
// whatever Math.random produced.
export function aliasFrom(rand = Math.random) {
  const pick = list => list[Math.floor(rand() * list.length)];
  return `${pick(ADJECTIVES)} ${pick(NOUNS)}`;
}

// Whether a name is one this file could have produced.
//
// The lists are only a safety boundary for what the *page* sends, and the page
// is not what /api/score talks to -- anyone can post a handle straight to it. So
// the endpoint checks membership here before recording one, and a name that
// isn't a pair from these lists is stored as no name at all. Without this the
// wordlist stops being a boundary the moment someone opens a terminal, and the
// board's destination is a live broadcast.
//
// Sets rather than indexOf: it is two lookups per play instead of a scan, built
// once per worker rather than per request.
const ADJECTIVE_SET = new Set(ADJECTIVES);
const NOUN_SET = new Set(NOUNS);

export function isAlias(name) {
  if (typeof name !== 'string') return false;
  // Exactly one space: splitting on every space would let "Lucky Overpass Foo"
  // through on its first two words.
  const parts = name.split(' ');
  return parts.length === 2 && ADJECTIVE_SET.has(parts[0]) && NOUN_SET.has(parts[1]);
}
