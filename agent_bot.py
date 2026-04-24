import os
import math
import base64
import logging
import httpx
from datetime import datetime
from pathlib import Path
from dotenv import load_dotenv
from anthropic import Anthropic
from bs4 import BeautifulSoup
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes

load_dotenv()

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

anthropic = Anthropic(api_key=os.getenv('ANTHROPIC_API_KEY'))
NOTES_DIR = Path('notes')

SYSTEM_PROMPT = """Ти — AI бізнес-асистент для підприємців.

Твої сильні сторони:
• Стратегічне мислення — аналіз ідей
• Управління — пріоритети, делегування
• Комунікація — листи, презентації
• Фінанси — unit-економіка, ROI

Будь конкретним, давай цифри та плани.
Відповідай українською мовою."""

TOOLS = [
    {
        "name": "calculate",
        "description": "Виконує математичні розрахунки за виразом",
        "input_schema": {
            "type": "object",
            "properties": {
                "expression": {"type": "string", "description": "Математичний вираз, наприклад: 150 * 12 / 100"}
            },
            "required": ["expression"]
        }
    },
    {
        "name": "save_note",
        "description": "Зберігає нотатку для користувача",
        "input_schema": {
            "type": "object",
            "properties": {
                "user_id": {"type": "string"},
                "title":   {"type": "string", "description": "Назва нотатки"},
                "content": {"type": "string", "description": "Текст нотатки"}
            },
            "required": ["user_id", "title", "content"]
        }
    },
    {
        "name": "list_notes",
        "description": "Повертає список нотаток користувача",
        "input_schema": {
            "type": "object",
            "properties": {
                "user_id": {"type": "string"}
            },
            "required": ["user_id"]
        }
    },
    {
        "name": "delete_note",
        "description": "Видаляє нотатку за назвою",
        "input_schema": {
            "type": "object",
            "properties": {
                "user_id": {"type": "string"},
                "title":   {"type": "string"}
            },
            "required": ["user_id", "title"]
        }
    },
    {
        "name": "get_datetime",
        "description": "Повертає поточну дату та час українською мовою",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "read_url",
        "description": "Читає текстовий вміст веб-сторінки за URL",
        "input_schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string"}
            },
            "required": ["url"]
        }
    }
]

# ── Tool implementations ──────────────────────────────────────────────────────

def calculate(expression: str) -> str:
    allowed = set('0123456789+-*/()., %')
    if not all(c in allowed for c in expression):
        return "Помилка: недозволені символи у виразі"
    try:
        result = eval(expression, {"__builtins__": {}, "math": math})
        return f"{expression} = {result}"
    except Exception as e:
        return f"Помилка розрахунку: {e}"

def save_note(user_id: str, title: str, content: str) -> str:
    path = NOTES_DIR / user_id
    path.mkdir(parents=True, exist_ok=True)
    (path / f"{title}.txt").write_text(content, encoding='utf-8')
    return f"Нотатку «{title}» збережено."

def list_notes(user_id: str) -> str:
    path = NOTES_DIR / user_id
    if not path.exists():
        return "Нотаток ще немає."
    notes = sorted(path.glob('*.txt'))
    if not notes:
        return "Нотаток ще немає."
    return "Ваші нотатки:\n" + "\n".join(f"• {n.stem}" for n in notes)

def delete_note(user_id: str, title: str) -> str:
    note = NOTES_DIR / user_id / f"{title}.txt"
    if note.exists():
        note.unlink()
        return f"Нотатку «{title}» видалено."
    return f"Нотатку «{title}» не знайдено."

def get_datetime() -> str:
    months = ['січня','лютого','березня','квітня','травня','червня',
              'липня','серпня','вересня','жовтня','листопада','грудня']
    days   = ['понеділок','вівторок','середа','четвер',
              "п'ятниця","субота","неділя"]
    now = datetime.now()
    return f"{days[now.weekday()]}, {now.day} {months[now.month-1]} {now.year} року, {now.strftime('%H:%M')}"

def read_url(url: str) -> str:
    try:
        with httpx.Client(timeout=15, follow_redirects=True) as client:
            r = client.get(url, headers={'User-Agent': 'Mozilla/5.0'})
        soup = BeautifulSoup(r.text, 'html.parser')
        for tag in soup(['script', 'style', 'nav', 'footer', 'header']):
            tag.decompose()
        text = soup.get_text(separator='\n', strip=True)
        return text[:4000] + ('…' if len(text) > 4000 else '')
    except Exception as e:
        return f"Помилка читання сторінки: {e}"

def run_tool(name: str, inputs: dict) -> str:
    match name:
        case 'calculate':  return calculate(inputs['expression'])
        case 'save_note':  return save_note(inputs['user_id'], inputs['title'], inputs['content'])
        case 'list_notes': return list_notes(inputs['user_id'])
        case 'delete_note':return delete_note(inputs['user_id'], inputs['title'])
        case 'get_datetime':return get_datetime()
        case 'read_url':   return read_url(inputs['url'])
        case _:            return f"Невідомий інструмент: {name}"

# ── Agentic loop ──────────────────────────────────────────────────────────────

def agent_response(user_id: str, messages: list) -> str:
    while True:
        response = anthropic.messages.create(
            model='claude-sonnet-4-6',
            max_tokens=2048,
            system=SYSTEM_PROMPT,
            tools=TOOLS,
            messages=messages,
        )
        if response.stop_reason == 'end_turn':
            return next((b.text for b in response.content if hasattr(b, 'text')), "—")

        if response.stop_reason == 'tool_use':
            messages.append({"role": "assistant", "content": response.content})
            results = []
            for block in response.content:
                if block.type == 'tool_use':
                    # inject user_id for note tools
                    inp = dict(block.input)
                    if block.name in ('save_note', 'list_notes', 'delete_note'):
                        inp['user_id'] = user_id
                    result = run_tool(block.name, inp)
                    results.append({"type": "tool_result", "tool_use_id": block.id, "content": result})
            messages.append({"role": "user", "content": results})
        else:
            return "Помилка агента."

# ── State ─────────────────────────────────────────────────────────────────────

conversations: dict[str, list] = {}
MAX_HISTORY = 20

def get_history(user_id: str) -> list:
    if user_id not in conversations:
        conversations[user_id] = []
    return conversations[user_id]

def trim(history: list):
    while len(history) > MAX_HISTORY:
        history.pop(0)

# ── Handlers ──────────────────────────────────────────────────────────────────

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    conversations[str(update.effective_user.id)] = []
    await update.message.reply_text(
        "Привіт! Я AI бізнес-асистент.\n\n"
        "Що вмію:\n"
        "• Рахувати та аналізувати фінанси\n"
        "• Зберігати нотатки (/notes)\n"
        "• Читати сайти за посиланням\n"
        "• Аналізувати фото\n\n"
        "/notes — мої нотатки\n"
        "/clear — очистити діалог"
    )

async def cmd_clear(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    conversations[str(update.effective_user.id)] = []
    await update.message.reply_text("Діалог очищено.")

async def cmd_notes(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(list_notes(str(update.effective_user.id)))

async def handle_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    text = update.message.text or ""
    history = get_history(user_id)
    history.append({"role": "user", "content": text})
    trim(history)
    await update.message.chat.send_action('typing')
    reply = agent_response(user_id, list(history))
    history.append({"role": "assistant", "content": reply})
    await update.message.reply_text(reply)

async def handle_photo(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    user_id = str(update.effective_user.id)
    caption = update.message.caption or "Проаналізуй це фото з бізнес-перспективи."
    await update.message.chat.send_action('typing')
    photo_file = await (await ctx.bot.get_file(update.message.photo[-1].file_id)).download_as_bytearray()
    image_b64 = base64.b64encode(bytes(photo_file)).decode()
    response = anthropic.messages.create(
        model='claude-sonnet-4-6',
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": image_b64}},
            {"type": "text", "text": caption}
        ]}]
    )
    await update.message.reply_text(response.content[0].text)

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    logger.info("Agent bot started with tools")
    NOTES_DIR.mkdir(exist_ok=True)
    app = Application.builder().token(os.getenv('TELEGRAM_BOT_TOKEN')).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("clear", cmd_clear))
    app.add_handler(CommandHandler("notes", cmd_notes))
    app.add_handler(MessageHandler(filters.PHOTO, handle_photo))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    app.run_polling()

if __name__ == '__main__':
    main()
