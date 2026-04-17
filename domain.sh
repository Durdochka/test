#!/bin/bash

set +o history

###########################################
#CONFIG
###########################################

LOG_FILE="/var/log/firststart.log"
DOMAIN_TEMPLATE="astra.local"
OU_DEFAULT="ou=astra.local,cn=orgunits,cn=accounts,dc=astra,dc=local"
ALDPRO_INSTALLER="/opt/rbta/aldpro/client/bin/aldpro-client-installer"
ALDPRO_PACKAGE="aldpro-client"
POST_JOIN_HOME="/home/astra"

#хранение учетных данных в скрипте небезопасно.
#для включения true и заполнить другие поля
AUTO_JOIN="false"
AUTO_USER=""
AUTO_PASS=""

###########################################
# COMMON FUNCTIONS
###########################################

#логирование
log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"
}

#функция для выхода с ошибкой
die() {
    log "ERROR" "$*"
    set -o history
    exit 1
}

#инициализация лог файла
init_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    fi
    log "INFO" "=== Запуск скрипта firststart ==="
}

#проверка рут прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Требуются права root. Запуск с sudo..."
        set -o history
        exec sudo bash -c "$(cat "$0"); set -o history"
    fi
}

has_gui() {
    [[ -n "${DISPLAY:-}" ]] && [[ -n "$(command -v zenity 2>/dev/null)" ]]
}

#установка zenity
ensure_zenity() {
    if has_gui && ! command -v zenity >/dev/null 2>&1; then
        log "INFO" "Установка zenity..."
        apt-get update >> "$LOG_FILE" 2>&1 || return 1
        apt-get install -y zenity >> "$LOG_FILE" 2>&1 || return 1
        log "INFO" "Zenity установлен"
    fi
    return 0
}

###########################################
# USER INTERACTION FUNCTIONS
###########################################

#запрос подтверждения
ask_yes_no() {
    local answer

    if has_gui; then
        zenity --question \
            --no-wrap \
            --text="Ввести этот ПК в домен ALDPro?\n\n- Да: запустить процесс ввода\n- Нет: пропустить и войти в систему\n\nЕсли пропустить, запрос будет повторен при следующем входе." \
            --ok-label="Да" \
            --cancel-label="Нет" \
            2>/dev/null
        return $?
    else
        echo ""
        echo "Ввести этот ПК в домен ALDPro?"
        echo "  y - запустить процесс ввода"
        echo "  n - пропустить и войти в систему"
        echo ""
        echo "Если пропустить, запрос будет повторен при следующем входе."
        echo ""
        read -rp "Выберите действие [y/N]: " answer

        case "${answer,,}" in
            y|yes|д|да) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

#получение имени хоста
get_hostname() {
    if has_gui; then
        HOSTNAME_NEW=$(zenity --entry \
            --title="Имя компьютера" \
            --text="Введите имя компьютера:" \
            --entry-text="$(hostname -s)" \
            2>/dev/null)
    else
        read -rp "Введите имя компьютера [$(hostname -s)]: " HOSTNAME_NEW
    fi

    HOSTNAME_NEW="${HOSTNAME_NEW:-$(hostname -s)}"

    if [[ ! "$HOSTNAME_NEW" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]; then
        log "ERROR" "Некорректное имя хоста: $HOSTNAME_NEW"
        return 1
    fi
}

#получение домена
get_domain() {
    if has_gui; then
        DOMAIN=$(zenity --entry \
            --title="Домен" \
            --text="Введите имя домена:" \
            --entry-text="$DOMAIN_TEMPLATE" \
            2>/dev/null)
    else
        read -rp "Введите имя домена [$DOMAIN_TEMPLATE]: " DOMAIN
    fi

    DOMAIN="${DOMAIN:-$DOMAIN_TEMPLATE}"
}

#получение учетных данных
get_credentials() {
    #используется автоматические учетные данные если прописано
    if [[ "$AUTO_JOIN" == "true" ]] && [[ -n "$AUTO_USER" ]] && [[ -n "$AUTO_PASS" ]]; then
        USERNAME="$AUTO_USER"
        PASSWORD="$AUTO_PASS"
        log "INFO" "Используются автоматические учетные данные"
        return 0
    fi

    if has_gui; then
        local creds
        creds=$(zenity --forms \
            --title="Учетные данные" \
            --text="Введите учетные данные администратора домена:" \
            --add-entry="Пользователь:" \
            --add-password="Пароль:" \
            --separator="|" \
            2>/dev/null)

        if [[ -z "$creds" ]]; then
            return 1
        fi

        USERNAME=$(echo "$creds" | cut -d'|' -f1)
        PASSWORD=$(echo "$creds" | cut -d'|' -f2)
    else
        set -o history
        read -rp "Введите имя пользователя домена: " USERNAME
        set +o history

        if [[ -z "$USERNAME" ]]; then
            return 1
        fi

        echo -n "Введите пароль: "
        set +o history
        IFS= read -rs PASSWORD
        echo
        set -o history

        if [[ -z "$PASSWORD" ]]; then
            return 1
        fi
    fi

    [[ -n "$USERNAME" && -n "$PASSWORD" ]]
}

###########################################
# SYSTEM OPERATIONS
###########################################

#установка AldPro
install_aldpro() {
    log "INFO" "Обновление репозиториев..."
    if ! apt-get update >> "$LOG_FILE" 2>&1; then
        die "Ошибка обновления репозиториев"
    fi

    log "INFO" "Установка $ALDPRO_PACKAGE..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -q "$ALDPRO_PACKAGE" >> "$LOG_FILE" 2>&1; then
        die "Ошибка установки $ALDPRO_PACKAGE"
    fi

    if [[ ! -x "$ALDPRO_INSTALLER" ]]; then
        die "Установщик не найден: $ALDPRO_INSTALLER"
    fi

    log "INFO" "$ALDPRO_PACKAGE успешно установлен"
}

#обновление hostname и /etc/hosts
update_hosts() {
    local current_hostname
    current_hostname=$(hostname -s)

    log "INFO" "Обновление имени хоста на ${HOSTNAME_NEW}.${DOMAIN}"

    cp /etc/hosts "/etc/hosts.backup.$(date +%s)" 2>/dev/null

    #/etc/hosts
    if grep -q "^127\.0\.1\.1\s" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1\s.*$/127.0.1.1\t${HOSTNAME_NEW}.${DOMAIN}\t${HOSTNAME_NEW}/" /etc/hosts
    else
        echo -e "127.0.1.1\t${HOSTNAME_NEW}.${DOMAIN}\t${HOSTNAME_NEW}" >> /etc/hosts
    fi

    #hostname
    if ! hostnamectl set-hostname "${HOSTNAME_NEW}.${DOMAIN}"; then
        log "ERROR" "Ошибка установки hostname"
        return 1
    fi

    log "INFO" "Имя хоста обновлено"
}

#ввод в домен
secure_join_domain() {
    local join_result

    log "INFO" "Ввод компьютера в домен $DOMAIN..."

    #ввод в домен
    "$ALDPRO_INSTALLER" \
        --domain "$DOMAIN" \
        --account "$USERNAME" \
        --password "$PASSWORD" \
        --host "$HOSTNAME_NEW" \
        --gui \
        --force \
        --orgunits "$OU_DEFAULT" \
        >> "$LOG_FILE" 2>&1

    join_result=$?
    unset PASSWORD

    return $join_result
}

#настройка sssd
update_sssd() {
    local sssd_conf="/etc/sssd/sssd.conf"

    if [[ ! -f "$sssd_conf" ]]; then
        log "WARN" "Файл SSSD конфигурации не найден: $sssd_conf"
        return 0
    fi

    log "INFO" "Настройка SSSD..."

    cp "$sssd_conf" "${sssd_conf}.backup.$(date +%s)" 2>/dev/null

    if grep -q "krb5_store_password_if_offline = True" "$sssd_conf"; then
        if ! grep -q "dyndns_update = True" "$sssd_conf"; then
            sed -i '/krb5_store_password_if_offline = True/a dyndns_update = True' "$sssd_conf"
        fi
        if ! grep -q "dyndns_update_ptr = True" "$sssd_conf"; then
            sed -i '/dyndns_update = True/a dyndns_update_ptr = True' "$sssd_conf"
        fi
        if ! grep -q "dyndns_refresh_interval = 60" "$sssd_conf"; then
            sed -i '/dyndns_update_ptr = True/a dyndns_refresh_interval = 60' "$sssd_conf"
        fi

        if systemctl is-active sssd >/dev/null 2>&1; then
            systemctl restart sssd >> "$LOG_FILE" 2>&1
            log "INFO" "SSSD перезапущен"
        fi
    fi

    log "INFO" "SSSD настроен"
}

finalize() {
    log "INFO" "Выполнение завершающих действий..."

    #создание домашней директории
    if [[ ! -d "$POST_JOIN_HOME" ]]; then
        mkdir -p "$POST_JOIN_HOME"
        chmod 755 "$POST_JOIN_HOME"
        log "INFO" "Создана директория: $POST_JOIN_HOME"
    fi

    #удаляем скрипт автозапуска
    local autostart_script="/etc/profile.d/firststart.sh"
    if [[ -f "$autostart_script" ]]; then
        rm -f "$autostart_script"
        log "INFO" "Удален скрипт автозапуска: $autostart_script"
    fi

    log "SUCCESS" "ПК успешно введен в домен $DOMAIN"

    #запрос на перезагрузку
    if has_gui; then
        zenity --info \
            --no-wrap \
            --text="ПК успешно введен в домен $DOMAIN\n\nДля применения изменений требуется перезагрузка.\n\nНажмите OK для перезагрузки." \
            --ok-label="Перезагрузить" \
            2>/dev/null || true
    else
        echo ""
        echo "========================================"
        echo "ПК успешно введен в домен $DOMAIN"
        echo "Для применения изменений требуется перезагрузка"
        echo ""
        read -rp "Нажмите Enter для перезагрузки..."
    fi

    log "INFO" "Инициирована перезагрузка системы"

    set -o history

    reboot
}

###########################################
# MAIN
###########################################

main() {
    init_log
    check_root

    log "INFO" "Текущий пользователь: $(whoami)"
    log "INFO" "Текущий hostname: $(hostname)"

    if has_gui; then
        ensure_zenity || log "WARN" "Не удалось установить zenity"
    fi

    #запрос подтверждения
    if ! ask_yes_no; then
        log "INFO" "Пользователь отказался от ввода в домен"
        set -o history
        exit 0
    fi

    install_aldpro

    #получение данных
    if ! get_hostname; then
        die "Ошибка получения имени хоста"
    fi

    get_domain
    log "INFO" "Выбран домен: $DOMAIN"

    if ! get_credentials; then
        die "Не указаны учетные данные"
    fi

    #обновление системных настроек
    if ! update_hosts; then
        die "Ошибка обновления hostname"
    fi

    #ввод в домен
    if ! secure_join_domain; then
        die "Ошибка ввода в домен. Проверьте логи: $LOG_FILE"
    fi

    #доп настройка
    update_sssd

    finalize
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    #обработка ошибок
    trap 'set -o history; log "ERROR" "Скрипт завершился с ошибкой (строка: $LINENO, код: $?)"' ERR

    main "$@"

    set -o history
fi
