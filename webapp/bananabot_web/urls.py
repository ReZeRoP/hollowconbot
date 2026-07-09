"""URL configuration for BananaBot Web Panel."""

import os
from django.urls import path, include

WEB_PATH = os.environ.get("WEB_PATH", "/panel").strip("/")

urlpatterns = [
    path(f"{WEB_PATH}/", include("panel.urls")),
    path("", include("panel.urls")),   # fallback for root
]
