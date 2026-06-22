# Sanaei Panel  Bot
## امکانات

### کاربر
- خرید سرویس با ایجاد خودکار کانفیگ روی پنل
- اکانت تست
- مشاهده سرویس‌ها، لینک کانفیگ، مصرف و بروزرسانی لینک
- کیف پول و افزایش موجودی (کارت به کارت)
- FAQ و آموزش
- پشتیبانی

### ادمین (داخل ربات)
- آمار کلی
- مدیریت پنل‌ها (افزودن، تست اتصال، لیست Inbound)
- مدیریت محصولات
- تأیید/رد پرداخت‌های کارت به کارت
- جستجوی کاربر و تغییر موجودی
- FAQ و ارسال همگانی
- تنظیمات (متن خوش‌آمد، کانال اجباری، اکانت تست، ...)

## پیش‌نیازها

- Python 3.11+
- پنل 3x-ui با API Token (Settings → Security → API Token)

## نصب

```bash
cd sanaei-bot
python -m venv .venv

# Windows
.venv\Scripts\activate

# Linux
source .venv/bin/activate

pip install -r requirements.txt
copy .env.example .env   # Windows
# cp .env.example .env   # Linux
```

فایل `.env` را ویرایش کنید:

```env
BOT_TOKEN=توکن_ربات
ADMIN_IDS=123456789
CARD_NUMBER=6037-xxxx-xxxx-xxxx
CARD_HOLDER=نام صاحب کارت
```

## اجرا

```bash
python main.py
```

## راه‌اندازی اولیه

1. ربات را اجرا کنید و از منوی **پنل مدیریت** وارد شوید.
2. **افزودن پنل**: `/add_panel`
   - آدرس پنل (مثال: `https://panel.example.com`)
   - API Token از پنل
   - IDهای Inbound (مثال: `1` یا `1,2`)
3. **افزودن محصول**: از منوی مدیریت محصولات → افزودن
4. (اختیاری) محصول تست: محصول با `is_trial=1` یا تنظیم `trial_product_id` با `/set trial_product_id 1`

## API پنل 3x-ui

این ربات از API رسمی پنل استفاده می‌کند:

| عملیات | Endpoint |
|--------|----------|
| ایجاد کلاینت | `POST /panel/api/clients/add` |
| دریافت لینک | `GET /panel/api/clients/links/{email}` |
| مصرف | `GET /panel/api/clients/traffic/{email}` |
| وضعیت سرور | `GET /panel/api/server/status` |
| لیست Inbound | `GET /panel/api/inbounds/options` |

احراز هویت: `Authorization: Bearer <API_TOKEN>`

مستندات کامل: در پنل → API Docs یا `/panel/api/openapi.json`

## دستورات ادمین

| دستور | توضیح |
|-------|--------|
| `/add_panel` | افزودن پنل |
| `/user <id>` | اطلاعات کاربر |
| `/addbalance <id> <amount>` | تغییر موجودی |
| `/add_faq` | افزودن FAQ |
| `/del_faq <id>` | حذف FAQ |
| `/set <key> <value>` | تغییر تنظیمات |

## ساختار پروژه

```
sanaei-bot/
├── main.py                 # نقطه ورود
├── config.py               # تنظیمات از .env
├── bot/
│   ├── handlers/           # هندلرهای کاربر و ادمین
│   ├── keyboards.py
│   ├── messages.py
│   └── middlewares.py
├── database/
│   └── db.py               # SQLite
├── services/
│   ├── xui_client.py       # کلاینت API پنل
│   └── subscription.py     # ایجاد/تمدید سرویس
└── utils/
```

## نکات

- برای **On-Hold** (فعال شدن پس از اولین اتصال)، هنگام افزودن پنل فیلد `on_hold` در DB را `1` قرار دهید.
- شماره کارت را در `.env` یا با `/set card_number ...` تنظیم کنید.
- کانال اجباری: `/set channel_required @your_channel`


