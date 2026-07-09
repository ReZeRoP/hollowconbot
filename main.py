"""Application entry point."""

import asyncio
import logging
import sys

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import MenuButtonWebApp, WebAppInfo

from bot.handlers import admin_router, user_router
from bot.middlewares import UserMiddleware
from config import get_settings
from database import get_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger(__name__)


async def main():
    settings = get_settings()
    if not settings.bot_token or settings.bot_token == "your_bot_token_here":
        logger.error("BOT_TOKEN is not set. Copy .env.example to .env and configure it.")
        sys.exit(1)

    if not settings.admin_ids:
        logger.warning("ADMIN_IDS is empty — no admin access configured.")

    db = get_db()
    await db.init()
    logger.info("Database initialized.")

    bot = Bot(
        token=settings.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher(storage=MemoryStorage())

    user_middleware = UserMiddleware()
    dp.message.middleware(user_middleware)
    dp.callback_query.middleware(user_middleware)
    dp.include_router(admin_router)
    dp.include_router(user_router)

    # Save the bot's own username so the web panel's "Login with Telegram"
    # widget (which needs data-telegram-login=<username>) always has it,
    # without requiring the admin to enter it manually anywhere.
    me = await bot.get_me()
    await db.set_setting("bot_username", me.username or "")
    logger.info(f"Bot username: @{me.username}")

    # Register the Mini App (Web App) button in Telegram's chat menu, so the
    # panel can be opened directly from the bot's chat, not just a browser.
    # Telegram only accepts HTTPS URLs for web_app menu buttons.
    panel_url = settings.panel_url.strip()
    if panel_url.startswith("https://"):
        try:
            await bot.set_chat_menu_button(
                menu_button=MenuButtonWebApp(text="پنل وب", web_app=WebAppInfo(url=panel_url))
            )
            logger.info(f"Web App menu button registered: {panel_url}")
        except Exception as exc:
            logger.warning(f"Could not register Web App menu button: {exc}")
    elif panel_url:
        logger.warning(
            "PANEL_URL is set but is not HTTPS — Telegram Web Apps require HTTPS. "
            "The web panel button will not be shown in Telegram."
        )

    logger.info("Bot starting...")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
