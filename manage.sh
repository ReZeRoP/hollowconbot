#!/usr/bin/env bash
# =============================================================================
#  BananaBot — اسکریپت مدیریت ربات
#  GitHub: https://github.com/mazyarzohdi/BananaBot
# =============================================================================

set -euo pipefail

# ── تنظیمات ─────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/BananaBot"
SERVICE_NAME="bananabot"
ENV_FILE="$INSTALL_DIR/.env"

# ── رنگ‌ها ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── توابع کمکی ──────────────────────────────────────────────────────────────
log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success(){ echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "این اسکریپت باید با دسترسی root اجرا شود."
        echo "    sudo bash manage.sh"
        exit 1
    fi
}

check_installed() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "BananaBot نصب نشده است. ابتدا install.sh را اجرا کنید."
        exit 1
    fi
}

get_env_value() {
    local key="$1"
    grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- || echo ""
}

set_env_value() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

bot_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  وضعیت: ${GREEN}● در حال اجرا${NC}"
    else
        echo -e "  وضعیت: ${RED}● متوقف${NC}"
    fi
}

print_header() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║       BananaBot — پنل مدیریت ربات       ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    bot_status
    echo ""
}

# ── منوی اصلی ───────────────────────────────────────────────────────────────
main_menu() {
    print_header
    echo -e "  ${BOLD}━━━ کنترل ربات ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "   [1] ▶  روشن کردن ربات"
    echo "   [2] ■  خاموش کردن ربات"
    echo "   [3] ↺  ریستارت ربات"
    echo "   [4] 📜 مشاهده لاگ زنده"
    echo "   [5] 📋 مشاهده آخرین 50 خط لاگ"
    echo ""
    echo -e "  ${BOLD}━━━ تنظیمات ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "   [6] 🔑 تغییر توکن ربات"
    echo "   [7] 👤 تغییر آیدی عددی ادمین"
    echo "   [8] 💳 تغییر شماره کارت"
    echo "   [9] 📢 تغییر کانال اجباری"
    echo "   [10] ⚙️  مشاهده تنظیمات فعلی"
    echo ""
    echo -e "  ${BOLD}━━━ عملیات پیشرفته ━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "   [11] 🔄 به‌روزرسانی ربات از GitHub"
    echo "   [12] 🗑️  حذف کامل ربات"
    echo ""
    echo "   [0] 🚪 خروج"
    echo ""
    echo -e "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -n "  انتخاب کنید: "
}

# ── روشن کردن ───────────────────────────────────────────────────────────────
action_start() {
    log "شروع ربات..."
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "ربات از قبل در حال اجراست."
    else
        systemctl start "$SERVICE_NAME"
        sleep 1
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            success "ربات با موفقیت روشن شد. ✅"
        else
            error "ربات روشن نشد! لاگ را بررسی کنید."
        fi
    fi
}

# ── خاموش کردن ──────────────────────────────────────────────────────────────
action_stop() {
    log "توقف ربات..."
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        warn "ربات از قبل متوقف است."
    else
        systemctl stop "$SERVICE_NAME"
        success "ربات متوقف شد. ■"
    fi
}

# ── ریستارت ─────────────────────────────────────────────────────────────────
action_restart() {
    log "ریستارت ربات..."
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "ربات ریستارت شد. ↺"
    else
        error "ربات پس از ریستارت اجرا نشد!"
    fi
}

# ── لاگ زنده ────────────────────────────────────────────────────────────────
action_live_log() {
    echo -e "${YELLOW}برای خروج از لاگ، Ctrl+C را فشار دهید.${NC}"
    echo ""
    journalctl -u "$SERVICE_NAME" -f --no-pager
}

# ── آخرین لاگ ───────────────────────────────────────────────────────────────
action_last_logs() {
    echo ""
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    echo ""
    read -rp "برای بازگشت Enter بزنید..."
}

# ── تغییر توکن ──────────────────────────────────────────────────────────────
action_change_token() {
    echo ""
    echo -e "${CYAN}توکن فعلی:${NC} $(get_env_value 'BOT_TOKEN')"
    echo ""
    echo -e "${CYAN}توکن جدید را وارد کنید (از @BotFather):${NC}"
    read -rp "  BOT_TOKEN: " NEW_TOKEN
    NEW_TOKEN="${NEW_TOKEN// /}"
    if [[ -z "$NEW_TOKEN" || "$NEW_TOKEN" == "your_bot_token_here" ]]; then
        warn "توکن معتبر نیست. تغییری اعمال نشد."
        return
    fi
    set_env_value "BOT_TOKEN" "$NEW_TOKEN"
    success "توکن ذخیره شد."
    echo -n "  آیا ربات ریستارت شود؟ [y/N]: "
    read -r RESTART_CHOICE
    if [[ "$RESTART_CHOICE" =~ ^[yY]$ ]]; then
        action_restart
    fi
}

# ── تغییر ادمین ─────────────────────────────────────────────────────────────
action_change_admin() {
    echo ""
    echo -e "${CYAN}آیدی‌های ادمین فعلی:${NC} $(get_env_value 'ADMIN_IDS')"
    echo ""
    echo -e "${CYAN}آیدی(های) جدید را وارد کنید (با کاما جدا کنید):${NC}"
    echo -e "${YELLOW}مثال: 123456789 یا 123456789,987654321${NC}"
    read -rp "  ADMIN_IDS: " NEW_ADMIN
    NEW_ADMIN="${NEW_ADMIN// /}"
    if [[ ! "$NEW_ADMIN" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        warn "فرمت اشتباه است. فقط اعداد و کاما مجاز است."
        return
    fi
    set_env_value "ADMIN_IDS" "$NEW_ADMIN"
    success "آیدی ادمین ذخیره شد."
    echo -n "  آیا ربات ریستارت شود؟ [y/N]: "
    read -r RESTART_CHOICE
    if [[ "$RESTART_CHOICE" =~ ^[yY]$ ]]; then
        action_restart
    fi
}

# ── تغییر شماره کارت ────────────────────────────────────────────────────────
action_change_card() {
    echo ""
    echo -e "${CYAN}شماره کارت فعلی:${NC} $(get_env_value 'CARD_NUMBER')"
    echo -e "${CYAN}نام صاحب کارت فعلی:${NC} $(get_env_value 'CARD_HOLDER')"
    echo ""
    echo -e "${CYAN}شماره کارت جدید (Enter برای رد کردن):${NC}"
    read -rp "  CARD_NUMBER: " NEW_CARD
    NEW_CARD="${NEW_CARD// /}"
    if [[ -n "$NEW_CARD" ]]; then
        set_env_value "CARD_NUMBER" "$NEW_CARD"
        echo -e "${CYAN}نام صاحب کارت جدید:${NC}"
        read -rp "  CARD_HOLDER: " NEW_HOLDER
        set_env_value "CARD_HOLDER" "$NEW_HOLDER"
        success "اطلاعات کارت ذخیره شد."
        echo -n "  آیا ربات ریستارت شود؟ [y/N]: "
        read -r RESTART_CHOICE
        if [[ "$RESTART_CHOICE" =~ ^[yY]$ ]]; then
            action_restart
        fi
    else
        warn "تغییری اعمال نشد."
    fi
}

# ── تغییر کانال اجباری ──────────────────────────────────────────────────────
action_change_channel() {
    echo ""
    echo -e "${CYAN}کانال اجباری فعلی:${NC} $(get_env_value 'REQUIRED_CHANNEL')"
    echo ""
    echo -e "${CYAN}آدرس کانال جدید (مثال: @mychannel — برای حذف خالی بگذارید):${NC}"
    read -rp "  REQUIRED_CHANNEL: " NEW_CHANNEL
    NEW_CHANNEL="${NEW_CHANNEL// /}"
    set_env_value "REQUIRED_CHANNEL" "$NEW_CHANNEL"
    if [[ -z "$NEW_CHANNEL" ]]; then
        success "کانال اجباری حذف شد."
    else
        success "کانال اجباری به «$NEW_CHANNEL» تغییر یافت."
    fi
    echo -n "  آیا ربات ریستارت شود؟ [y/N]: "
    read -r RESTART_CHOICE
    if [[ "$RESTART_CHOICE" =~ ^[yY]$ ]]; then
        action_restart
    fi
}

# ── مشاهده تنظیمات ──────────────────────────────────────────────────────────
action_show_config() {
    echo ""
    echo -e "${BOLD}  ═══ تنظیمات فعلی ═══${NC}"
    echo ""
    # نمایش توکن با مخفی‌سازی وسط
    TOKEN=$(get_env_value 'BOT_TOKEN')
    if [[ ${#TOKEN} -gt 10 ]]; then
        MASKED_TOKEN="${TOKEN:0:6}****${TOKEN: -4}"
    else
        MASKED_TOKEN="$TOKEN"
    fi
    echo -e "  BOT_TOKEN:         ${CYAN}$MASKED_TOKEN${NC}"
    echo -e "  ADMIN_IDS:         ${CYAN}$(get_env_value 'ADMIN_IDS')${NC}"
    echo -e "  DATABASE_PATH:     ${CYAN}$(get_env_value 'DATABASE_PATH')${NC}"
    echo -e "  DEFAULT_LANG:      ${CYAN}$(get_env_value 'DEFAULT_LANG')${NC}"
    echo -e "  CARD_NUMBER:       ${CYAN}$(get_env_value 'CARD_NUMBER')${NC}"
    echo -e "  CARD_HOLDER:       ${CYAN}$(get_env_value 'CARD_HOLDER')${NC}"
    echo -e "  REQUIRED_CHANNEL:  ${CYAN}$(get_env_value 'REQUIRED_CHANNEL')${NC}"
    echo ""
    read -rp "  برای بازگشت Enter بزنید..."
}

# ── به‌روزرسانی از GitHub ────────────────────────────────────────────────────
action_update() {
    echo ""
    warn "به‌روزرسانی، فایل .env را تغییر نمی‌دهد."
    echo -n "  آیا مطمئن هستید؟ [y/N]: "
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        return
    fi
    log "دریافت آخرین نسخه از GitHub..."
    # پشتیبان از .env
    cp "$ENV_FILE" "/tmp/.env.bananabot.bak"
    git -C "$INSTALL_DIR" fetch origin >> /dev/null 2>&1
    git -C "$INSTALL_DIR" reset --hard origin/main >> /dev/null 2>&1
    # بازگرداندن .env
    cp "/tmp/.env.bananabot.bak" "$ENV_FILE"
    # به‌روزرسانی کتابخانه‌ها
    log "به‌روزرسانی کتابخانه‌های Python..."
    "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet
    success "به‌روزرسانی انجام شد."
    echo -n "  آیا ربات ریستارت شود؟ [y/N]: "
    read -r RESTART_CHOICE
    if [[ "$RESTART_CHOICE" =~ ^[yY]$ ]]; then
        action_restart
    fi
}

# ── حذف کامل ────────────────────────────────────────────────────────────────
action_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}  ⚠️  هشدار: این عملیات غیرقابل بازگشت است!${NC}"
    echo -e "${RED}  ربات، فایل‌های تنظیمات و پایگاه داده حذف می‌شوند.${NC}"
    echo ""
    echo -n "  برای تأیید، عبارت «حذف» را تایپ کنید: "
    read -r CONFIRM_TEXT
    if [[ "$CONFIRM_TEXT" != "حذف" ]]; then
        warn "عملیات لغو شد."
        return
    fi

    log "متوقف کردن سرویس..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    log "حذف فایل سرویس systemd..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload

    log "حذف فایل‌های پروژه..."
    rm -rf "$INSTALL_DIR"

    success "BananaBot کاملاً حذف شد."
    echo ""
    exit 0
}

# ── حلقه اصلی ───────────────────────────────────────────────────────────────
run() {
    check_root
    check_installed

    while true; do
        main_menu
        read -r CHOICE
        echo ""

        case "$CHOICE" in
            1)  action_start ;;
            2)  action_stop ;;
            3)  action_restart ;;
            4)  action_live_log ;;
            5)  action_last_logs ;;
            6)  action_change_token ;;
            7)  action_change_admin ;;
            8)  action_change_card ;;
            9)  action_change_channel ;;
            10) action_show_config ;;
            11) action_update ;;
            12) action_uninstall ;;
            0)  echo "خداحافظ! 👋"; exit 0 ;;
            *)  warn "انتخاب نامعتبر." ;;
        esac

        if [[ "$CHOICE" != "4" && "$CHOICE" != "5" && "$CHOICE" != "10" ]]; then
            echo ""
            read -rp "  برای بازگشت به منو Enter بزنید..."
        fi
    done
}

run "$@"
