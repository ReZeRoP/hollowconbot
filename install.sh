#!/usr/bin/env bash
# =============================================================================
#  BananaBot — اسکریپت نصب و پیکربندی خودکار
#  GitHub: https://github.com/mazyarzohdi/BananaBot
# =============================================================================

set -euo pipefail

# ── رنگ‌ها ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── متغیرها ─────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/mazyarzohdi/BananaBot"
INSTALL_DIR="/opt/BananaBot"
SERVICE_NAME="bananabot"
PYTHON_MIN="3.11"
VENV_DIR="$INSTALL_DIR/.venv"
LOG_FILE="/var/log/bananabot-install.log"

# ── توابع کمکی ──────────────────────────────────────────────────────────────
log()    { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
success(){ echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

print_banner() {
cat << 'EOF'

  ██████╗  █████╗ ███╗   ██╗ █████╗ ███╗   ██╗ █████╗ ██████╗  ██████╗ ████████╗
  ██╔══██╗██╔══██╗████╗  ██║██╔══██╗████╗  ██║██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝
  ██████╔╝███████║██╔██╗ ██║███████║██╔██╗ ██║███████║██████╔╝██║   ██║   ██║   
  ██╔══██╗██╔══██║██║╚██╗██║██╔══██║██║╚██╗██║██╔══██║██╔══██╗██║   ██║   ██║   
  ██████╔╝██║  ██║██║ ╚████║██║  ██║██║ ╚████║██║  ██║██████╔╝╚██████╔╝   ██║   
  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═════╝  ╚═════╝    ╚═╝   

  نصب و پیکربندی خودکار — github.com/mazyarzohdi/BananaBot
EOF
echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "این اسکریپت باید با دسترسی root اجرا شود.\nلطفاً با sudo دوباره اجرا کنید: sudo bash install.sh"
    fi
}

check_os() {
    log "بررسی سیستم‌عامل..."
    if ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null; then
        error "فقط Debian/Ubuntu و CentOS/RHEL پشتیبانی می‌شوند."
    fi
    success "سیستم‌عامل شناسایی شد."
}

install_system_deps() {
    log "نصب پیش‌نیازهای سیستم..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv git curl unzip >> "$LOG_FILE" 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y python3 python3-pip git curl unzip >> "$LOG_FILE" 2>&1
    fi
    success "پیش‌نیازهای سیستم نصب شدند."
}

check_python() {
    log "بررسی نسخه Python..."
    if ! command -v python3 &>/dev/null; then
        error "Python3 یافت نشد! لطفاً آن را نصب کنید."
    fi
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PY_OK=$(python3 -c "import sys; print(1 if sys.version_info >= (3,11) else 0)")
    if [[ "$PY_OK" != "1" ]]; then
        error "Python $PYTHON_MIN+ مورد نیاز است. نسخه فعلی: $PY_VER"
    fi
    success "Python $PY_VER شناسایی شد."
}

clone_or_update_repo() {
    log "دریافت کد پروژه..."
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        warn "پوشه $INSTALL_DIR از قبل وجود دارد. به‌روزرسانی..."
        git -C "$INSTALL_DIR" pull --ff-only >> "$LOG_FILE" 2>&1 || warn "به‌روزرسانی git ناموفق بود — از فایل‌های موجود استفاده می‌شود."
    else
        git clone "$REPO_URL" "$INSTALL_DIR" >> "$LOG_FILE" 2>&1
    fi
    success "کد پروژه در $INSTALL_DIR قرار گرفت."
}

create_virtualenv() {
    log "ساخت محیط مجازی Python..."
    python3 -m venv "$VENV_DIR" >> "$LOG_FILE" 2>&1
    "$VENV_DIR/bin/pip" install --upgrade pip --quiet >> "$LOG_FILE" 2>&1
    success "محیط مجازی ساخته شد."
}

install_python_deps() {
    log "نصب کتابخانه‌های Python (این ممکن است چند دقیقه طول بکشد)..."
    "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet >> "$LOG_FILE" 2>&1
    success "کتابخانه‌ها نصب شدند."
}

# ── جمع‌آوری اطلاعات پیکربندی ─────────────────────────────────────────────
collect_config() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════${NC}"
    echo -e "${BOLD}   پیکربندی ربات — لطفاً اطلاعات را وارد کنید${NC}"
    echo -e "${BOLD}════════════════════════════════════════════${NC}"
    echo ""

    # توکن ربات
    while true; do
        echo -e "${CYAN}1) توکن ربات تلگرام (از @BotFather):${NC}"
        read -rp "   BOT_TOKEN: " BOT_TOKEN
        BOT_TOKEN="${BOT_TOKEN// /}"
        if [[ -n "$BOT_TOKEN" && "$BOT_TOKEN" != "your_bot_token_here" ]]; then
            break
        fi
        warn "توکن وارد شده معتبر نیست. دوباره تلاش کنید."
    done

    # آیدی عددی ادمین
    echo ""
    echo -e "${CYAN}2) آیدی عددی ادمین (یک یا چند آیدی با کاما جدا کنید):${NC}"
    echo -e "   ${YELLOW}مثال: 123456789 یا 123456789,987654321${NC}"
    while true; do
        read -rp "   ADMIN_IDS: " ADMIN_IDS
        ADMIN_IDS="${ADMIN_IDS// /}"
        if [[ "$ADMIN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            break
        fi
        warn "فرمت آیدی اشتباه است. فقط اعداد و کاما مجاز است."
    done

    # شماره کارت (اختیاری)
    echo ""
    echo -e "${CYAN}3) شماره کارت برای پرداخت کارت‌به‌کارت (اختیاری — Enter برای رد کردن):${NC}"
    echo -e "   ${YELLOW}مثال: 6037-1234-5678-9012${NC}"
    read -rp "   CARD_NUMBER: " CARD_NUMBER
    CARD_NUMBER="${CARD_NUMBER// /}"

    # نام صاحب کارت
    if [[ -n "$CARD_NUMBER" ]]; then
        echo ""
        echo -e "${CYAN}4) نام صاحب کارت:${NC}"
        read -rp "   CARD_HOLDER: " CARD_HOLDER
    else
        CARD_HOLDER=""
    fi

    # کانال اجباری (اختیاری)
    echo ""
    echo -e "${CYAN}5) کانال اجباری برای خرید سرویس (اختیاری — Enter برای رد کردن):${NC}"
    echo -e "   ${YELLOW}مثال: @mychannel${NC}"
    read -rp "   REQUIRED_CHANNEL: " REQUIRED_CHANNEL
    REQUIRED_CHANNEL="${REQUIRED_CHANNEL// /}"

    # زبان پیش‌فرض
    echo ""
    echo -e "${CYAN}6) زبان پیش‌فرض ربات:${NC}"
    echo "   [1] فارسی (fa) — پیش‌فرض"
    echo "   [2] انگلیسی (en)"
    read -rp "   انتخاب [1/2]: " LANG_CHOICE
    case "$LANG_CHOICE" in
        2) DEFAULT_LANG="en" ;;
        *) DEFAULT_LANG="fa" ;;
    esac

    echo ""
    success "اطلاعات پیکربندی دریافت شد."
}

write_env_file() {
    log "ایجاد فایل .env..."
    cat > "$INSTALL_DIR/.env" <<EOF
# تولید شده توسط install.sh — $(date)
BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
DATABASE_PATH=data/bot.db
DEFAULT_LANG=${DEFAULT_LANG}
CARD_NUMBER=${CARD_NUMBER}
CARD_HOLDER=${CARD_HOLDER}
REQUIRED_CHANNEL=${REQUIRED_CHANNEL}
EOF
    chmod 600 "$INSTALL_DIR/.env"
    success "فایل .env ساخته شد."
}

create_data_dir() {
    mkdir -p "$INSTALL_DIR/data"
    chown -R root:root "$INSTALL_DIR"
    success "پوشه data/ آماده شد."
}

create_systemd_service() {
    log "ایجاد سرویس systemd..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=BananaBot — Telegram Bot
After=network.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/python main.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1
    success "سرویس systemd ایجاد و فعال شد."
}

start_bot() {
    log "راه‌اندازی ربات..."
    systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "ربات با موفقیت راه‌اندازی شد! ✅"
    else
        warn "ربات راه‌اندازی نشد. لاگ را بررسی کنید:"
        echo "    journalctl -u $SERVICE_NAME -n 30 --no-pager"
    fi
}

print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}   نصب با موفقیت انجام شد! 🎉${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  📁 مسیر نصب:      ${CYAN}$INSTALL_DIR${NC}"
    echo -e "  ⚙️  فایل تنظیمات:  ${CYAN}$INSTALL_DIR/.env${NC}"
    echo -e "  📋 لاگ نصب:        ${CYAN}$LOG_FILE${NC}"
    echo ""
    echo -e "  ${BOLD}مدیریت ربات:${NC}"
    echo -e "  🔧 اسکریپت مدیریت:  ${CYAN}sudo bash $INSTALL_DIR/manage.sh${NC}"
    echo ""
    echo -e "  ${BOLD}دستورات سریع:${NC}"
    echo -e "  ▶  شروع:   ${CYAN}systemctl start $SERVICE_NAME${NC}"
    echo -e "  ■  توقف:   ${CYAN}systemctl stop $SERVICE_NAME${NC}"
    echo -e "  ↺  ریستارت: ${CYAN}systemctl restart $SERVICE_NAME${NC}"
    echo -e "  📜 لاگ:    ${CYAN}journalctl -u $SERVICE_NAME -f${NC}"
    echo ""
}

# ── اجرای اصلی ──────────────────────────────────────────────────────────────
main() {
    print_banner
    touch "$LOG_FILE"
    log "شروع نصب — $(date)"

    check_root
    check_os
    install_system_deps
    check_python
    clone_or_update_repo
    create_virtualenv
    install_python_deps
    collect_config
    write_env_file
    create_data_dir
    create_systemd_service
    start_bot
    print_summary
}

main "$@"
