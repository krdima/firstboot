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
    RESPONSE=$(curl -s "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
    UPDATES=$(echo "$RESPONSE" | jq -r '.result[]')
    
    while read -r UPDATE; do
        UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
        CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query')
        
        if [ "$UPDATE_ID" -gt "$LAST_UPDATE_ID" ]; then
            LAST_UPDATE_ID=$UPDATE_ID
            
            if [ "$CALLBACK" != "null" ]; then
                DATA=$(echo "$CALLBACK" | jq -r '.data')
                CB_CHAT_ID=$(echo "$CALLBACK" | jq -r '.message.chat.id')
                
                if [ "$CB_CHAT_ID" = "$CHAT_ID" ]; then
                    case $DATA in
                        "deny")
                            # Ответ на callback
                            CB_ID=$(echo "$CALLBACK" | jq -r '.id')
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
                            CB_ID=$(echo "$CALLBACK" | jq -r '.id')
                            curl -s -X POST "$API_URL/answerCallbackQuery" \
                                -d callback_query_id="$CB_ID"
                            
                            # Запрос нового токена
                            send_telegram "Введите новый токен бота:"
                            TOKEN_TIMEOUT=$((SECONDS + 300))  # 5 минут на ввод токена
                            
                            while [ $SECONDS -lt $TOKEN_TIMEOUT ]; do
                                TOKEN_RESP=$(curl -s "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
                                TOKEN_UPDATE=$(echo "$TOKEN_RESP" | jq -r '.result[0]')
                                
                                if [ "$TOKEN_UPDATE" != "null" ]; then
                                    MSG_TEXT=$(echo "$TOKEN_UPDATE" | jq -r '.message.text')
                                    MSG_CHAT_ID=$(echo "$TOKEN_UPDATE" | jq -r '.message.chat.id')
                                    
                                    if [ "$MSG_CHAT_ID" = "$CHAT_ID" ]; then
                                        TG_BOT_TOKEN_NEW="$MSG_TEXT"
                                        
                                        # Запрос ссылки на скрипт
                                        send_telegram "Введите URL скрипта бота:"
                                        URL_TIMEOUT=$((SECONDS + 300))  # 5 минут на ввод URL
                                        
                                        while [ $SECONDS -lt $URL_TIMEOUT ]; do
                                            URL_RESP=$(curl -s "$API_URL/getUpdates?offset=$((LAST_UPDATE_ID + 2))")
                                            URL_UPDATE=$(echo "$URL_RESP" | jq -r '.result[0]')
                                            
                                            if [ "$URL_UPDATE" != "null" ]; then
                                                BOT_SCRIPT_URL=$(echo "$URL_UPDATE" | jq -r '.message.text')
                                                
                                                # Скачивание и настройка бота
                                                curl -sLo /usr/local/bin/bot_script "$BOT_SCRIPT_URL"
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
                                            fi
                                            sleep 5
                                        done
                                        send_telegram "⏰ Время ожидания URL истекло!"
                                        exit 1
                                    fi
                                fi
                                sleep 5
                            done
                            send_telegram "⏰ Время ожидания токена истекло!"
                            exit 1
                            ;;
                    esac
                fi
            fi
        fi
    done <<< "$UPDATES"
    sleep 5
done

send_telegram "⏰ Время ожидания ответа истекло!"
exit 1
