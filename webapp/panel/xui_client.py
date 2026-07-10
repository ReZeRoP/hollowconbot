"""Minimal synchronous 3x-ui (MHSanaei) panel API client, for the Django
web panel process.

The bot already has a full async client (services/xui_client.py, built on
aiohttp) — but that process is a separate aiogram polling loop, and the
panel's venv doesn't include aiohttp. Since the panel only ever needs to
delete a client (when an admin removes a user's active service from the
web UI), this only implements that one endpoint, using the same request
shape as the bot's client so both stay compatible with the same 3x-ui
panel installs.
"""

import json
import urllib.error
import urllib.request


def delete_client(base_url: str, api_token: str, email: str, keep_traffic: bool = False, timeout: float = 15) -> bool:
    """Delete a client from a 3x-ui panel. Returns True on confirmed
    success, False otherwise (network error, auth error, or the panel
    reporting failure) — the caller decides whether that's fatal."""
    if not base_url or not api_token or not email:
        return False

    path = f"/panel/api/clients/del/{email}"
    if keep_traffic:
        path += "?keepTraffic=1"
    url = base_url.rstrip("/") + path

    req = urllib.request.Request(
        url, data=b"{}", method="POST",
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_token}",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8") or "{}")
    except (urllib.error.URLError, TimeoutError, ValueError):
        return False

    if isinstance(body, dict) and body.get("success") is False:
        return False
    return True
