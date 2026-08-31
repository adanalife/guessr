`/api/guesses` rows now carry `answer_lat`/`answer_lng` — where the round
actually was — alongside the guess pin, so a drilldown can show the miss rather
than only measure it. Withheld by the same open-date guard the pin and the clip
use: on a date still open the round's location is the answer key itself.
