import asyncio
import json
import logging

import aiosqlite
from pathlib import Path

from config import get_settings
from db_schema import DEFAULT_SETTINGS, reconcile  # noqa: F401 (DEFAULT_SETTINGS kept for anything importing it from here)

logger = logging.getLogger(__name__)


class Database:
    def __init__(self, path: str | None = None):
        settings = get_settings()
        self.path = path or settings.database_path
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)

    async def connect(self) -> aiosqlite.Connection:
        conn = await aiosqlite.connect(self.path)
        conn.row_factory = aiosqlite.Row
        await conn.execute("PRAGMA foreign_keys = ON")
        return conn

    async def init(self):
        # reconcile() is plain sync sqlite3 (see db_schema.py for why), so
        # it's run in a worker thread to avoid blocking the event loop.
        # It creates any missing tables/columns — including ones added in
        # a newer version of the code than whatever data/bot.db currently
        # has (e.g. right after restoring an older backup) — so the bot
        # never crashes on a stale schema.
        report = await asyncio.to_thread(reconcile, self.path)
        if report["tables_created"] or report["columns_added"]:
            logger.info(
                "Database schema updated — tables created: %s, columns added: %s",
                report["tables_created"], report["columns_added"],
            )

    async def _fetchone(self, query: str, params: tuple = ()) -> dict | None:
        conn = await self.connect()
        try:
            cursor = await conn.execute(query, params)
            row = await cursor.fetchone()
            return dict(row) if row else None
        finally:
            await conn.close()

    async def _fetchall(self, query: str, params: tuple = ()) -> list[dict]:
        conn = await self.connect()
        try:
            cursor = await conn.execute(query, params)
            rows = await cursor.fetchall()
            return [dict(r) for r in rows]
        finally:
            await conn.close()

    async def _execute(self, query: str, params: tuple = ()) -> int:
        conn = await self.connect()
        try:
            cursor = await conn.execute(query, params)
            await conn.commit()
            return cursor.lastrowid or 0
        finally:
            await conn.close()

    # --- Users ---
    async def get_or_create_user(
        self, telegram_id: int, username: str | None, full_name: str | None
    ) -> dict:
        user = await self._fetchone(
            "SELECT * FROM users WHERE telegram_id = ?", (telegram_id,)
        )
        if user:
            if username and user["username"] != username:
                await self._execute(
                    "UPDATE users SET username = ? WHERE id = ?",
                    (username, user["id"]),
                )
                user["username"] = username
            return user
        uid = await self._execute(
            "INSERT INTO users (telegram_id, username, full_name) VALUES (?, ?, ?)",
            (telegram_id, username or "", full_name or ""),
        )
        return await self._fetchone("SELECT * FROM users WHERE id = ?", (uid,))

    async def get_user_by_telegram_id(self, telegram_id: int) -> dict | None:
        return await self._fetchone(
            "SELECT * FROM users WHERE telegram_id = ?", (telegram_id,)
        )

    async def update_user_balance(self, user_id: int, amount: int) -> int:
        await self._execute(
            "UPDATE users SET balance = balance + ? WHERE id = ?",
            (amount, user_id),
        )
        user = await self._fetchone("SELECT balance FROM users WHERE id = ?", (user_id,))
        return user["balance"] if user else 0

    async def set_user_banned(self, user_id: int, banned: bool):
        await self._execute(
            "UPDATE users SET is_banned = ? WHERE id = ?",
            (1 if banned else 0, user_id),
        )

    async def set_user_phone(self, user_id: int, phone: str):
        await self._execute(
            "UPDATE users SET phone = ? WHERE id = ?", (phone, user_id)
        )

    async def get_all_users_count(self, search: str = "") -> int:
        if search:
            row = await self._fetchone(
                "SELECT COUNT(*) as c FROM users WHERE "
                "CAST(telegram_id AS TEXT) LIKE ? OR username LIKE ? OR full_name LIKE ?",
                (f"%{search}%", f"%{search}%", f"%{search}%"),
            )
        else:
            row = await self._fetchone("SELECT COUNT(*) as c FROM users")
        return row["c"] if row else 0

    async def get_users_page(self, page: int, per_page: int = 10, search: str = "") -> list[dict]:
        offset = (page - 1) * per_page
        if search:
            return await self._fetchall(
                "SELECT * FROM users WHERE "
                "CAST(telegram_id AS TEXT) LIKE ? OR username LIKE ? OR full_name LIKE ? "
                "ORDER BY id DESC LIMIT ? OFFSET ?",
                (f"%{search}%", f"%{search}%", f"%{search}%", per_page, offset),
            )
        return await self._fetchall(
            "SELECT * FROM users ORDER BY id DESC LIMIT ? OFFSET ?",
            (per_page, offset),
        )

    # --- Settings ---
    async def get_setting(self, key: str, default: str = "") -> str:
        row = await self._fetchone("SELECT value FROM settings WHERE key = ?", (key,))
        return row["value"] if row else default

    async def set_setting(self, key: str, value: str):
        await self._execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, value),
        )

    # --- Panels ---
    async def get_panels(self, active_only: bool = True) -> list[dict]:
        if active_only:
            return await self._fetchall(
                "SELECT * FROM panels WHERE is_active = 1 ORDER BY id"
            )
        return await self._fetchall("SELECT * FROM panels ORDER BY id")

    async def get_panel(self, panel_id: int) -> dict | None:
        return await self._fetchone("SELECT * FROM panels WHERE id = ?", (panel_id,))

    async def add_panel(
        self, name: str, url: str, api_token: str, inbound_ids: str, on_hold: int = 0
    ) -> int:
        return await self._execute(
            "INSERT INTO panels (name, url, api_token, inbound_ids, on_hold) VALUES (?, ?, ?, ?, ?)",
            (name, url.rstrip("/"), api_token, inbound_ids, on_hold),
        )

    async def update_panel(self, panel_id: int, **fields):
        allowed = {"name", "url", "api_token", "inbound_ids", "on_hold", "is_active", "sub_link_template"}
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return
        cols = ", ".join(f"{k} = ?" for k in updates)
        await self._execute(
            f"UPDATE panels SET {cols} WHERE id = ?",
            (*updates.values(), panel_id),
        )

    async def delete_panel(self, panel_id: int):
        await self._execute("DELETE FROM panels WHERE id = ?", (panel_id,))

    # --- Products ---
    async def get_products(self, active_only: bool = True, trial: bool | None = None) -> list[dict]:
        query = "SELECT p.*, pn.name as panel_name FROM products p JOIN panels pn ON p.panel_id = pn.id"
        conditions = []
        if active_only:
            conditions.append("p.is_active = 1")
        if trial is not None:
            conditions.append(f"p.is_trial = {1 if trial else 0}")
        if conditions:
            query += " WHERE " + " AND ".join(conditions)
        query += " ORDER BY p.price"
        return await self._fetchall(query)

    async def get_product(self, product_id: int) -> dict | None:
        return await self._fetchone(
            "SELECT p.*, pn.name as panel_name, pn.url as panel_url, "
            "pn.api_token, pn.inbound_ids, pn.on_hold "
            "FROM products p JOIN panels pn ON p.panel_id = pn.id "
            "WHERE p.id = ?",
            (product_id,),
        )

    async def add_product(
        self,
        name: str,
        panel_id: int,
        volume_gb: float,
        duration_days: int,
        price: int,
        is_trial: int = 0,
        description: str = "",
    ) -> int:
        return await self._execute(
            "INSERT INTO products (name, panel_id, volume_gb, duration_days, price, is_trial, description) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (name, panel_id, volume_gb, duration_days, price, is_trial, description),
        )

    async def update_product(self, product_id: int, **fields):
        allowed = {
            "name", "panel_id", "volume_gb", "duration_days",
            "price", "is_trial", "is_active", "description",
        }
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return
        cols = ", ".join(f"{k} = ?" for k in updates)
        await self._execute(
            f"UPDATE products SET {cols} WHERE id = ?",
            (*updates.values(), product_id),
        )

    async def delete_product(self, product_id: int):
        await self._execute("DELETE FROM products WHERE id = ?", (product_id,))

    # --- Subscriptions ---
    async def add_subscription(self, **data) -> int:
        return await self._execute(
            "INSERT INTO subscriptions "
            "(user_id, product_id, panel_id, email, sub_id, volume_gb, expiry_time, "
            "config_link, config_links, sub_link, status, is_trial) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                data["user_id"],
                data.get("product_id"),
                data["panel_id"],
                data["email"],
                data.get("sub_id", ""),
                data["volume_gb"],
                data.get("expiry_time", 0),
                data.get("config_link", ""),
                data.get("config_links", "[]"),
                data.get("sub_link", ""),
                data.get("status", "active"),
                data.get("is_trial", 0),
            ),
        )

    async def get_user_subscriptions(self, user_id: int) -> list[dict]:
        return await self._fetchall(
            "SELECT s.*, pn.name as panel_name, pn.url as panel_url, pn.api_token "
            "FROM subscriptions s JOIN panels pn ON s.panel_id = pn.id "
            "WHERE s.user_id = ? ORDER BY s.created_at DESC",
            (user_id,),
        )

    async def get_subscription(self, sub_id: int) -> dict | None:
        return await self._fetchone(
            "SELECT s.*, pn.name as panel_name, pn.url as panel_url, "
            "pn.api_token, pn.inbound_ids, pn.sub_link_template "
            "FROM subscriptions s JOIN panels pn ON s.panel_id = pn.id "
            "WHERE s.id = ?",
            (sub_id,),
        )

    async def update_subscription(self, sub_id: int, **fields):
        allowed = {
            "config_link", "config_links", "sub_link", "status", "expiry_time",
            "volume_gb", "email", "sub_id",
        }
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return
        cols = ", ".join(f"{k} = ?" for k in updates)
        await self._execute(
            f"UPDATE subscriptions SET {cols} WHERE id = ?",
            (*updates.values(), sub_id),
        )

    async def user_has_trial(self, user_id: int) -> bool:
        row = await self._fetchone(
            "SELECT COUNT(*) as c FROM subscriptions WHERE user_id = ? AND is_trial = 1",
            (user_id,),
        )
        return (row["c"] if row else 0) > 0

    async def get_active_subscriptions_count(self) -> int:
        row = await self._fetchone(
            "SELECT COUNT(*) as c FROM subscriptions WHERE status = 'active'"
        )
        return row["c"] if row else 0

    # --- Orders ---
    async def create_order(
        self, user_id: int, product_id: int | None, amount: int,
        payment_method: str, description: str = "",
    ) -> tuple[int, str]:
        import random
        import string
        code = "".join(random.choices(string.digits, k=8))
        oid = await self._execute(
            "INSERT INTO orders (user_id, product_id, order_code, amount, payment_method, description) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, product_id, code, amount, payment_method, description),
        )
        return oid, code

    async def get_order(self, order_id: int) -> dict | None:
        return await self._fetchone("SELECT * FROM orders WHERE id = ?", (order_id,))

    async def get_order_by_code(self, code: str) -> dict | None:
        return await self._fetchone(
            "SELECT * FROM orders WHERE order_code = ?", (code,)
        )

    async def update_order_status(self, order_id: int, status: str):
        await self._execute(
            "UPDATE orders SET status = ? WHERE id = ?", (status, order_id)
        )

    # --- Payments ---
    async def create_payment(
        self, user_id: int, amount: int, payment_method: str = "card",
        order_id: int | None = None, receipt_file_id: str | None = None,
        product_id: int | None = None, renew_sub_id: int | None = None,
    ) -> int:
        return await self._execute(
            "INSERT INTO payments (user_id, order_id, product_id, renew_sub_id, amount, payment_method, receipt_file_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (user_id, order_id, product_id, renew_sub_id, amount, payment_method, receipt_file_id),
        )

    async def get_payment(self, payment_id: int) -> dict | None:
        return await self._fetchone("SELECT * FROM payments WHERE id = ?", (payment_id,))

    async def get_pending_payments(self) -> list[dict]:
        return await self._fetchall(
            "SELECT py.*, u.telegram_id, u.username "
            "FROM payments py JOIN users u ON py.user_id = u.id "
            "WHERE py.status = 'pending' ORDER BY py.created_at"
        )

    async def update_payment(self, payment_id: int, status: str, admin_note: str = ""):
        await self._execute(
            "UPDATE payments SET status = ?, admin_note = ? WHERE id = ?",
            (status, admin_note, payment_id),
        )

    async def claim_payment(self, payment_id: int, status: str, admin_id: int) -> bool:
        """Atomically move a payment from 'pending' to status, recording who claimed it.

        Returns False if the payment was no longer pending (i.e. another admin
        already approved/rejected it) — callers must not act on the payment
        again in that case. This is what makes multi-admin approval race-safe.
        """
        conn = await self.connect()
        try:
            cursor = await conn.execute(
                "UPDATE payments SET status = ?, handled_by = ? WHERE id = ? AND status = 'pending'",
                (status, admin_id, payment_id),
            )
            await conn.commit()
            return cursor.rowcount > 0
        finally:
            await conn.close()

    async def get_payment_notif_chats(self, payment_id: int) -> list[dict]:
        row = await self._fetchone(
            "SELECT notif_chats FROM payments WHERE id = ?", (payment_id,)
        )
        if not row or not row.get("notif_chats"):
            return []
        try:
            return json.loads(row["notif_chats"])
        except (json.JSONDecodeError, TypeError):
            return []

    async def set_payment_notif_chats(self, payment_id: int, chats: list[dict]):
        await self._execute(
            "UPDATE payments SET notif_chats = ? WHERE id = ?",
            (json.dumps(chats), payment_id),
        )

    async def append_payment_notif_chat(self, payment_id: int, chat_id: int, message_id: int):
        chats = await self.get_payment_notif_chats(payment_id)
        chats.append({"chat_id": chat_id, "message_id": message_id})
        await self.set_payment_notif_chats(payment_id, chats)

    # --- FAQ ---
    async def get_faqs(self) -> list[dict]:
        return await self._fetchall(
            "SELECT * FROM faq ORDER BY sort_order, id"
        )

    async def add_faq(self, question: str, answer: str) -> int:
        return await self._execute(
            "INSERT INTO faq (question, answer) VALUES (?, ?)", (question, answer)
        )

    async def delete_faq(self, faq_id: int):
        await self._execute("DELETE FROM faq WHERE id = ?", (faq_id,))

    # --- Tutorials ---
    async def get_tutorials(self) -> list[dict]:
        return await self._fetchall(
            "SELECT * FROM tutorials ORDER BY sort_order, id"
        )

    async def add_tutorial(self, title: str, content: str) -> int:
        return await self._execute(
            "INSERT INTO tutorials (title, content) VALUES (?, ?)", (title, content)
        )

    async def delete_tutorial(self, tutorial_id: int):
        await self._execute("DELETE FROM tutorials WHERE id = ?", (tutorial_id,))

    # --- Coupons ---
    async def add_coupon(
        self,
        code: str,
        discount_type: str,
        discount_value: int,
        usage_type: str,
        max_uses: int = 0,
        expires_at: str | None = None,
    ) -> int:
        return await self._execute(
            "INSERT INTO coupons (code, discount_type, discount_value, usage_type, max_uses, expires_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (code.upper(), discount_type, discount_value, usage_type, max_uses, expires_at),
        )

    async def get_coupons(self) -> list[dict]:
        return await self._fetchall("SELECT * FROM coupons ORDER BY id DESC")

    async def get_coupon(self, coupon_id: int) -> dict | None:
        return await self._fetchone("SELECT * FROM coupons WHERE id = ?", (coupon_id,))

    async def get_coupon_by_code(self, code: str) -> dict | None:
        return await self._fetchone("SELECT * FROM coupons WHERE code = ?", (code.upper(),))

    async def update_coupon(self, coupon_id: int, **fields):
        allowed = {"is_active", "discount_value", "discount_type", "usage_type", "max_uses", "expires_at"}
        updates = {k: v for k, v in fields.items() if k in allowed}
        if not updates:
            return
        cols = ", ".join(f"{k} = ?" for k in updates)
        await self._execute(
            f"UPDATE coupons SET {cols} WHERE id = ?",
            (*updates.values(), coupon_id),
        )

    async def delete_coupon(self, coupon_id: int):
        await self._execute("DELETE FROM coupon_uses WHERE coupon_id = ?", (coupon_id,))
        await self._execute("DELETE FROM coupons WHERE id = ?", (coupon_id,))

    async def validate_coupon(self, code: str, user_id: int) -> tuple[dict | None, str]:
        """
        کوپن رو اعتبارسنجی می‌کنه.
        Returns: (coupon_dict, error_message)
        اگه error_message خالی باشه یعنی کوپن معتبره.
        """
        coupon = await self.get_coupon_by_code(code)
        if not coupon:
            return None, "❌ کوپن تخفیف یافت نشد."
        if not coupon["is_active"]:
            return None, "❌ این کوپن غیرفعال است."
        if coupon["expires_at"]:
            from datetime import datetime
            try:
                exp = datetime.fromisoformat(coupon["expires_at"])
                if datetime.now() > exp:
                    return None, "❌ مدت اعتبار این کوپن به پایان رسیده است."
            except ValueError:
                pass
        if coupon["max_uses"] > 0 and coupon["used_count"] >= coupon["max_uses"]:
            return None, "❌ ظرفیت استفاده از این کوپن تکمیل شده است."
        if coupon["usage_type"] in ("once_per_user", "one_time"):
            already = await self._fetchone(
                "SELECT id FROM coupon_uses WHERE coupon_id = ? AND user_id = ?",
                (coupon["id"], user_id),
            )
            if already:
                return None, "❌ شما قبلاً از این کوپن استفاده کرده‌اید."
        return coupon, ""

    async def apply_coupon(self, coupon_id: int, user_id: int):
        """ثبت استفاده از کوپن و افزایش شمارنده."""
        await self._execute(
            "INSERT INTO coupon_uses (coupon_id, user_id) VALUES (?, ?)",
            (coupon_id, user_id),
        )
        await self._execute(
            "UPDATE coupons SET used_count = used_count + 1 WHERE id = ?",
            (coupon_id,),
        )

    def calc_discount(self, coupon: dict, price: int) -> int:
        """مبلغ تخفیف رو محاسبه می‌کنه (حداکثر برابر قیمت)."""
        if coupon["discount_type"] == "percent":
            discount = int(price * coupon["discount_value"] / 100)
        else:
            discount = coupon["discount_value"]
        return min(discount, price)


_db: Database | None = None


def get_db() -> Database:
    global _db
    if _db is None:
        _db = Database()
    return _db
