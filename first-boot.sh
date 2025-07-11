#!/bin/bash
set -e

# Параметры
FINGERPRINT=$1
BOT_TOKEN=$2
ADMIN_CHAT_ID=$3  # Получаем из user-data

# Функция регистрации
register_server() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${ADMIN_CHAT_ID}" \
    -d "text=/register ${FINGERPRINT}"
}

# Основной процесс
if register_server; then
  logger -t first-boot "✅ Регистрация отправлена"
else
  logger -t first-boot "❌ Ошибка регистрации"
fi

# Очистка
unset BOT_TOKEN
rm -f /etc/cron.d/first-boot
