"""Who is calling /admin: the owner, a moderator of the channel, or nobody.

The caller brings a Twitch user token as `Authorization: Bearer <token>` -- the
one tempomat's device-code login and the console's web login already hold -- and
guessr asks Twitch about it. Nothing is stored here: no principals file, no
session, no secret.

- `/oauth2/validate` says whose token it is and which app minted it.
- Owner is one Twitch user id. A mod is anyone Helix lists as moderating the
  channel, asked on the caller's own token (scope user:read:moderated_channels),
  so guessr never needs the broadcaster's credential to know who the mods are.

Keyed on user ids, never logins: a login can be renamed and, once released,
registered by someone else.

`fetch` is the same outbound seam /api/live takes: an async
`(url, headers=None) -> (status, text)` that raises when no response arrives.
"""

import json
from dataclasses import dataclass

VALIDATE_URL = "https://id.twitch.tv/oauth2/validate"
MODERATED_URL = "https://api.twitch.tv/helix/moderation/channels"
MOD_SCOPE = "user:read:moderated_channels"


@dataclass(frozen=True)
class Admins:
    """Who may administer, handed in by whatever serves the app.

    `client_ids` is the apps whose tokens are accepted (tempomat's, the
    console's). Without it any app Dana ever signed into could replay his
    token here: a token proves who, not where it was meant to be spent."""

    owner_id: str
    channel_id: str
    client_ids: frozenset[str]


@dataclass(frozen=True)
class Caller:
    tier: str  # "owner" or "mod"
    user_id: str
    login: str  # a label for the audit trail, never a key


async def _json(fetch, url: str, headers: dict) -> dict | None:
    try:
        status, text = await fetch(url, headers)
        return json.loads(text) if status == 200 else None
    except Exception:  # noqa: BLE001 -- unreachable Twitch refuses, never admits
        return None


async def caller(authorization: str | None, fetch, admins: Admins) -> Caller | None:
    """The admin behind an Authorization header, or None.

    None covers every failure alike -- no header, a revoked or expired token,
    another app's token, a stranger, Twitch unreachable -- because refusing is
    the one safe answer to all of them. A route maps None to 401.

    ponytail: validates on every call, no cache. Admin requests are a human
    clicking; cache by sha256(token) for the token's remaining life if they
    stop being that."""
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    token = token.strip()

    who = await _json(fetch, VALIDATE_URL, {"Authorization": f"OAuth {token}"})
    if not who or who.get("client_id") not in admins.client_ids:
        return None
    user_id, login = str(who.get("user_id") or ""), str(who.get("login") or "")
    if not user_id:
        return None
    if user_id == admins.owner_id:
        return Caller("owner", user_id, login)

    if MOD_SCOPE not in (who.get("scopes") or []):
        return None
    # ponytail: first page only; a mod of more than a hundred channels pages
    # when one exists.
    mods = await _json(
        fetch,
        f"{MODERATED_URL}?user_id={user_id}&first=100",
        {"Authorization": f"Bearer {token}", "Client-Id": who["client_id"]},
    )
    channels = (mods or {}).get("data") or []
    if any(str(c.get("broadcaster_id")) == admins.channel_id for c in channels):
        return Caller("mod", user_id, login)
    return None
