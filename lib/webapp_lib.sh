#!/usr/bin/env bash
# =============================================================================
#  HollowConBot — shared web panel deployment helpers.
#  Sourced by both install.sh and manage.sh so this logic only lives once.
#
#  Callers must have these already set before sourcing/calling:
#    INSTALL_DIR, WEBAPP_DIR, WEBAPP_VENV, WEBAPP_SERVICE, LOG_FILE
#    BOT_TOKEN, ADMIN_IDS, WEB_DOMAIN, WEB_PORT, WEB_PATH, SSL_CERT, SSL_KEY
#  and the log()/success()/warn()/error() helper functions.
# =============================================================================

# Safe defaults so manage.sh (or older installs) never hit unbound-variable
# errors under `set -u` when a caller forgets to export these.
: "${INSTALL_DIR:=/opt/HollowConBot}"
: "${WEBAPP_DIR:=${INSTALL_DIR}/webapp}"
: "${WEBAPP_VENV:=${WEBAPP_DIR}/.venv}"
: "${WEBAPP_SERVICE:=hollowconbot-web}"
: "${LOG_FILE:=/var/log/hollowconbot-web-manage.log}"
: "${WEB_PORT:=8080}"
: "${WEB_PATH:=/panel}"
: "${SSL_CERT:=}"
: "${SSL_KEY:=}"
: "${BOT_TOKEN:=}"
: "${ADMIN_IDS:=}"

# Ensure the log file exists so redirects don't fail on a missing path.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# Write (or rewrite) the webapp's own .env file.
webapp_write_env() {
    local django_secret
    if [[ -f "$WEBAPP_DIR/.env" ]] && grep -q '^DJANGO_SECRET_KEY=' "$WEBAPP_DIR/.env"; then
        # Keep the existing secret key across reconfigurations — rotating it
        # invalidates every logged-in session for no reason.
        django_secret=$(grep '^DJANGO_SECRET_KEY=' "$WEBAPP_DIR/.env" | cut -d'=' -f2-)
    else
        django_secret=$("$WEBAPP_VENV/bin/python" -c "import secrets; print(secrets.token_urlsafe(50))" 2>/dev/null \
            || python3 -c "import secrets; print(secrets.token_urlsafe(50))")
    fi

    cat > "$WEBAPP_DIR/.env" << EOF
DJANGO_SECRET_KEY=${django_secret}
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=${WEB_DOMAIN},localhost,127.0.0.1
WEB_DOMAIN=${WEB_DOMAIN}
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
BOT_DB_PATH=${INSTALL_DIR}/data/bot.db
WEB_PATH=${WEB_PATH}
WEB_PORT=${WEB_PORT}
SSL_CERT=${SSL_CERT}
SSL_KEY=${SSL_KEY}
EOF
    chmod 600 "$WEBAPP_DIR/.env"
}

# Create/refresh the gunicorn start script, wiring in SSL flags if configured.
webapp_write_start_script() {
    cat > "$WEBAPP_DIR/start_webapp.sh" << STARTEOF
#!/usr/bin/env bash
set -a
source "\$(dirname "\$0")/.env"
set +a
exec "\$(dirname "\$0")/.venv/bin/gunicorn" \\
    --workers 2 \\
    --bind "0.0.0.0:\${WEB_PORT:-8080}" \\
    --access-logfile /var/log/hollowconbot-web-access.log \\
    --error-logfile  /var/log/hollowconbot-web-error.log \\
STARTEOF

    if [[ -n "$SSL_CERT" && -f "$SSL_CERT" && -n "$SSL_KEY" && -f "$SSL_KEY" ]]; then
        cat >> "$WEBAPP_DIR/start_webapp.sh" << STARTEOF
    --certfile "${SSL_CERT}" \\
    --keyfile  "${SSL_KEY}" \\
    hollowconbot_web.wsgi:application
STARTEOF
    else
        cat >> "$WEBAPP_DIR/start_webapp.sh" << STARTEOF
    hollowconbot_web.wsgi:application
STARTEOF
    fi
    chmod +x "$WEBAPP_DIR/start_webapp.sh"
}

webapp_create_service() {
    cat > "/etc/systemd/system/${WEBAPP_SERVICE}.service" << EOF
[Unit]
Description=HollowConBot Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=${WEBAPP_DIR}
ExecStart=${WEBAPP_DIR}/start_webapp.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${WEBAPP_SERVICE}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# Full deploy/redeploy: venv, deps, .env, static files, DB schema, service.
# Safe to call repeatedly (e.g. from manage.sh whenever settings change).
webapp_deploy() {
    if [[ ! -d "$WEBAPP_DIR" ]]; then
        error "پوشه webapp/ در $INSTALL_DIR پیدا نشد."
        return 1
    fi

    log "Creating/updating web panel virtual environment..."
    python3 -m venv "$WEBAPP_VENV" >> "$LOG_FILE" 2>&1
    "$WEBAPP_VENV/bin/pip" install --upgrade pip --quiet >> "$LOG_FILE" 2>&1
    "$WEBAPP_VENV/bin/pip" install -r "$WEBAPP_DIR/requirements.txt" --quiet >> "$LOG_FILE" 2>&1
    success "Web panel packages installed."

    webapp_write_env
    webapp_write_start_script

    log "Collecting static files & syncing database schema..."
    (
        cd "$WEBAPP_DIR"
        set -a
        source "$WEBAPP_DIR/.env"
        set +a
        "$WEBAPP_VENV/bin/python" manage.py collectstatic --noinput >> "$LOG_FILE" 2>&1
        "$WEBAPP_VENV/bin/python" manage.py migrate --run-syncdb >> "$LOG_FILE" 2>&1
    )
    success "Static files & schema ready."

    webapp_create_service
    systemctl enable "$WEBAPP_SERVICE" >> "$LOG_FILE" 2>&1
    systemctl restart "$WEBAPP_SERVICE"
    sleep 2

    if systemctl is-active --quiet "$WEBAPP_SERVICE"; then
        success "Web panel is running on port ${WEB_PORT}."
    else
        warn "Web panel failed to start. Check: journalctl -u ${WEBAPP_SERVICE} -n 50"
        return 1
    fi

    webapp_sync_panel_url
}

# Compute the public URL and write it into the bot's own .env as PANEL_URL,
# so the bot can show a Mini App button. Telegram requires HTTPS for that
# button, so over plain HTTP we still save the URL (useful for testing links
# manually) but the bot will skip showing the in-chat button.
webapp_sync_panel_url() {
    local proto="http"
    if [[ -n "${SSL_CERT:-}" && -f "$SSL_CERT" && -n "${SSL_KEY:-}" && -f "$SSL_KEY" ]]; then
        proto="https"
    fi

    # Omit default ports so Telegram / browsers treat the URL as clean HTTPS.
    local hostport="${WEB_DOMAIN}"
    if [[ -n "${WEB_PORT:-}" ]]; then
        if [[ "$proto" == "https" && "$WEB_PORT" != "443" ]] || \
           [[ "$proto" == "http"  && "$WEB_PORT" != "80"  ]]; then
            hostport="${WEB_DOMAIN}:${WEB_PORT}"
        fi
    fi

    local path_prefix="${WEB_PATH:-/panel}"
    [[ "${path_prefix:0:1}" != "/" ]] && path_prefix="/${path_prefix}"
    path_prefix="${path_prefix%/}"
    local panel_url="${proto}://${hostport}${path_prefix}/"

    if grep -qE '^PANEL_URL=' "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i "s|^PANEL_URL=.*|PANEL_URL=${panel_url}|" "$INSTALL_DIR/.env"
    else
        echo "PANEL_URL=${panel_url}" >> "$INSTALL_DIR/.env"
    fi

    if [[ "$proto" == "https" ]]; then
        success "Panel URL saved for the bot: ${panel_url}"
    else
        warn "Panel is set up over plain HTTP (${panel_url})."
        warn "Telegram requires HTTPS for the in-chat Web App button, so it will stay hidden until SSL is configured."
    fi
}

webapp_installed() {
    [[ -f "$WEBAPP_DIR/.env" && -f "/etc/systemd/system/${WEBAPP_SERVICE}.service" ]]
}

webapp_get_env_value() {
    local key="$1"
    grep -E "^${key}=" "$WEBAPP_DIR/.env" 2>/dev/null | cut -d'=' -f2- || echo ""
}
