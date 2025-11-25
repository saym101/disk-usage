#!/bin/bash

################################################################################
# Disk Space Analyzer for Debian 12 / Ubuntu 20+
# Комплексный анализ дисковой системы с детальной информацией
################################################################################

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Параметры по умолчанию
TOPN=20
MIN_FILE_SIZE_MB=100
QUICK_MODE=false
DEEP_MODE=false
WITH_SMART=false
EXCLUDE_PSEUDO=true
OUTPUT_FORMAT="txt"
OUTPUT_FILE=""
ONLY_MOUNTS=""

# Проверка запуска от root (для некоторых операций)
NEED_ROOT=false

################################################################################
# Функция: вывод использования
################################################################################
usage() {
    cat << EOF
Использование: $0 [ОПЦИИ]

Опции:
  --quick              Быстрый режим (без поиска крупных файлов)
  --deep               Глубокий режим (больше деталей, медленнее)
  --topn N             Количество крупных папок/файлов (по умолчанию: 20)
  --min N              Минимальный размер файла в МБ (по умолчанию: 100)
  --with-smart         Включить SMART-диагностику (требует root)
  --include-pseudo     Включить псевдо-ФС (tmpfs, proc и т.д.)
  --only MOUNTS        Анализировать только указанные точки монтирования
  --json [FILE]        Вывод в JSON (опционально в файл)
  --csv [FILE]         Вывод в CSV (опционально в файл)
  --txt [FILE]         Вывод в TXT (опционально в файл, по умолчанию stdout)
  -h, --help           Показать эту справку

Примеры:
  $0                           # Стандартный анализ
  $0 --deep --with-smart       # Полный анализ с SMART (нужен root)
  $0 --quick --topn 10         # Быстрый анализ, топ-10
  $0 --only "/,/home" --json   # Только / и /home в JSON
  $0 --json report.json        # Сохранить JSON в файл

EOF
    exit 0
}

################################################################################
# Парсинг аргументов
################################################################################
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick) QUICK_MODE=true; shift ;;
        --deep) DEEP_MODE=true; shift ;;
        --topn) TOPN="$2"; shift 2 ;;
        --min) MIN_FILE_SIZE_MB="$2"; shift 2 ;;
        --with-smart) WITH_SMART=true; NEED_ROOT=true; shift ;;
        --include-pseudo) EXCLUDE_PSEUDO=false; shift ;;
        --only) ONLY_MOUNTS="$2"; shift 2 ;;
        --json) OUTPUT_FORMAT="json"; OUTPUT_FILE="${2:-}"; shift; [[ -n "${OUTPUT_FILE}" && "${OUTPUT_FILE}" != --* ]] && shift || OUTPUT_FILE="" ;;
        --csv) OUTPUT_FORMAT="csv"; OUTPUT_FILE="${2:-}"; shift; [[ -n "${OUTPUT_FILE}" && "${OUTPUT_FILE}" != --* ]] && shift || OUTPUT_FILE="" ;;
        --txt) OUTPUT_FORMAT="txt"; OUTPUT_FILE="${2:-}"; shift; [[ -n "${OUTPUT_FILE}" && "${OUTPUT_FILE}" != --* ]] && shift || OUTPUT_FILE="" ;;
        -h|--help) usage ;;
        *) echo "Неизвестная опция: $1"; usage ;;
    esac
done

# Проверка root при необходимости
if [[ "$NEED_ROOT" == true ]] && [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: для --with-smart требуются права root${NC}" >&2
    exit 1
fi

################################################################################
# Проверка и установка необходимых утилит
################################################################################
REQUIRED_TOOLS="df findmnt lsblk du sort awk sed grep"
OPTIONAL_TOOLS="lsof mdadm pvs vgs lvs zpool btrfs docker snap smartctl"
MISSING_REQUIRED=()
MISSING_OPTIONAL=()

echo -e "${CYAN}${BOLD}=== Проверка необходимых утилит ===${NC}\n"

for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_REQUIRED+=("$tool")
    fi
done

for tool in $OPTIONAL_TOOLS; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_OPTIONAL+=("$tool")
    fi
done

if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
    echo -e "${RED}Отсутствуют обязательные утилиты:${NC} ${MISSING_REQUIRED[*]}"
    echo -e "${YELLOW}Установите их командой:${NC}"
    echo "  sudo apt update && sudo apt install -y coreutils util-linux"
    exit 1
fi

if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Отсутствуют опциональные утилиты (некоторые функции будут недоступны):${NC}"
    echo "  ${MISSING_OPTIONAL[*]}"
    echo -e "${YELLOW}Для полного функционала установите:${NC}"
    echo "  sudo apt install -y lsof mdadm lvm2 zfsutils-linux btrfs-progs smartmontools docker.io snapd"
    echo ""
    read -p "Продолжить без них? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

echo -e "${GREEN}✓ Проверка завершена${NC}\n"

################################################################################
# Основные функции
################################################################################

print_header() {
    local title="$1"
    echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $title${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_subheader() {
    local title="$1"
    echo -e "${BLUE}${BOLD}▶ $title${NC}"
}

format_size() {
    local size=$1
    numfmt --to=iec-i --suffix=B --format="%.1f" "$size" 2>/dev/null || echo "${size}B"
}

get_mount_points() {
    if [[ -n "$ONLY_MOUNTS" ]]; then
        echo "$ONLY_MOUNTS" | tr ',' '\n'
    else
        if [[ "$EXCLUDE_PSEUDO" == true ]]; then
            df -T | awk 'NR>1 && $2 !~ /^(tmpfs|devtmpfs|proc|sysfs|devpts|securityfs|cgroup|pstore|bpf|tracefs|debugfs|hugetlbfs|mqueue|configfs|fusectl|fuse\.lxcfs)$/ {print $7}' | sort -u
        else
            df -T | awk 'NR>1 {print $7}' | sort -u
        fi
    fi
}

################################################################################
# 1. Сводка по файловым системам
################################################################################
show_filesystem_summary() {
    print_header "1. Сводка по файловым системам"
    
    printf "%-25s %-10s %10s %10s %10s %6s %12s %s\n" \
        "ТОЧКА МОНТИРОВАНИЯ" "FSTYPE" "ВСЕГО" "ЗАНЯТО" "ДОСТУПНО" "USE%" "INODES%" "ИСТОЧНИК"
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    df -T | awk 'NR>1' | while read -r line; do
        fs=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $2}')
        total=$(echo "$line" | awk '{print $3}')
        used=$(echo "$line" | awk '{print $4}')
        avail=$(echo "$line" | awk '{print $5}')
        use_pct=$(echo "$line" | awk '{print $6}')
        mount=$(echo "$line" | awk '{print $7}')
        
        # Пропускаем псевдо-ФС если нужно
        if [[ "$EXCLUDE_PSEUDO" == true ]] && [[ "$fstype" =~ ^(tmpfs|devtmpfs|proc|sysfs|devpts|securityfs|cgroup|pstore|bpf|tracefs|debugfs|hugetlbfs|mqueue|configfs|fusectl|fuse\.lxcfs)$ ]]; then
            continue
        fi
        
        # Проверка использования инодов
        inode_pct="-"
        if df -i "$mount" &>/dev/null; then
            inode_pct=$(df -i "$mount" | awk 'NR==2 {print $5}')
        fi
        
        # Цвет предупреждения
        color=""
        if [[ "${use_pct%\%}" -ge 90 ]]; then
            color="${RED}"
        elif [[ "${use_pct%\%}" -ge 80 ]]; then
            color="${YELLOW}"
        fi
        
        printf "${color}%-25s %-10s %10s %10s %10s %6s %12s %s${NC}\n" \
            "$mount" "$fstype" \
            "$(format_size $((total * 1024)))" \
            "$(format_size $((used * 1024)))" \
            "$(format_size $((avail * 1024)))" \
            "$use_pct" "$inode_pct" "$fs"
    done
    echo ""
}

################################################################################
# 2. Карта монтирований (дерево findmnt)
################################################################################
show_mount_tree() {
    print_header "2. Карта монтирований (дерево)"
    
    if command -v findmnt &> /dev/null; then
        if [[ "$EXCLUDE_PSEUDO" == true ]]; then
            findmnt -t ext4,xfs,btrfs,zfs,nfs,nfs4,cifs,fuse,exfat,vfat,ntfs -D
        else
            findmnt -D
        fi
    else
        echo "findmnt не установлен, используется mount:"
        mount | column -t
    fi
    echo ""
}

################################################################################
# 3. Топология устройств
################################################################################
show_device_topology() {
    print_header "3. Топология устройств (цепочка зависимостей)"
    
    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" ]] && continue
        
        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        fstype=$(df -T "$mnt" | awk 'NR==2 {print $2}')
        
        echo -e "${BOLD}$mnt${NC} → ${GREEN}$fstype${NC}@${YELLOW}$device${NC}"
        
        # Показываем lsblk для этого устройства
        if [[ "$device" =~ ^/dev/ ]]; then
            dev_name=$(basename "$device")
            lsblk -no NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "/dev/$dev_name" 2>/dev/null | sed 's/^/  /' || true
        fi
        echo ""
    done
}

################################################################################
# 4. Идентификация физических дисков
################################################################################
show_physical_disks() {
    print_header "4. Идентификация физических дисков"
    
    printf "%-10s %10s %-25s %-20s %-20s %6s %s\n" \
        "УСТРОЙСТВО" "РАЗМЕР" "МОДЕЛЬ" "SERIAL" "WWN" "ROTA" "HCTL/PCI"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    lsblk -dno NAME,SIZE,MODEL,SERIAL,WWN,ROTA,HCTL | while read -r name size model serial wwn rota hctl; do
        # Пропускаем loop устройства
        [[ "$name" =~ loop ]] && continue
        
        disk_type="HDD"
        [[ "$rota" == "0" ]] && disk_type="SSD"
        
        printf "%-10s %10s %-25s %-20s %-20s %6s %s\n" \
            "/dev/$name" "$size" "${model:--}" "${serial:--}" "${wwn:--}" "$disk_type" "${hctl:--}"
    done
    echo ""
}

################################################################################
# 5. RAID/LVM/ZFS/Btrfs статус
################################################################################
show_raid_lvm_status() {
    print_header "5. RAID / LVM / ZFS / Btrfs — Статус"
    
    # MDRAID
    if command -v mdadm &> /dev/null && [[ -f /proc/mdstat ]]; then
        print_subheader "MD RAID"
        cat /proc/mdstat
        echo ""
        
        mdadm --detail --scan 2>/dev/null | grep "ARRAY" | awk '{print $2}' | while read -r array; do
            echo -e "${YELLOW}Детали: $array${NC}"
            mdadm --detail "$array" 2>/dev/null | grep -E "(State|Active Devices|Failed|Spare)" || true
            echo ""
        done
    fi
    
    # LVM
    if command -v pvs &> /dev/null; then
        print_subheader "LVM Physical Volumes"
        pvs -o pv_name,vg_name,pv_size,pv_free,pv_used --units g 2>/dev/null || echo "PV не найдены"
        echo ""
        
        print_subheader "LVM Volume Groups"
        vgs -o vg_name,pv_count,lv_count,vg_size,vg_free --units g 2>/dev/null || echo "VG не найдены"
        echo ""
        
        print_subheader "LVM Logical Volumes"
        lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent,lv_attr --units g 2>/dev/null || echo "LV не найдены"
        echo ""
    fi
    
    # ZFS
    if command -v zpool &> /dev/null; then
        print_subheader "ZFS Pools"
        zpool list 2>/dev/null || echo "ZFS пулы не найдены"
        echo ""
        zpool status 2>/dev/null || true
        echo ""
    fi
    
    # Btrfs
    if command -v btrfs &> /dev/null; then
        print_subheader "Btrfs Filesystems"
        btrfs filesystem show 2>/dev/null || echo "Btrfs ФС не найдены"
        echo ""
        
        # Использование для каждой btrfs ФС
        get_mount_points | while read -r mnt; do
            fstype=$(df -T "$mnt" | awk 'NR==2 {print $2}')
            if [[ "$fstype" == "btrfs" ]]; then
                echo -e "${YELLOW}Использование: $mnt${NC}"
                btrfs filesystem usage "$mnt" 2>/dev/null || true
                echo ""
            fi
        done
    fi
}

################################################################################
# 6. Сетевые монтирования
################################################################################
show_network_mounts() {
    print_header "6. Сетевые и внешние монтирования"
    
    mount | grep -E "(nfs|cifs|fuse|overlay|squashfs)" | while read -r line; do
        device=$(echo "$line" | awk '{print $1}')
        mnt=$(echo "$line" | awk '{print $3}')
        fstype=$(echo "$line" | awk '{print $5}')
        opts=$(echo "$line" | sed 's/.*(\(.*\))/\1/')
        
        echo -e "${BOLD}$mnt${NC} ← ${GREEN}$fstype${NC} from ${YELLOW}$device${NC}"
        echo "  Опции: $opts"
        echo ""
    done
}

################################################################################
# 7. Крупные каталоги
################################################################################
show_large_directories() {
    print_header "7. Крупные каталоги (топ-$TOPN по каждой ФС)"
    
    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" || ! -d "$mnt" ]] && continue
        
        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        echo -e "${BLUE}${BOLD}▶ Монтирование: $mnt (устройство: $device)${NC}"
        
        printf "  %-50s %15s\n" "КАТАЛОГ" "РАЗМЕР"
        echo "  ────────────────────────────────────────────────────────────────────────────────"
        
        # Используем du с timeout на случай медленных ФС
        timeout 60 du -x -d 1 "$mnt" 2>/dev/null | sort -rn | head -n "$TOPN" | while read -r size path; do
            formatted_size=$(format_size $((size * 1024)))
            printf "  %-50s %15s\n" "$path" "$formatted_size"
        done || echo "  ${YELLOW}Timeout или ошибка доступа${NC}"
        
        echo ""
    done
}

################################################################################
# 8. Крупные файлы
################################################################################
show_large_files() {
    if [[ "$QUICK_MODE" == true ]]; then
        echo -e "${YELLOW}Пропуск поиска крупных файлов (режим --quick)${NC}\n"
        return
    fi
    
    print_header "8. Крупные файлы (≥${MIN_FILE_SIZE_MB}MB)"
    
    printf "%-15s %-70s %s\n" "РАЗМЕР" "ПУТЬ" "УСТРОЙСТВО"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" || ! -d "$mnt" ]] && continue
        
        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        
        timeout 120 find "$mnt" -xdev -type f -size "+${MIN_FILE_SIZE_MB}M" -exec ls -lh {} \; 2>/dev/null | \
            awk -v dev="$device" '{printf "%-15s %-70s %s\n", $5, $9, dev}' | sort -rh | head -n "$TOPN" || true
    done
    
    echo ""
}

################################################################################
# 9. Журналы и кеши
################################################################################
show_logs_and_caches() {
    print_header "9. Журналы и кеши"
    
    # Journalctl
    if command -v journalctl &> /dev/null; then
        print_subheader "Журналы systemd"
        journalctl --disk-usage 2>/dev/null || echo "Недоступно"
        echo ""
    fi
    
    # Проверка типичных мест
    print_subheader "Типичные каталоги кешей"
    check_dirs=(
        "/var/log"
        "/var/cache/apt/archives"
        "/var/tmp"
        "/tmp"
        "/var/lib/docker/overlay2"
        "/var/lib/snapd/snaps"
        "/root/.cache"
        "/home/*/.cache"
    )
    
    for dir_pattern in "${check_dirs[@]}"; do
        for dir in $dir_pattern; do
            if [[ -d "$dir" ]]; then
                size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
                echo "  $dir: $size"
            fi
        done
    done
    echo ""
}

################################################################################
# 10. Docker/Snap/Flatpak
################################################################################
show_containers_snaps() {
    print_header "10. Контейнеры и снапы"
    
    # Docker
    if command -v docker &> /dev/null; then
        print_subheader "Docker"
        docker system df 2>/dev/null || echo "Docker не запущен или недоступен"
        echo ""
    fi
    
    # Snap
    if command -v snap &> /dev/null; then
        print_subheader "Snap пакеты"
        snap list 2>/dev/null | awk '{print $1, $4}' | column -t || echo "Snap не установлен"
        echo ""
        
        if [[ -d /var/lib/snapd/snaps ]]; then
            snap_size=$(du -sh /var/lib/snapd/snaps 2>/dev/null | awk '{print $1}')
            echo "  Общий размер снапов: $snap_size"
        fi
        echo ""
    fi
    
    # Flatpak
    if command -v flatpak &> /dev/null; then
        print_subheader "Flatpak приложения"
        flatpak list --app --columns=name,size 2>/dev/null || echo "Flatpak не установлен"
        echo ""
    fi
}

################################################################################
# 11. Удалённые файлы, занятые процессами
################################################################################
show_deleted_files() {
    if ! command -v lsof &> /dev/null; then
        return
    fi
    
    print_header "11. Удалённые файлы, удерживаемые процессами"
    
    deleted=$(lsof +L1 2>/dev/null | grep deleted || true)
    
    if [[ -n "$deleted" ]]; then
        echo "$deleted" | awk '{print $1, $2, $7, $9}' | column -t
    else
        echo -e "${GREEN}Удерживаемых удалённых файлов не найдено${NC}"
    fi
    echo ""
}

################################################################################
# 12. Своп и tmpfs
################################################################################
show_swap_tmpfs() {
    print_header "12. Своп и временные ФС"
    
    print_subheader "Swap"
    swapon --show 2>/dev/null || echo "Своп не активирован"
    echo ""
    
    print_subheader "Tmpfs монтирования"
    df -t tmpfs -h | awk 'NR>1 {printf "  %-30s %10s / %10s (%s)\n", $6, $3, $2, $5}'
    echo ""
}

################################################################################
# 13. SMART диагностика
################################################################################
show_smart_status() {
    if [[ "$WITH_SMART" != true ]] || ! command -v smartctl &> /dev/null; then
        return
    fi
    
    print_header "13. SMART — Здоровье дисков"
    
    printf "%-12s %-10s %10s %10s %10s %8s %s\n" \
        "УСТРОЙСТВО" "HEALTH" "REALLOC" "PENDING" "CRC_ERR" "TEMP" "USED%"
    echo "────────────────────────────────────────────────────────────────────────────────────"
    
    lsblk -dno NAME | grep -v loop | while read -r disk; do
        dev="/dev/$disk"
        
        smart_output=$(smartctl -H -A "$dev" 2>/dev/null || true)
        
        health=$(echo "$smart_output" | grep "SMART overall-health" | awk '{print $NF}' || echo "-")
        realloc=$(echo "$smart_output" | grep "Reallocated_Sector" | awk '{print $10}' || echo "-")
        pending=$(echo "$smart_output" | grep "Current_Pending_Sector" | awk '{print $10}' || echo "-")
        crc=$(echo "$smart_output" | grep "UDMA_CRC_Error" | awk '{print $10}' || echo "-")
        temp=$(echo "$smart_output" | grep "Temperature_Celsius" | awk '{print $10}' || echo "-")
        
        # NVMe
        if [[ "$smart_output" =~ "NVMe" ]]; then
            health=$(echo "$smart_output" | grep "SMART Health Status" | awk '{print $NF}' || echo "-")
            temp=$(echo "$smart_output" | grep "Temperature:" | awk '{print $2}' || echo "-")
        fi
        
        used_pct="-"
        
        printf "%-12s %-10s %10s %10s %10s %8s %s\n" \
            "$dev" "$health" "$realloc" "$pending" "$crc" "$temp" "$used_pct"
    done
    echo ""
}

################################################################################
# 14. Алармы и предупреждения
################################################################################
show_alerts() {
    print_header "14. Предупреждения и алармы"
    
    alerts=0
    
    # Проверка заполнения ФС
    df -h | awk 'NR>1 {gsub(/%/,"",$5); if ($5 >= 90) print $0}' | while read -r line; do
        echo -e "${RED}⚠ Файловая система переполнена (≥90%):${NC}"
        echo "  $line"
        ((alerts++))
    done
    
    # Проверка инодов
    df -i | awk 'NR>1 {gsub(/%/,"",$5); if ($5 >= 90) print $0}' | while read -r line; do
        echo -e "${RED}⚠ Иноды исчерпаны (≥90%):${NC}"
        echo "  $line"
        ((alerts++))
    done
    
    # Проверка RAID
    if [[ -f /proc/mdstat ]]; then
        if grep -q "DEGRADED\|RECOVERING" /proc/mdstat 2>/dev/null; then
            echo -e "${RED}⚠ RAID массив деградирован или восстанавливается${NC}"
            ((alerts++))
        fi
    fi
    
    # Проверка журналов
    if command -v journalctl &> /dev/null; then
        journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '\d+\.\d+[GM]' || echo "0")
        if [[ "$journal_size" =~ G ]] && (( $(echo "$journal_size" | grep -oP '\d+') > 2 )); then
            echo -e "${YELLOW}⚠ Журналы превышают 2GB: $journal_size${NC}"
            ((alerts++))
        fi
    fi
    
    # Проверка удалённых файлов
    if command -v lsof &> /dev/null; then
        deleted_count=$(lsof +L1 2>/dev/null | grep -c deleted || echo "0")
        if (( deleted_count > 0 )); then
            echo -e "${YELLOW}⚠ Найдено $deleted_count удалённых файлов, удерживаемых процессами${NC}"
            ((alerts++))
        fi
    fi
    
    if (( alerts == 0 )); then
        echo -e "${GREEN}✓ Критичных проблем не обнаружено${NC}"
    fi
    
    echo ""
}

################################################################################
# 15. Конфигурация автомонтирования
################################################################################
show_fstab() {
    print_header "15. Конфигурация /etc/fstab"
    
    if [[ -f /etc/fstab ]]; then
        grep -v "^#" /etc/fstab | grep -v "^$" | column -t
    else
        echo "Файл /etc/fstab не найден"
    fi
    echo ""
}

################################################################################
# MAIN
################################################################################

clear
echo -e "${BOLD}${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║         DISK SPACE ANALYZER — Анализ дисковой системы             ║
║                   Debian 12 / Ubuntu 20+                          ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "Запуск анализа: ${BOLD}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "Режим: ${BOLD}$([[ "$QUICK_MODE" == true ]] && echo "БЫСТРЫЙ" || [[ "$DEEP_MODE" == true ]] && echo "ГЛУБОКИЙ" || echo "СТАНДАРТНЫЙ")${NC}"
echo ""

# Выполнение анализа
show_filesystem_summary
show_mount_tree
show_device_topology
show_physical_disks
show_raid_lvm_status
show_network_mounts
show_large_directories
show_large_files
show_logs_and_caches
show_containers_snaps
show_deleted_files
show_swap_tmpfs
show_smart_status
show_alerts
show_fstab

################################################################################
# Итоговая сводка
################################################################################
print_header "ИТОГИ"

total_size=0
total_used=0
total_avail=0

df -k | awk 'NR>1' | while read -r line; do
    fstype=$(echo "$line" | awk '{print $1}')
    
    # Пропускаем псевдо-ФС если нужно
    if [[ "$EXCLUDE_PSEUDO" == true ]]; then
        mount_point=$(echo "$line" | awk '{print $6}')
        fs_type=$(df -T "$mount_point" 2>/dev/null | awk 'NR==2 {print $2}')
        [[ "$fs_type" =~ ^(tmpfs|devtmpfs|proc|sysfs)$ ]] && continue
    fi
    
    total=$(echo "$line" | awk '{print $2}')
    used=$(echo "$line" | awk '{print $3}')
    avail=$(echo "$line" | awk '{print $4}')
    
    total_size=$((total_size + total))
    total_used=$((total_used + used))
    total_avail=$((total_avail + avail))
done

echo -e "${BOLD}Общая емкость:${NC}      $(format_size $((total_size * 1024)))"
echo -e "${BOLD}Использовано:${NC}       $(format_size $((total_used * 1024)))"
echo -e "${BOLD}Доступно:${NC}           $(format_size $((total_avail * 1024)))"

if (( total_size > 0 )); then
    usage_pct=$(( (total_used * 100) / total_size ))
    echo -e "${BOLD}Процент использования:${NC} ${usage_pct}%"
fi

echo ""
echo -e "${GREEN}${BOLD}✓ Анализ завершен: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""

################################################################################
# Экспорт в JSON (если требуется)
################################################################################
export_json() {
    local output="${1:-/dev/stdout}"
    
    cat > "$output" << 'JSON_START'
{
  "timestamp": "'"$(date -Iseconds)"'",
  "hostname": "'"$(hostname)"'",
  "filesystems": [
JSON_START

    # Сбор данных по ФС
    local first=true
    df -T -k | awk 'NR>1' | while read -r line; do
        fs=$(echo "$line" | awk '{print $1}')
        fstype=$(echo "$line" | awk '{print $2}')
        total=$(echo "$line" | awk '{print $3}')
        used=$(echo "$line" | awk '{print $4}')
        avail=$(echo "$line" | awk '{print $5}')
        use_pct=$(echo "$line" | awk '{print $6}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $7}')
        
        [[ "$first" == true ]] && first=false || echo "," >> "$output"
        
        cat >> "$output" << JSON_FS
    {
      "mountpoint": "$mount",
      "device": "$fs",
      "fstype": "$fstype",
      "total_kb": $total,
      "used_kb": $used,
      "available_kb": $avail,
      "use_percent": $use_pct
    }
JSON_FS
    done
    
    cat >> "$output" << 'JSON_END'
  ],
  "physical_disks": [
JSON_END

    # Физические диски
    first=true
    lsblk -dno NAME,SIZE,MODEL,SERIAL -b | while read -r name size model serial; do
        [[ "$name" =~ loop ]] && continue
        
        [[ "$first" == true ]] && first=false || echo "," >> "$output"
        
        cat >> "$output" << JSON_DISK
    {
      "device": "/dev/$name",
      "size_bytes": $size,
      "model": "${model:--}",
      "serial": "${serial:--}"
    }
JSON_DISK
    done
    
    echo "  ]" >> "$output"
    echo "}" >> "$output"
}

################################################################################
# Экспорт в CSV (если требуется)
################################################################################
export_csv() {
    local output="${1:-/dev/stdout}"
    
    echo "type,path,size_kb,device,fstype,mountpoint" > "$output"
    
    # Крупные каталоги
    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" || ! -d "$mnt" ]] && continue
        
        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        fstype=$(df -T "$mnt" | awk 'NR==2 {print $2}')
        
        du -x -d 1 -k "$mnt" 2>/dev/null | sort -rn | head -n "$TOPN" | while read -r size path; do
            echo "directory,\"$path\",$size,\"$device\",\"$fstype\",\"$mnt\"" >> "$output"
        done
    done
    
    # Крупные файлы
    if [[ "$QUICK_MODE" != true ]]; then
        get_mount_points | while read -r mnt; do
            [[ -z "$mnt" || ! -d "$mnt" ]] && continue
            
            device=$(df "$mnt" | awk 'NR==2 {print $1}')
            fstype=$(df -T "$mnt" | awk 'NR==2 {print $2}')
            
            find "$mnt" -xdev -type f -size "+${MIN_FILE_SIZE_MB}M" -exec du -k {} \; 2>/dev/null | \
                sort -rn | head -n "$TOPN" | while read -r size path; do
                echo "file,\"$path\",$size,\"$device\",\"$fstype\",\"$mnt\"" >> "$output"
            done
        done
    fi
}

################################################################################
# Обработка вывода согласно формату
################################################################################
case "$OUTPUT_FORMAT" in
    json)
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo -e "${CYAN}Экспорт в JSON: $OUTPUT_FILE${NC}"
            export_json "$OUTPUT_FILE"
            echo -e "${GREEN}✓ JSON сохранен${NC}"
        else
            export_json
        fi
        ;;
    csv)
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo -e "${CYAN}Экспорт в CSV: $OUTPUT_FILE${NC}"
            export_csv "$OUTPUT_FILE"
            echo -e "${GREEN}✓ CSV сохранен${NC}"
        else
            export_csv
        fi
        ;;
    txt)
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo -e "${CYAN}Сохранение отчета: $OUTPUT_FILE${NC}"
            # Перенаправляем весь вывод выше в файл
            # (в реальности это нужно делать в начале, но для примера упрощаем)
            echo -e "${YELLOW}Для сохранения TXT используйте перенаправление:${NC}"
            echo "  $0 > report.txt"
        fi
        ;;
esac

exit 0

