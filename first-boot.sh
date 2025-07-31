#!/bin/bash

# Проверка наличия трех обязательных аргументов
if [ $# -ne 3 ]; then
    echo "Usage: $0 <FINGERPRINT> <TG_BOT_TOKEN> <CHAT_ID>"
    exit 1
fi

FINGERPRINT="$1"
TG_BOT_TOKEN="$2"
CHAT_ID="$3"
GIT_REPO="https://github.com/krdima/firstboot.git"
GIT_BRANCH="main"
SCRIPT_NAME="bot.sh"
INSTALL_DIR="/root/"

mkdir -p /tmp/bot-update; 
cd /tmp/bot-update;
git clone --quiet --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" . >/dev/null 2>&1;
if [ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ] && [ -f "${SCRIPT_NAME}" ]; then
    current_hash=$(sha256sum "${INSTALL_DIR}/${SCRIPT_NAME}" | cut -d" " -f1);
    new_hash=$(sha256sum "${SCRIPT_NAME}" | cut -d" " -f1);
    if [ "$current_hash" != "$new_hash" ]; then
        echo "[Bot Service] Обновление скрипта обнаружено";
        cp -f "${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}";
        chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}";
    fi;
    elif [ -f "${SCRIPT_NAME}" ]; then
        cp -f "${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}";
        chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}";
    fi;
rm -rf /tmp/bot-update
fi

cd /root
./bot.sh "$FINGERPRINT" "$TG_BOT_TOKEN" "$CHAT_ID"