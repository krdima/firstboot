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
    local pkgs=("curl" "jq" "net-tools" "wireless-tools" "wpasupplicant" "ufw" "nginx" "ansible")
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
    local public_ip=$(curl -s ifconfig.me)
    local iface=$(ip route | awk '/default/ {print $5}')
    local iface_type="Wi-Fi"
    
    [[ $iface == eth* ]] && iface_type="Ethernet"
    
    echo "$local_ip|$public_ip|$iface_type|$iface"
}

# Сканирование Wi-Fi интерфейсов
scan_wifi_interfaces() {
    iw dev | awk '/Interface/ {print $2}' | grep -v "lo"
}

# Сканирование доступных сетей
scan_wifi_networks() {
    local iface="$1"
    iw dev "$iface" scan | \
        awk -F ':' '/SSID:/ {ssid=$2} /signal:/ {print $2 "|" ssid}' | \
        sort -nr | \
        head -n 6 | \
        awk -F '|' '{print $2 " (" $1 " dBm)"}' | \
        tr -d '\n'
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
            local info=($(get_network_info))
            local ports=$(ss -tuln)
            send_message "📡 Сетевая информация:\n- Локальный IP: ${info[0]}\n- Внешний IP: ${info[1]}\n- Тип подключения: ${info[2]}\n- Интерфейс: ${info[3]}\n\n🔓 Открытые порты:\n$ports" ""
            ;;
            
        setup_duckdns)
            send_message "Введите токен и домен DuckDNS в формате: <токен> <домен>\nПример: abcdef12-1234-5678 mydomain.duckdns.org" ""
            # Ожидаем ввода данных в следующем сообщении
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
            # Сохраняем выбранный интерфейс
            local iface="${callback_data#wifi_iface_}"
            # Сканируем сети
            local networks=$(scan_wifi_networks "$iface")
            IFS='|' read -ra net_array <<< "$networks"
            
            # Формируем клавиатуру с сетями
            local net_options=()
            for net in "${net_array[@]}"; do
                # Убираем лишние пробелы и dBm в тексте
                clean_net=$(echo "$net" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                net_options+=("$clean_net" "wifi_net_${clean_net%% *}")
            done
            
            local keyboard=$(generate_keyboard "${net_options[@]}")
            send_message "Выберите сеть:" "$keyboard"
            ;;
            
        wifi_net_*)
            # Сохраняем выбранную сеть
            local ssid="${callback_data#wifi_net_}"
            send_message "Введите пароль для сети \"$ssid\":" ""
            # Ожидаем ввода пароля
            ;;
    esac
}

# Главная функция
main() {
    install_dependencies
    
    # Начальная информация о сети
    local info=($(get_network_info))
    send_message "🤖 Бот запущен!\n- Отпечаток: $FINGERPRINT\n- Локальный IP: ${info[0]}\n- Внешний IP: ${info[1]}\n- Тип подключения: ${info[2]}" ""
    
    # Если подключение по Ethernet, сканируем Wi-Fi интерфейсы
    if [[ "${info[2]}" == "Ethernet" ]]; then
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
        local count=$(echo "$updates" | jq '.result | length')
        
        if [ "$count" -gt 0 ]; then
            offset=$(echo "$updates" | jq '.result[-1].update_id') 
            ((offset++))
            
            for ((i=0; i<count; i++)); do
                local message=$(echo "$updates" | jq -r ".result[$i].message")
                local callback=$(echo "$updates" | jq -r ".result[$i].callback_query")
                
                if [ "$message" != "null" ]; then
                    local text=$(echo "$message" | jq -r '.text')
                    local chat_id=$(echo "$message" | jq -r '.chat.id')
                    
                    # Обработка текстовых команд
                    if [ "$text" == "/start" ]; then
                        show_main_menu
                    elif [[ "$text" =~ ^[a-zA-Z0-9\-]+\.[a-zA-Z0-9\-]+ ]]; then
                        # DuckDNS данные
                        setup_duckdns $text
                        send_message "DuckDNS настроен для домена: $text" ""
                        show_main_menu
                    elif [ -n "$text" ]; then
                        # Попытка подключения к Wi-Fi
                        # Логика обработки пароля
                        send_message "Попытка подключения..." ""
                        # После подключения:
                        local new_info=($(get_network_info))
                        send_message "✅ Подключение установлено!\n- Локальный IP: ${new_info[0]}\n- Внешний IP: ${new_info[1]}" ""
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
