"""The `get_clip` seam over a Cloudflare R2 binding, for the Python Worker.

The call is the one functions/clips/[[path]].js makes: the request's headers go
to `get` whole, as both `range` and `onlyIf`, because R2 parses Range and the
conditionals itself. R2 reads them only from a real JS `Headers` -- a plain
object in that slot is taken as an `R2Range` and quietly ignored -- so the
request's dict is rebuilt as one before the call.

Attributes are read with a default because what R2 leaves off is the signal: a
conditional that matched returns the object with no `body`, and a whole-object
read may carry no `range`.

ponytail: the SDK's attribute conversion is modeled by a stand-in, not run; the
first staging deploy's /clips smoke is what proves it.
"""

from server.clips import Clip, Range


def js_headers(items):
    """A JS `Headers` from (name, value) pairs; importable only under Pyodide."""
    from js import Headers

    return Headers.new(items)


class R2:
    def __init__(self, binding, new_headers=js_headers):
        self.binding = binding
        self.new_headers = new_headers

    async def get_clip(self, key: str, headers: dict) -> Clip | None:
        wanted = self.new_headers(list(headers.items()))
        found = await self.binding.get(key, {"range": wanted, "onlyIf": wanted})
        if found is None:
            return None

        stored = self.new_headers([])
        found.writeHttpMetadata(stored)
        r = getattr(found, "range", None)
        return Clip(
            size=found.size,
            etag=found.httpEtag,
            body=getattr(found, "body", None),
            range=Range(r.get("offset"), r.get("length"), r.get("suffix"))
            if r
            else None,
            metadata=dict(stored),
        )
