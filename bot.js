require('dotenv').config();
const TelegramBot = require('node-telegram-bot-api');
const Anthropic = require('@anthropic-ai/sdk');

const bot = new TelegramBot(process.env.TELEGRAM_BOT_TOKEN, { polling: true });
const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

// Per-user conversation history
const conversations = new Map();
const MAX_HISTORY = 20;

bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = msg.text;

  if (!text) return;

  if (text === '/start') {
    conversations.delete(chatId);
    return bot.sendMessage(chatId,
      'Привіт! Я AI-асистент на базі Claude. Задавай будь-які питання!'
    );
  }

  if (text === '/clear') {
    conversations.delete(chatId);
    return bot.sendMessage(chatId, 'Історію очищено.');
  }

  if (text === '/help') {
    return bot.sendMessage(chatId,
      '/start — почати новий діалог\n/clear — очистити історію\n/help — допомога'
    );
  }

  // Show typing indicator
  bot.sendChatAction(chatId, 'typing');

  // Build conversation history
  if (!conversations.has(chatId)) conversations.set(chatId, []);
  const history = conversations.get(chatId);
  history.push({ role: 'user', content: text });

  // Keep history within limit
  while (history.length > MAX_HISTORY) history.splice(0, 2);

  try {
    const response = await anthropic.messages.create({
      model: 'claude-sonnet-4-6',
      max_tokens: 1024,
      system: `Ти — AI бізнес-асистент для підприємців.

Твої сильні сторони:
• Стратегічне мислення — аналіз ідей
• Управління — пріоритети, делегування
• Комунікація — листи, презентації
• Фінанси — unit-економіка, ROI

Будь конкретним, давай цифри та плани.`,
      messages: history,
    });

    const reply = response.content[0].text;
    history.push({ role: 'assistant', content: reply });

    await bot.sendMessage(chatId, reply, { parse_mode: 'Markdown' });
  } catch (err) {
    console.error('Claude API error:', err.message);
    // Retry without markdown if parse error
    if (err.message?.includes('parse')) {
      await bot.sendMessage(chatId, reply);
    } else {
      await bot.sendMessage(chatId, 'Помилка. Спробуй ще раз.');
    }
  }
});

console.log('Bot started.');
