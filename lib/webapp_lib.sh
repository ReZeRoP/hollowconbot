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
: "${WEB_DOMAIN:=}"

# Ensure the log file exists so redirects don't fail on a missing path.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# SSL helpers
# ---------------------------------------------------------------------------

# Return 0 if both cert and key files exist and look usable.
webapp_ssl_files_present() {
    [[ -n "${SSL_CERT:-}" && -f "$SSL_CERT" && -r "$SSL_CERT" \
    && -n "${SSL_KEY:-}"  && -f "$SSL_KEY"  && -r "$SSL_KEY" ]]
}

# Validate PEM cert + private key (existence, readability, pair match, expiry).
# On success, optionally copies them into $WEBAPP_DIR/certs/ and rewrites
# SSL_CERT / SSL_KEY to those stable paths (avoids /root permission surprises
# after restarts and keeps gunicorn paths short).
# On failure: prints a clear reason, clears SSL_CERT/SSL_KEY, returns 1.
webapp_validate_and_install_ssl() {
    if [[ -z "${SSL_CERT:-}" && -z "${SSL_KEY:-}" ]]; then
        return 0  # SSL intentionally not configured
    fi

    if [[ -z "${SSL_CERT:-}" || -z "${SSL_KEY:-}" ]]; then
        warn "Both SSL_CERT and SSL_KEY are required for HTTPS. Disabling SSL."
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi

    if [[ ! -f "$SSL_CERT" ]]; then
        warn "SSL certificate not found: $SSL_CERT"
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi
    if [[ ! -r "$SSL_CERT" ]]; then
        warn "SSL certificate not readable: $SSL_CERT (check permissions)"
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi
    if [[ ! -f "$SSL_KEY" ]]; then
        warn "SSL private key not found: $SSL_KEY"
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi
    if [[ ! -r "$SSL_KEY" ]]; then
        warn "SSL private key not readable: $SSL_KEY (check permissions)"
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi

    # Basic PEM sanity
    if ! grep -q "BEGIN .*CERTIFICATE" "$SSL_CERT" 2>/dev/null; then
        warn "SSL certificate does not look like a PEM certificate: $SSL_CERT"
        SSL_CERT=""; SSL_KEY=""
        return 1
    fi
    if ! grep -qE "BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY" "$SSL_KEY" 2>/dev/null; then
        # also accept PKCS#8 "BEGIN PRIVATE KEY"
        if ! grep -q "BEGIN PRIVATE KEY" "$SSL_KEY" 2>/dev/null; then
            warn "SSL key does not look like a PEM private key: $SSL_KEY"
            SSL_CERT=""; SSL_KEY=""
            return 1
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        # Expiry check (warn only if expired)
        local enddate
        enddate=$(openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2- || true)
        if [[ -n "$enddate" ]]; then
            local end_epoch now_epoch
            end_epoch=$(date -d "$enddate" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$enddate" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            if [[ "$end_epoch" -gt 0 && "$now_epoch" -gt "$end_epoch" ]]; then
                warn "SSL certificate is EXPIRED (ended: $enddate). Telegram will reject it."
                SSL_CERT=""; SSL_KEY=""
                return 1
            fi
            log "Certificate valid until: $enddate"
        fi

        # Subject / SAN — warn if domain not covered
        local subject sans
        subject=$(openssl x509 -in "$SSL_CERT" -noout -subject 2>/dev/null || true)
        sans=$(openssl x509 -in "$SSL_CERT" -noout -ext subjectAltName 2>/dev/null || true)
        log "Certificate subject: ${subject:-unknown}"
        if [[ -n "${WEB_DOMAIN:-}" ]]; then
            local domain_ok=0
            if echo "$subject $sans" | grep -qiE "(CN|DNS)[ =:]*(\*\.)?${WEB_DOMAIN//./\\.}"; then
                domain_ok=1
            fi
            # also accept IP in SAN
            if [[ $domain_ok -eq 0 ]] && echo "$sans" | grep -qi "IP Address:${WEB_DOMAIN}"; then
                domain_ok=1
            fi
            if [[ $domain_ok -eq 0 ]]; then
                warn "Domain '${WEB_DOMAIN}' may not match this certificate."
                warn "Telegram Mini Apps require a valid public cert for the exact domain."
                warn "Subject/SAN: ${subject} ${sans}"
            fi
        fi

        # Public-key modulus match between cert and key
        local cert_mod key_mod
        cert_mod=$(openssl x509 -noout -modulus -in "$SSL_CERT" 2>/dev/null | openssl md5 2>/dev/null || true)
        key_mod=$(openssl rsa -noout -modulus -in "$SSL_KEY" 2>/dev/null | openssl md5 2>/dev/null \
            || openssl ec -noout -modulus -in "$SSL_KEY" 2>/dev/null | openssl md5 2>/dev/null \
            || openssl pkey -noout -modulus -in "$SSL_KEY" 2>/dev/null | openssl md5 2>/dev/null \
            || true)
        if [[ -n "$cert_mod" && -n "$key_mod" && "$cert_mod" != "$key_mod" ]]; then
            warn "SSL certificate and private key do NOT match each other."
            warn "  cert: $SSL_CERT"
            warn "  key:  $SSL_KEY"
            SSL_CERT=""; SSL_KEY=""
            return 1
        fi
        if [[ -n "$cert_mod" && -n "$key_mod" ]]; then
            success "Certificate and private key match."
        fi
    else
        warn "openssl not installed — skipping deep certificate validation."
    fi

    # Install a stable copy under the webapp dir so gunicorn always has
    # readable paths even if the original lives under a restricted tree.
    local cert_dir="$WEBAPP_DIR/certs"
    mkdir -p "$cert_dir"
    local installed_cert="$cert_dir/fullchain.pem"
    local installed_key="$cert_dir/privkey.pem"

    # Only re-copy when source differs (avoid clobbering identical files)
    if [[ "$(readlink -f "$SSL_CERT" 2>/dev/null || echo "$SSL_CERT")" != \
          "$(readlink -f "$installed_cert" 2>/dev/null || echo "$installed_cert")" ]]; then
        cp -f "$SSL_CERT" "$installed_cert"
    fi
    if [[ "$(readlink -f "$SSL_KEY" 2>/dev/null || echo "$SSL_KEY")" != \
          "$(readlink -f "$installed_key" 2>/dev/null || echo "$installed_key")" ]]; then
        cp -f "$SSL_KEY" "$installed_key"
    fi
    chmod 600 "$installed_cert" "$installed_key"
    chown root:root "$installed_cert" "$installed_key" 2>/dev/null || true

    SSL_CERT="$installed_cert"
    SSL_KEY="$installed_key"
    success "SSL cert installed at $SSL_CERT"
    return 0
}

# Quick post-start HTTPS probe (does not fail deploy on soft errors).
webapp_probe_https() {
    if ! webapp_ssl_files_present; then
        return 0
    fi
    local path_prefix="${WEB_PATH:-/panel}"
    [[ "${path_prefix:0:1}" != "/" ]] && path_prefix="/${path_prefix}"
    path_prefix="${path_prefix%/}"
    local url="https://127.0.0.1:${WEB_PORT}${path_prefix}/"
    if command -v curl >/dev/null 2>&1; then
        local code
        code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
        if [[ "$code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
            success "Local HTTPS probe OK (HTTP $code) on port ${WEB_PORT}."
        else
            warn "Local HTTPS probe returned HTTP $code for $url"
            warn "Check: journalctl -u ${WEBAPP_SERVICE} -n 50 --no-pager"
            warn "And:   tail -n 50 /var/log/hollowconbot-web-error.log"
        fi
    fi
}

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
    # Use env-expanded cert paths baked at deploy time, but also re-read from
    # .env at runtime so a manual cert swap under webapp/certs/ still works
    # if the operator restarts the unit without re-running configure.
    cat > "$WEBAPP_DIR/start_webapp.sh" << 'STARTEOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
set -a
# shellcheck disable=SC1091
source "${APP_DIR}/.env"
set +a

GUNICORN="${APP_DIR}/.venv/bin/gunicorn"
BIND="0.0.0.0:${WEB_PORT:-8080}"
ACCESS_LOG="/var/log/hollowconbot-web-access.log"
ERROR_LOG="/var/log/hollowconbot-web-error.log"

SSL_ARGS=()
if [[ -n "${SSL_CERT:-}" && -f "${SSL_CERT}" && -n "${SSL_KEY:-}" && -f "${SSL_KEY}" ]]; then
    SSL_ARGS=(--certfile "${SSL_CERT}" --keyfile "${SSL_KEY}")
    echo "[start_webapp] HTTPS enabled with cert=${SSL_CERT}" >> "${ERROR_LOG}"
else
    echo "[start_webapp] HTTP only (no usable SSL_CERT/SSL_KEY)" >> "${ERROR_LOG}"
fi

exec "${GUNICORN}" \
    --workers 2 \
    --bind "${BIND}" \
    --access-logfile "${ACCESS_LOG}" \
    --error-logfile  "${ERROR_LOG}" \
    --capture-output \
    "${SSL_ARGS[@]}" \
    hollowconbot_web.wsgi:application
STARTEOF
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
# Ensure private key is readable if it lives under /root
Environment=HOME=/root

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

    # Validate / install SSL first so .env + start script get the final paths.
    if [[ -n "${SSL_CERT:-}" || -n "${SSL_KEY:-}" ]]; then
        log "Validating SSL certificate and private key..."
        if webapp_validate_and_install_ssl; then
            success "SSL will be enabled for the web panel."
        else
            warn "SSL validation failed — panel will start over plain HTTP."
            warn "Telegram Mini App requires a valid HTTPS certificate for your domain."
        fi
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
        # shellcheck disable=SC1091
        source "$WEBAPP_DIR/.env"
        set +a
        "$WEBAPP_VENV/bin/python" manage.py collectstatic --noinput >> "$LOG_FILE" 2>&1
        "$WEBAPP_VENV/bin/python" manage.py migrate --run-syncdb >> "$LOG_FILE" 2>&1
    )
    success "Static files & schema ready."

    webapp_create_service
    systemctl enable "$WEBAPP_SERVICE" >> "$LOG_FILE" 2>&1
    systemctl restart "$WEBAPP_SERVICE"
    sleep 3

    if systemctl is-active --quiet "$WEBAPP_SERVICE"; then
        success "Web panel is running on port ${WEB_PORT}."
        webapp_probe_https
    else
        warn "Web panel failed to start. Recent logs:"
        journalctl -u "$WEBAPP_SERVICE" -n 40 --no-pager 2>/dev/null || true
        if [[ -f /var/log/hollowconbot-web-error.log ]]; then
            warn "gunicorn error log (last 30 lines):"
            tail -n 30 /var/log/hollowconbot-web-error.log 2>/dev/null || true
        fi
        if webapp_ssl_files_present; then
            warn "SSL was configured — a bad cert/key is a common cause of start failure."
            warn "Test manually: openssl s_server -accept ${WEB_PORT} -cert ${SSL_CERT} -key ${SSL_KEY}"
        fi
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
    if webapp_ssl_files_present; then
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

    # Keep SSL paths in bot .env too (handy for reconfigure defaults).
    if grep -qE '^SSL_CERT=' "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i "s|^SSL_CERT=.*|SSL_CERT=${SSL_CERT}|" "$INSTALL_DIR/.env"
    else
        echo "SSL_CERT=${SSL_CERT}" >> "$INSTALL_DIR/.env"
    fi
    if grep -qE '^SSL_KEY=' "$INSTALL_DIR/.env" 2>/dev/null; then
        sed -i "s|^SSL_KEY=.*|SSL_KEY=${SSL_KEY}|" "$INSTALL_DIR/.env"
    else
        echo "SSL_KEY=${SSL_KEY}" >> "$INSTALL_DIR/.env"
    fi

    if [[ "$proto" == "https" ]]; then
        success "Panel URL saved for the bot: ${panel_url}"
        log "Telegram Mini App will use this HTTPS URL after bot restart."
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
