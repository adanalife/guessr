"""The App Store Connect API, as far as Game Center needs it: a signed token
and one POST per submission.

A request carries an ES256 JWT over the team's API key. Signing is a seam
(`sign(data) -> raw r||s signature`) because the Worker has WebCrypto and
nothing else, while a test has neither and fakes it. The client never reads
the key itself beyond handing it to `sign`.

Configuration is three Worker secrets -- ASC_KEY_ID, ASC_ISSUER_ID and
ASC_PRIVATE_KEY (the .p8, PEM) -- and `from_env` answers None when any is
missing, which every caller reads as "Game Center is off on this tier".
"""

import base64
import json
import time

API = "https://api.appstoreconnect.apple.com/v1"
# Apple caps a token's life at twenty minutes; one per request is well inside.
TOKEN_LIFE = 600


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class AppStoreConnect:
    def __init__(self, key_id: str, issuer_id: str, private_key: str, sign):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.sign = sign

    async def token(self, now: float | None = None) -> str:
        iat = int(now if now is not None else time.time())
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        claims = {
            "iss": self.issuer_id,
            "iat": iat,
            "exp": iat + TOKEN_LIFE,
            "aud": "appstoreconnect-v1",
        }
        signing_input = ".".join(
            _b64url(json.dumps(part, separators=(",", ":")).encode())
            for part in (header, claims)
        )
        signature = await self.sign(self.private_key, signing_input.encode())
        return f"{signing_input}.{_b64url(signature)}"

    async def submit(self, fetch, resource: str, attributes: dict) -> int:
        """POSTs one JSON:API resource and returns the status; 201 is accepted."""
        body = json.dumps({"data": {"type": resource, "attributes": attributes}})
        status, _ = await fetch(
            f"{API}/{resource}",
            {
                "Authorization": f"Bearer {await self.token()}",
                "Content-Type": "application/json",
            },
            method="POST",
            body=body,
        )
        return status


def from_env(env, sign) -> AppStoreConnect | None:
    """The client the Worker's secrets describe, or None when any is unset."""
    values = [
        str(getattr(env, name, None) or "").strip()
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")
    ]
    if not all(values):
        return None
    return AppStoreConnect(*values, sign)
