#!/usr/bin/env python3
"""Cover who /admin admits: the owner, a channel moderator, and every way of
being neither. Twitch is stubbed at the fetch seam, answering from a table keyed
on the token so each case reads as the Twitch state it models.
"""

import asyncio
import json

from server.admin_auth import MOD_SCOPE, Admins, Caller, caller

OWNER, CHANNEL = "111", "999"
TEMPOMAT, CONSOLE, STRANGER_APP = "tempomat-app", "console-app", "some-other-app"
ADMINS = Admins(
    owner_id=OWNER, channel_id=CHANNEL, client_ids=frozenset({TEMPOMAT, CONSOLE})
)

# token -> what /oauth2/validate answers (None = 401)
VALIDATE = {
    "owner": {"client_id": TEMPOMAT, "login": "dana", "user_id": OWNER, "scopes": []},
    "owner-console": {
        "client_id": CONSOLE,
        "login": "dana",
        "user_id": OWNER,
        "scopes": [],
    },
    "owner-elsewhere": {
        "client_id": STRANGER_APP,
        "login": "dana",
        "user_id": OWNER,
        "scopes": [],
    },
    "mod": {
        "client_id": TEMPOMAT,
        "login": "friend",
        "user_id": "222",
        "scopes": [MOD_SCOPE],
    },
    "mod-console": {
        "client_id": CONSOLE,
        "login": "friend",
        "user_id": "222",
        "scopes": [MOD_SCOPE],
    },
    # A mod whose Helix lookup is refused, with a body that would admit if read.
    "mod-throttled": {
        "client_id": TEMPOMAT,
        "login": "friend",
        "user_id": "666",
        "scopes": [MOD_SCOPE],
    },
    "mod-no-scope": {
        "client_id": TEMPOMAT,
        "login": "friend",
        "user_id": "222",
        "scopes": [],
    },
    "other-mod": {
        "client_id": TEMPOMAT,
        "login": "elsewhere",
        "user_id": "333",
        "scopes": [MOD_SCOPE],
    },
    # The owner's *login*, on someone else's account: a renamed-and-reregistered
    # handle must not inherit anything.
    "lookalike": {
        "client_id": TEMPOMAT,
        "login": "dana",
        "user_id": "444",
        "scopes": [MOD_SCOPE],
    },
    "expired": None,
}
# user_id -> broadcaster ids Helix says they moderate
MODERATES = {"222": [CHANNEL, "555"], "666": [CHANNEL], "333": ["555"], "444": []}


def twitch(down=False):
    calls = []

    async def fetch(url, headers=None):
        calls.append((url, headers))
        if down:
            raise OSError("unreachable")
        token = headers["Authorization"].split(" ", 1)[1]
        if url.startswith("https://id.twitch.tv/oauth2/validate"):
            assert headers["Authorization"].startswith("OAuth ")
            body = VALIDATE.get(token)
            return (200, json.dumps(body)) if body else (401, "{}")
        assert headers["Client-Id"] == VALIDATE[token]["client_id"], (
            "Helix asked with the wrong app"
        )
        uid = url.split("user_id=")[1].split("&")[0]
        rows = [{"broadcaster_id": b, "broadcaster_login": "x"} for b in MODERATES[uid]]
        return (429 if uid == "666" else 200), json.dumps({"data": rows})

    return fetch, calls


async def who(header, down=False):
    fetch, calls = twitch(down)
    return await caller(header, fetch, ADMINS), calls


async def test_admin_auth() -> None:
    got, calls = await who("Bearer owner")
    assert got == Caller("owner", OWNER, "dana")
    assert len(calls) == 1, "the owner needs no moderator lookup"
    assert (await who("bearer owner-console"))[0].tier == "owner", (
        "the scheme is case-insensitive"
    )
    assert (await who("Bearer mod"))[0] == Caller("mod", "222", "friend")
    assert (await who("Bearer mod-console"))[0].tier == "mod", (
        "Helix asked with the token's own app"
    )

    for header, why in [
        (None, "no header"),
        ("", "empty header"),
        ("Bearer ", "no token"),
        ("Basic owner", "not a bearer"),
        ("owner", "no scheme"),
        ("Bearer expired", "Twitch refuses the token"),
        ("Bearer owner-elsewhere", "the owner's token minted for another app"),
        ("Bearer mod-no-scope", "a mod whose token cannot ask"),
        ("Bearer other-mod", "a mod of some other channel"),
        ("Bearer mod-throttled", "a refused lookup read as an answer"),
        ("Bearer lookalike", "the owner's login on another account"),
    ]:
        assert (await who(header))[0] is None, why

    got, calls = await who("Bearer owner", down=True)
    assert got is None and calls, "unreachable Twitch admitted someone"


asyncio.run(test_admin_auth())
print(
    "ok: /admin admits the owner and the channel's mods, by user id, from allowed apps only"
)
