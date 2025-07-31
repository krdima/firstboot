#!/bin/bash

# Проверка наличия трех обязательных аргументов
if [ $# -ne 3 ]; then
    echo "Usage: $0 <FINGERPRINT> <TG_BOT_TOKEN> <CHAT_ID>"
    exit 1
fi

FINGERPRINT="$1"
TG_BOT_TOKEN="$2"
CHAT_ID="$3"
REPO_URL="https://github.com/krdima/firstboot.git"
BRANCH="main"
SCRIPT_NAME="bot.sh"
INSTALL_DIR="/root/bot/"

# Создаем рабочую директорию
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit 1

# Проверка сети с повторными попытками
        NETWORK_OK=0
        for i in {1..10}; do
          if ping -c 3 8.8.8.8 &>/dev/null; then
            echo "Сеть доступна"
            NETWORK_OK=1
            break
          else
            echo "Попытка $i/10: сеть недоступна"
            sleep 5
          fi
        done
        if [ "$NETWORK_OK" -eq 0 ]; then
          echo "Критическая ошибка: сеть недоступна"
          exit 1
        fi

# Обновление из Git
update_bot() {
    echo "🔁 Проверка обновлений бота..."
    
    if [ ! -d ".git" ]; then
        echo "🔄 Первоначальное клонирование репозитория..."
        git clone -b "$BRANCH" "$REPO_URL" . || return 1
        chmod +x "$SCRIPT_NAME"
        return 0
    fi
    
    # Проверяем обновления
    git fetch origin
    LOCAL_COMMIT=$(git rev-parse HEAD)
    REMOTE_COMMIT=$(git rev-parse origin/"$BRANCH")
    
    if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
        echo "🔄 Обнаружены обновления. Выполняем обновление..."
        git reset --hard origin/"$BRANCH"
        git pull origin "$BRANCH"
        chmod +x "$SCRIPT_NAME"
    fi
    
    return 0
}

# Основная логика
if update_bot; then
    echo "✅ Бот успешно обновлен"
    # Запускаем основную программу
    exec "./$SCRIPT_NAME" "$FINGERPRINT" "$TG_BOT_TOKEN" "$CHAT_ID"
else
    echo "❌ Ошибка обновления бота"
    exit 1
fi