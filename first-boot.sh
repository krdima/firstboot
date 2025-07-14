#!/bin/bash

# Проверка аргументов
if [ $# -ne 3 ]; then
    echo "Usage: $0 <server_fingerprint> <tg_bot_token> <chat_id>"
    exit 1
fi

FINGERPRINT="$1"
TG_BOT_TOKEN="$2"
CHAT_ID="$3"
API_URL="https://api.telegram.org/bot$TG_BOT_TOKEN"
SELF_PATH=$(realpath "$0")

# Функции для работы с Telegram API
send_telegram() {
    local text="$1"
    curl -s -X POST "$API_URL/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$text" \
        -d parse_mode="Markdown"
}

send_keyboard() {
    local text="$1"
    local keyboard="$2"
    curl -s -X POST "$API_URL/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$text" \
        -d reply_markup="$keyboard" \
        -d parse_mode="Markdown"
}

# Проверка интернета
until ping -c1 8.8.8.8 &>/dev/null; do
    sleep 5
done

# Получение внешнего IP
EXTERNAL_IP=$(curl -s ifconfig.me)

# Проверка SSH
ss -tuln | grep -q ':22 ' || send_telegram "⚠️ SSH не слушает порт 22"

# Отправка информации с кнопками
KEYBOARD='{
    "inline_keyboard": [
        [{"text": "Принять", "callback_data": "approve"}],
        [{"text": "Отклонить", "callback_data": "deny"}]
    ]
}'

send_keyboard "✅ Сервер запущен!\n\n• IP: \`$EXTERNAL_IP\`\n• Отпечаток: \`$FINGERPRINT\`" "$KEYBOARD"

# Ожидание ответа
TIMEOUT=$((SECONDS + 600))  # 10 минут таймаут
LAST_UPDATE_ID=0

while [ $SECONDS -lt $TIMEOUT ]; do
    # Получаем обновления с таймаутом
    RESPONSE=$(curl -s -m 10 "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
    
    # Проверяем валидность JSON
    if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
        sleep 5
        continue
    fi
    
    # Извлекаем список обновлений
    UPDATES_COUNT=$(echo "$RESPONSE" | jq -r '.result | length')
    
    for ((i=0; i<UPDATES_COUNT; i++)); do
        UPDATE=$(echo "$RESPONSE" | jq -r ".result[$i]")
        UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
        
        # Обновляем последний ID
        if [ "$UPDATE_ID" -gt "$LAST_UPDATE_ID" ]; then
            LAST_UPDATE_ID=$UPDATE_ID
        fi
        
        CALLBACK_QUERY=$(echo "$UPDATE" | jq -r '.callback_query')
        if [ "$CALLBACK_QUERY" != "null" ]; then
            DATA=$(echo "$CALLBACK_QUERY" | jq -r '.data')
            CB_CHAT_ID=$(echo "$CALLBACK_QUERY" | jq -r '.message.chat.id')
            CB_ID=$(echo "$CALLBACK_QUERY" | jq -r '.id')
            
            if [ "$CB_CHAT_ID" = "$CHAT_ID" ]; then
                case $DATA in
                    "deny")
                        # Ответ на callback
                        curl -s -X POST "$API_URL/answerCallbackQuery" \
                            -d callback_query_id="$CB_ID"
                        
                        # Самоудаление
                        systemctl disable first-boot.service
                        rm -f "$SELF_PATH" /etc/systemd/system/first-boot.service
                        systemctl daemon-reload
                        exit 0
                        ;;
                    "approve")
                        # Ответ на callback
                        curl -s -X POST "$API_URL/answerCallbackQuery" \
                            -d callback_query_id="$CB_ID"
                        
                        # Запрос нового токена
                        send_telegram "Введите новый токен бота:"
                        TOKEN_TIMEOUT=$((SECONDS + 300))  # 5 минут на ввод токена
                        TOKEN_RECEIVED=""
                        
                        while [ $SECONDS -lt $TOKEN_TIMEOUT ] && [ -z "$TOKEN_RECEIVED" ]; do
                            TOKEN_RESP=$(curl -s -m 10 "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
                            
                            if echo "$TOKEN_RESP" | jq -e . >/dev/null 2>&1; then
                                MSG_UPDATE=$(echo "$TOKEN_RESP" | jq -r '.result[0]')
                                if [ "$MSG_UPDATE" != "null" ]; then
                                    MSG_TEXT=$(echo "$MSG_UPDATE" | jq -r '.message.text // empty')
                                    if [ -n "$MSG_TEXT" ]; then
                                        MSG_CHAT_ID=$(echo "$MSG_UPDATE" | jq -r '.message.chat.id')
                                        if [ "$MSG_CHAT_ID" = "$CHAT_ID" ]; then
                                            TOKEN_RECEIVED="$MSG_TEXT"
                                            LAST_UPDATE_ID=$(echo "$MSG_UPDATE" | jq -r '.update_id')
                                        fi
                                    fi
                                fi
                            fi
                            sleep 2
                        done
                        
                        if [ -z "$TOKEN_RECEIVED" ]; then
                            send_telegram "⏰ Время ожидания токена истекло!"
                            exit 1
                        fi
                        
                        TG_BOT_TOKEN_NEW="$TOKEN_RECEIVED"
                        
                        # Запрос ссылки на скрипт
                        send_telegram "Введите URL скрипта бота:"
                        URL_TIMEOUT=$((SECONDS + 300))  # 5 минут на ввод URL
                        URL_RECEIVED=""
                        
                        while [ $SECONDS -lt $URL_TIMEOUT ] && [ -z "$URL_RECEIVED" ]; do
                            URL_RESP=$(curl -s -m 10 "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
                            
                            if echo "$URL_RESP" | jq -e . >/dev/null 2>&1; then
                                URL_UPDATE=$(echo "$URL_RESP" | jq -r '.result[0]')
                                if [ "$URL_UPDATE" != "null" ]; then
                                    URL_TEXT=$(echo "$URL_UPDATE" | jq -r '.message.text // empty')
                                    if [ -n "$URL_TEXT" ]; then
                                        URL_CHAT_ID=$(echo "$URL_UPDATE" | jq -r '.message.chat.id')
                                        if [ "$URL_CHAT_ID" = "$CHAT_ID" ]; then
                                            URL_RECEIVED="$URL_TEXT"
                                            LAST_UPDATE_ID=$(echo "$URL_UPDATE" | jq -r '.update_id')
                                        fi
                                    fi
                                fi
                            fi
                            sleep 2
                        done
                        
                        if [ -z "$URL_RECEIVED" ]; then
                            send_telegram "⏰ Время ожидания URL истекло!"
                            exit 1
                        fi
                        
                        BOT_SCRIPT_URL="$URL_RECEIVED"
                        
                        # Скачивание и настройка бота
                        if curl -sLo /usr/local/bin/bot_script "$BOT_SCRIPT_URL"; then
                            chmod +x /usr/local/bin/bot_script
                            
                            # Создание сервиса
                            cat > /etc/systemd/system/tg-bot.service <<EOF
[Unit]
Description=Telegram Bot Service
After=network.target

[Service]
ExecStart=/usr/local/bin/bot_script $TG_BOT_TOKEN_NEW
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
                            
                            # Запуск сервиса
                            systemctl daemon-reload
                            systemctl enable tg-bot.service
                            systemctl start tg-bot.service
                            
                            # Самоудаление
                            systemctl disable first-boot.service
                            rm -f "$SELF_PATH" /etc/systemd/system/first-boot.service
                            systemctl daemon-reload
                            exit 0
                        else
                            send_telegram "❌ Ошибка скачивания скрипта бота!"
                            exit 1
                        fi
                        ;;
                esac
            fi
        fi
    done
    sleep 5
done

send_telegram "⏰ Время ожидания ответа истекло!"
exit 1
