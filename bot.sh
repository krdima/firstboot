#!/bin/bash

# Проверка наличия трех обязательных аргументов
if [ $# -ne 3 ]; then
    echo "Usage: $0 <FINGERPRINT> <TG_BOT_TOKEN> <CHAT_ID>"
    exit 1
fi

FINGERPRINT="$1"
TG_BOT_TOKEN="$2"
CHAT_ID="$3"
API_URL="https://api.telegram.org/bot$TG_BOT_TOKEN"
MAX_PASS_ATTEMPTS=5
WIFI_CONF_DIR="/etc/netplan"
SSH_PORT=22

# Установка необходимых пакетов
install_dependencies() {
    local pkgs=("curl" "jq" "net-tools" "iw" "wpasupplicant" "ufw" "nginx" "ansible")
    local missing=()
    
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Установка недостающих пакетов: ${missing[*]}"
        apt-get update
        apt-get install -y "${missing[@]}"
    fi
}

# Отправка сообщений в Telegram
send_message() {
    local text="$1"
    local markup="$2"
    local params=(-s -X POST "$API_URL/sendMessage" -d chat_id="$CHAT_ID" -d text="$text")
    
    [ -n "$markup" ] && params+=(-d reply_markup="$markup")
    
    curl "${params[@]}" > /dev/null
}

# Генерация inline-клавиатуры
generate_keyboard() {
    local keyboard='{"inline_keyboard":['
    local rows=()
    local row=()
    local count=0
    
    while [ $# -gt 0 ]; do
        row+=("{\"text\":\"$1\",\"callback_data\":\"$2\"}")
        shift 2
        ((count++))
        
        if [ $count -eq 2 ]; then
            rows+=("[${row[*]}]")
            row=()
            count=0
        fi
    done
    
    [ ${#row[@]} -gt 0 ] && rows+=("[${row[*]}]")
    keyboard+=$(IFS=,; echo "${rows[*]}")
    keyboard+=']}'
    
    echo "$keyboard"
}

# Получение текущего состояния сети
get_network_info() {
    local local_ip=$(hostname -I | awk '{print $1}')
    local public_ip=$(curl -4 -s ifconfig.me --max-time 5 || echo "N/A")
    local iface=$(ip route | awk '/default/ {print $5}')
    local iface_type="Unknown"
    
    # Точное определение типа интерфейса
    if [[ -d "/sys/class/net/$iface/wireless" ]]; then
        iface_type="Wi-Fi"
    else
        iface_type="Ethernet"
    fi
    
    echo "$local_ip|$public_ip|$iface_type|$iface"
}

# Сканирование Wi-Fi интерфейсов
scan_wifi_interfaces() {
    for iface in /sys/class/net/*; do
        if [ -d "$iface/wireless" ]; then
            basename "$iface"
        fi
    done
}

# Сканирование доступных сетей wlp6s0
scan_wifi_networks() {
    local iface="$1"
    
    # Включаем интерфейс
    if ! ip link set dev "$iface" up; then
        echo "ERR|Не удалось включить интерфейс $iface"
        return 1
    fi
    
    # Ждем активации
    sleep 10
    
    # Проверяем статус
    #local iface_status
    #iface_status=$(ip -o link show "$iface" | awk '{print $9}')
    #if [ "$iface_status" != "UP" ]; then
    #    echo "ERR|Интерфейс $iface остался в состоянии DOWN"
    #    return 1
    #fi
    
    # Сканируем сети с таймаутом
    local scan_result
    scan_result=$(timeout 30 iw dev "$iface" scan 2>&1)
    
    if [[ "$scan_result" == *"command failed"* ]]; then
        echo "ERR|Ошибка сканирования: ${scan_result##*: }"
        return 1
    fi
    
    # Обрабатываем результаты
    local networks
    networks=$(echo "$scan_result" | \
        awk -F ':' '/SSID:/ {ssid=substr($0, index($0,":")+2; gsub(/^[ \t]+|[ \t]+$/, "", ssid)} 
                   /signal:/ {signal=$2; gsub(/^[ \t]+|[ \t]+$/, "", signal); print signal "|" ssid}' | \
        sort -nr -t'|' -k1 | \
        head -n 6)
    
    if [ -z "$networks" ]; then
        echo "ERR|Не найдено доступных сетей"
        return 1
    fi
    
    echo "$networks"
}

# Подключение к Wi-Fi сети
connect_to_wifi() {
    local iface="$1"
    local ssid="$2"
    local password="$3"
    local conf_file="$WIFI_CONF_DIR/99-wifi-config.yaml"
    
    # Генерация конфигурации Netplan
    cat > "$conf_file" <<EOL
network:
  version: 2
  renderer: networkd
  wifis:
    $iface:
      dhcp4: true
      access-points:
        "$ssid":
          password: "$password"
EOL
    
    # Применение конфигурации
    if netplan apply; then
        return 0
    else
        rm -f "$conf_file"
        return 1
    fi
}

# Настройка DuckDNS
setup_duckdns() {
    local token="$1"
    local domain="$2"
    local cron_job="*/5 * * * * curl -s 'https://www.duckdns.org/update?domains=$domain&token=$token&ip=' >/dev/null"
    
    # Добавление задачи в cron
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
}

# Управление SSH портом
manage_ssh_port() {
    local action="$1"
    
    if [ "$action" == "open" ]; then
        ufw allow $SSH_PORT
    else
        ufw delete allow $SSH_PORT
    fi
    ufw reload
}

# Основное меню бота
show_main_menu() {
    local menu=(
        "📡 Получить IP/порты" "get_info"
        "🦆 Настроить DuckDNS" "setup_duckdns"
        "⚙️ Настроить Ansible" "setup_ansible"
        "🔐 Управление SSH" "manage_ssh"
        "⛔ Выключить бота" "shutdown"
    )
    
    local keyboard=$(generate_keyboard "${menu[@]}")
    send_message "Выберите действие:" "$keyboard"
}

# Обработка callback-запросов
process_callback() {
    local callback_data="$1"
    local message_id="$2"
    
    case $callback_data in
        get_info)
            local info_str=$(get_network_info)
            IFS='|' read -r local_ip public_ip iface_type iface <<< "$info_str"
            local ports=$(ss -tuln)
            send_message "📡 Сетевая информация:\n- Локальный IP: $local_ip\n- Внешний IP: $public_ip\n- Тип подключения: $iface_type\n- Интерфейс: $iface\n\n🔓 Открытые порты:\n$ports" ""
            ;;
            
        setup_duckdns)
            send_message "Введите токен и домен DuckDNS в формате: <токен> <домен>\nПример: abcdef12-1234-5678 mydomain.duckdns.org" ""
            ;;
            
        setup_ansible)
            send_message "Настройка Ansible роли...\nИмитация: git clone <repo> && ansible-playbook setup.yml" ""
            ;;
            
        manage_ssh)
            local keyboard=$(generate_keyboard "Открыть порт $SSH_PORT" "ssh_open" "Закрыть порт $SSH_PORT" "ssh_close")
            send_message "Управление SSH портом:" "$keyboard"
            ;;
            
        ssh_open|ssh_close)
            manage_ssh_port "${callback_data#ssh_}"
            send_message "Порт SSH $SSH_PORT ${callback_data#ssh_}!" ""
            ;;
            
        shutdown)
            send_message "🛑 Бот выключается..." ""
            exit 0
            ;;
            
        wifi_iface_*)
            local iface="${callback_data#wifi_iface_}"
            local networks=$(scan_wifi_networks "$iface")
            
            # Проверка на ошибки
            if [[ "$networks" == ERR* ]]; then
                send_message "❌ ${networks#ERR|}" ""
                show_main_menu
                return 0
            fi
            
            # Формируем клавиатуру с сетями
            local net_options=()
            while IFS='|' read -r signal ssid; do
                # Убираем лишние пробелы
                clean_ssid=$(echo "$ssid" | xargs)
                net_options+=("$clean_ssid ($signal dBm)" "wifi_net_${clean_ssid}")
            done <<< "$networks"
            
            # Сохраняем интерфейс для последующего использования
            echo "$iface" > /tmp/wifi_iface_$CHAT_ID
            
            local keyboard=$(generate_keyboard "${net_options[@]}")
            send_message "Выберите сеть:" "$keyboard"
            ;;
            
        wifi_net_*)
            local ssid="${callback_data#wifi_net_}"
            # Сохраняем SSID для последующего использования
            echo "$ssid" > /tmp/wifi_ssid_$CHAT_ID
            send_message "Введите пароль для сети \"$ssid\":" ""
            ;;
    esac
}

# Главная функция
main() {
    install_dependencies
    
    # Начальная информация о сети
    local info_str=$(get_network_info)
    IFS='|' read -r local_ip public_ip iface_type iface <<< "$info_str"
    send_message "🤖 Бот запущен!\n- Отпечаток: $FINGERPRINT\n- Локальный IP: $local_ip\n- Внешний IP: $public_ip\n- Тип подключения: $iface_type\n- Интерфейс: $iface" ""
    
    # Если подключение по Ethernet, сканируем Wi-Fi интерфейсы
    if [[ "$iface_type" == "Ethernet" ]]; then
        local ifaces=($(scan_wifi_interfaces))
        
        if [ ${#ifaces[@]} -gt 0 ]; then
            # Формируем кнопки с интерфейсами
            local iface_options=()
            for iface in "${ifaces[@]}"; do
                iface_options+=("$iface" "wifi_iface_$iface")
            done
            
            local keyboard=$(generate_keyboard "${iface_options[@]}")
            send_message "Обнаружены Wi-Fi интерфейсы:" "$keyboard"
        fi
    fi
    
    # Основной цикл обработки сообщений
    local offset=0
    while true; do
        local updates=$(curl -s "$API_URL/getUpdates?offset=$offset&timeout=60")
        # Исправление ошибки "integer expression expected"
        local count=$(echo "$updates" | jq -r '.result | length' 2>/dev/null || echo 0)
        
        # Проверяем, что count - число
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
        
        if [ "$count" -gt 0 ]; then
            offset=$(echo "$updates" | jq -r '.result[-1].update_id' 2>/dev/null || echo 0)
            offset=$((offset + 1))
            
            for ((i=0; i<count; i++)); do
                local message=$(echo "$updates" | jq -r ".result[$i].message")
                local callback=$(echo "$updates" | jq -r ".result[$i].callback_query")
                
                if [ "$message" != "null" ]; then
                    local text=$(echo "$message" | jq -r '.text')
                    local chat_id=$(echo "$message" | jq -r '.chat.id')
                    
                    # Обработка текстовых команд
                    if [ "$text" == "/start" ]; then
                        show_main_menu
                    elif [[ "$text" =~ ^[a-zA-Z0-9\-]+\s+[a-zA-Z0-9\.\-]+ ]]; then
                        # DuckDNS данные
                        read token domain <<< "$text"
                        setup_duckdns "$token" "$domain"
                        send_message "✅ DuckDNS настроен для домена: $domain" ""
                        show_main_menu
                    elif [ -f "/tmp/wifi_ssid_$CHAT_ID" ]; then
                        # Попытка подключения к Wi-Fi
                        local ssid=$(cat "/tmp/wifi_ssid_$CHAT_ID")
                        local iface=$(cat "/tmp/wifi_iface_$CHAT_ID")
                        local password="$text"
                        
                        # Удаляем временные файлы
                        rm -f "/tmp/wifi_ssid_$CHAT_ID" "/tmp/wifi_iface_$CHAT_ID"
                        
                        send_message "⌛ Попытка подключения к $ssid..." ""
                        
                        if connect_to_wifi "$iface" "$ssid" "$password"; then
                            sleep 5  # Ждем применения настроек
                            local new_info_str=$(get_network_info)
                            IFS='|' read -r new_local_ip new_public_ip new_iface_type new_iface <<< "$new_info_str"
                            send_message "✅ Подключение установлено!\n- Локальный IP: $new_local_ip\n- Внешний IP: $new_public_ip" ""
                        else
                            send_message "❌ Ошибка подключения! Проверьте пароль и повторите попытку." ""
                        fi
                        show_main_menu
                    elif [ "$text" == "/menu" ]; then
                        show_main_menu
                    fi
                
                elif [ "$callback" != "null" ]; then
                    local data=$(echo "$callback" | jq -r '.data')
                    local chat_id=$(echo "$callback" | jq -r '.message.chat.id')
                    local msg_id=$(echo "$callback" | jq -r '.message.message_id')
                    
                    process_callback "$data" "$msg_id"
                fi
            done
        fi
    done
}

# Запуск основной функции
main