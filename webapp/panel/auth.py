"""Telegram Login Widget authentication helpers."""

import hashlib
import hmac
import time
from functools import wraps
from django.conf import settings
from django.shortcuts import redirect
from django.http import HttpRequest


def verify_telegram_auth(data: dict) -> bool:
    """Verify data received from Telegram Login Widget."""
    token = settings.BOT_TOKEN
    if not token:
        return False

    check_hash = data.pop("hash", "")
    data_check_string = "\n".join(
        f"{k}={v}" for k, v in sorted(data.items())
    )
    secret_key = hashlib.sha256(token.encode()).digest()
    computed = hmac.new(secret_key, data_check_string.encode(), hashlib.sha256).hexdigest()

    if computed != check_hash:
        return False

    # Auth must not be older than 24 hours
    auth_date = int(data.get("auth_date", 0))
    if time.time() - auth_date > 86400:
        return False

    return True


def login_required(view_func):
    @wraps(view_func)
    def wrapper(request: HttpRequest, *args, **kwargs):
        if not request.session.get("tg_user"):
            return redirect("panel:login")
        return view_func(request, *args, **kwargs)
    return wrapper


def admin_required(view_func):
    @wraps(view_func)
    def wrapper(request: HttpRequest, *args, **kwargs):
        tg_user = request.session.get("tg_user")
        if not tg_user:
            return redirect("panel:login")
        if int(tg_user["id"]) not in settings.ADMIN_TELEGRAM_IDS:
            return redirect("panel:dashboard")
        return view_func(request, *args, **kwargs)
    return wrapper


def get_current_user(request: HttpRequest) -> dict | None:
    return request.session.get("tg_user")


def is_admin(request: HttpRequest) -> bool:
    user = get_current_user(request)
    if not user:
        return False
    return int(user["id"]) in settings.ADMIN_TELEGRAM_IDS
