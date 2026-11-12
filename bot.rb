# frozen_string_literal: true

# Telegram-бот «Менеджер посилань».
# Команди: /start, /help, /save [url] [tag], /get [tag], /tags, /delete [url]
# Дані зберігаються у CSV-файлі data/links.csv.

require 'telegram/bot'
require 'csv'
require 'uri'
require 'fileutils'

TOKEN     = ENV['TELEGRAM_BOT_TOKEN']
DATA_FILE = File.join(__dir__, 'data', 'links.csv')
HEADERS   = %w[chat_id tag url saved_at].freeze

abort 'Не задано змінну середовища TELEGRAM_BOT_TOKEN' if TOKEN.nil? || TOKEN.empty?

# ---------- Робота зі сховищем (CSV) ----------

def ensure_storage
  FileUtils.mkdir_p(File.dirname(DATA_FILE))
  return if File.exist?(DATA_FILE)

  CSV.open(DATA_FILE, 'w') { |csv| csv << HEADERS }
end

def load_links
  ensure_storage
  CSV.read(DATA_FILE, headers: true).map(&:to_h)
end

def save_links(rows)
  CSV.open(DATA_FILE, 'w') do |csv|
    csv << HEADERS
    rows.each { |row| csv << HEADERS.map { |h| row[h] } }
  end
end

def add_link(chat_id, url, tag)
  rows = load_links
  duplicate = rows.any? do |r|
    r['chat_id'] == chat_id.to_s && r['url'] == url && r['tag'] == tag
  end
  return false if duplicate

  CSV.open(DATA_FILE, 'a') do |csv|
    csv << [chat_id, tag, url, Time.now.strftime('%Y-%m-%d %H:%M')]
  end
  true
end

def links_by_tag(chat_id, tag)
  load_links.select { |r| r['chat_id'] == chat_id.to_s && r['tag'] == tag }
end

def tags_for(chat_id)
  load_links.select { |r| r['chat_id'] == chat_id.to_s }
            .map { |r| r['tag'] }
            .tally
end

def delete_link(chat_id, url)
  rows = load_links
  left = rows.reject { |r| r['chat_id'] == chat_id.to_s && r['url'] == url }
  removed = rows.size - left.size
  save_links(left) if removed.positive?
  removed
end

# ---------- Допоміжні функції ----------

def valid_url?(text)
  uri = URI.parse(text)
  %w[http https].include?(uri.scheme) && !uri.host.nil? && uri.host.include?('.')
rescue URI::InvalidURIError
  false
end

def normalize_tag(tag)
  tag.to_s.downcase.delete_prefix('#')
end

HELP_TEXT = <<~TEXT
  Я зберігаю корисні посилання за тегами.

  /save [url] [tag] – зберегти посилання з тегом
  /get [tag] – показати всі посилання за тегом
  /tags – показати всі ваші теги
  /delete [url] – видалити посилання
  /help – ця довідка

  Приклад: /save https://ruby-lang.org ruby
TEXT

# ---------- Обробка команд ----------

def handle_message(bot, message)
  return unless message.respond_to?(:text) && message.text

  chat_id = message.chat.id
  command, *args = message.text.strip.split(/\s+/)
  command = command.to_s.sub(/@\w+\z/, '') # /save@my_bot -> /save

  reply = case command
          when '/start'
            "Привіт, #{message.from.first_name}! Я бот «Менеджер посилань».\n\n#{HELP_TEXT}"
          when '/help'
            HELP_TEXT
          when '/save'
            cmd_save(chat_id, args)
          when '/get'
            cmd_get(chat_id, args)
          when '/tags'
            cmd_tags(chat_id)
          when '/delete'
            cmd_delete(chat_id, args)
          else
            'Невідома команда. Напишіть /help, щоб побачити список команд.'
          end

  bot.api.send_message(chat_id: chat_id, text: reply, disable_web_page_preview: true)
end

def cmd_save(chat_id, args)
  return "Формат: /save [url] [tag]\nПриклад: /save https://ruby-lang.org ruby" if args.size < 2

  url = args[0]
  tag = normalize_tag(args[1])
  return "Некоректне посилання: #{url}\nВоно має починатися з http:// або https://" unless valid_url?(url)
  return 'Тег не може бути порожнім.' if tag.empty?

  if add_link(chat_id, url, tag)
    "Збережено з тегом ##{tag}"
  else
    'Таке посилання з цим тегом уже збережено.'
  end
end

def cmd_get(chat_id, args)
  return "Формат: /get [tag]\nПриклад: /get ruby" if args.empty?

  tag = normalize_tag(args[0])
  rows = links_by_tag(chat_id, tag)
  return "За тегом ##{tag} нічого не знайдено. Спробуйте /tags." if rows.empty?

  list = rows.each_with_index.map { |r, i| "#{i + 1}. #{r['url']}" }.join("\n")
  "Посилання за тегом ##{tag}:\n#{list}"
end

def cmd_tags(chat_id)
  tags = tags_for(chat_id)
  return 'Ви ще не зберегли жодного посилання. Скористайтеся /save.' if tags.empty?

  lines = tags.sort.map { |tag, count| "##{tag} – #{count}" }
  "Ваші теги:\n#{lines.join("\n")}"
end

def cmd_delete(chat_id, args)
  return "Формат: /delete [url]\nПриклад: /delete https://ruby-lang.org" if args.empty?

  removed = delete_link(chat_id, args[0])
  removed.positive? ? "Видалено записів: #{removed}" : 'Таке посилання не знайдено.'
end

# ---------- Запуск ----------

ensure_storage
puts 'Бот запущено. Для зупинки натисніть Ctrl+C.'

Telegram::Bot::Client.run(TOKEN) do |bot|
  bot.listen do |message|
    handle_message(bot, message)
  rescue Telegram::Bot::Exceptions::ResponseError => e
    warn "Помилка Telegram API: #{e.message}"
  rescue StandardError => e
    warn "Непередбачена помилка: #{e.class}: #{e.message}"
    begin
      bot.api.send_message(chat_id: message.chat.id, text: 'Сталася помилка. Спробуйте ще раз.')
    rescue StandardError
      nil
    end
  end
end
