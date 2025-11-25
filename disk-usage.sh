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
        --json)
            OUTPUT_FORMAT="json"
            OUTPUT_FILE=""
            shift
            if [[ $# -gt 0 && "$1" != --* ]]; then
                OUTPUT_FILE="$1"
                shift
            fi
            ;;
        --csv)
            OUTPUT_FORMAT="csv"
            OUTPUT_FILE=""
            shift
            if [[ $# -gt 0 && "$1" != --* ]]; then
                OUTPUT_FILE="$1"
                shift
            fi
            ;;
        --txt)
            OUTPUT_FORMAT="txt"
            OUTPUT_FILE=""
            shift
            if [[ $# -gt 0 && "$1" != --* ]]; then
                OUTPUT_FILE="$1"
                shift
            fi
            ;;
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
OPTIONAL_TOOLS="lsof mdadm pvs vgs lvs btrfs docker snap smartctl"
declare -A TOOL_PACKAGE_MAP=(
    [lsof]="lsof"
    [mdadm]="mdadm"
    [pvs]="lvm2"
    [vgs]="lvm2"
    [lvs]="lvm2"
    [btrfs]="btrfs-progs"
    [docker]="docker.io"
    [snap]="snapd"
    [smartctl]="smartmontools"
)
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
    echo "  apt update && apt install -y coreutils util-linux"
    exit 1
fi

if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Отсутствуют опциональные утилиты (некоторые функции будут недоступны):${NC}"
    echo "  ${MISSING_OPTIONAL[*]}"
    echo -e "${YELLOW}Для полного функционала установите:${NC}"
    missing_packages=()
    for tool in "${MISSING_OPTIONAL[@]}"; do
        pkg=${TOOL_PACKAGE_MAP[$tool]-}
        [[ -z "$pkg" ]] && continue
        if [[ " ${missing_packages[*]} " != *" $pkg "* ]]; then
            missing_packages+=("$pkg")
        fi
    done

    available_packages=()
    unavailable_packages=()

    is_pkg_available() {
        local pkg="$1"
        local candidate
        candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk -F': ' '/Candidate:/ {print $2; exit}')
        [[ -n "$candidate" && "$candidate" != "(none)" ]]
    }

    for pkg in "${missing_packages[@]}"; do
        if is_pkg_available "$pkg"; then
            available_packages+=("$pkg")
        else
            unavailable_packages+=("$pkg")
        fi
    done

    if [[ ${#available_packages[@]} -gt 0 ]]; then
        echo "  apt install -y ${available_packages[*]}"
    fi
    if [[ ${#unavailable_packages[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Недоступные в текущих репозиториях:${NC} ${unavailable_packages[*]}"
        echo "  Добавьте нужные репозитории (например, contrib/non-free или backports) или установите пакеты вручную."
    fi
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

        if [[ "$EXCLUDE_PSEUDO" == true ]] && [[ "$fstype" =~ ^(tmpfs|devtmpfs|proc|sysfs|devpts|securityfs|cgroup|pstore|bpf|tracefs|debugfs|hugetlbfs|mqueue|configfs|fusectl|fuse\.lxcfs)$ ]]; then
            continue
        fi

        inode_pct="-"
        if df -i "$mount" &>/dev/null; then
            inode_pct=$(df -i "$mount" | awk 'NR==2 {print $5}')
        fi

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

show_mount_tree() {
    print_header "2. Карта монтирований (дерево)"

    if command -v findmnt &> /dev/null; then
        if [[ "$EXCLUDE_PSEUDO" == true ]]; then
            findmnt -t ext4,xfs,btrfs,nfs,nfs4,cifs,fuse,exfat,vfat,ntfs -D
        else
            findmnt -D
        fi
    else
        echo "findmnt не установлен, используется mount:"
        mount | column -t
    fi
    echo ""
}

show_device_topology() {
    print_header "3. Топология устройств (цепочка зависимостей)"

    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" ]] && continue

        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        fstype=$(df -T "$mnt" | awk 'NR==2 {print $2}')

        echo -e "${BOLD}$mnt${NC} → ${GREEN}$fstype${NC}@${YELLOW}$device${NC}"

        if [[ "$device" =~ ^/dev/ ]]; then
            dev_name=$(basename "$device")
            lsblk -no NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "/dev/$dev_name" 2>/dev/null | sed 's/^/  /' || true
        fi
        echo ""
    done
}

show_physical_disks() {
    print_header "4. Идентификация физических дисков"

    printf "%-10s %10s %-25s %-20s %-20s %6s %s\n" \
        "УСТРОЙСТВО" "РАЗМЕР" "МОДЕЛЬ" "SERIAL" "WWN" "ROTA" "HCTL/PCI"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

    lsblk -dno NAME,SIZE,MODEL,SERIAL,WWN,ROTA,HCTL | while read -r name size model serial wwn rota hctl; do
        [[ "$name" =~ loop ]] && continue

        disk_type="HDD"
        [[ "$rota" == "0" ]] && disk_type="SSD"

        printf "%-10s %10s %-25s %-20s %-20s %6s %s\n" \
            "/dev/$name" "$size" "${model:--}" "${serial:--}" "${wwn:--}" "$disk_type" "${hctl:--}"
    done
    echo ""
}

show_raid_lvm_status() {
    print_header "5. RAID / LVM / Btrfs — Статус"

    # MDRAID
    if command -v mdadm &> /dev/null && [[ -f /proc/mdstat ]]; then
        print_subheader "MD RAID"
        cat /proc/mdstat
        echo ""

        # Используем || true чтобы не падать при отсутствии массивов
        mdadm --detail --scan 2>/dev/null | grep "ARRAY" | awk '{print $2}' | while read -r array; do
            echo -e "${YELLOW}Детали: $array${NC}"
            mdadm --detail "$array" 2>/dev/null | grep -E "(State|Active Devices|Failed|Spare)" || true
            echo ""
        done || true  # Добавляем || true для всего пайпа
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

    # Btrfs
    if command -v btrfs &> /dev/null; then
        print_subheader "Btrfs Filesystems"
        btrfs filesystem show 2>/dev/null || echo "Btrfs ФС не найдены"
        echo ""

        get_mount_points | while read -r mnt; do
            fstype=$(df -T "$mnt" 2>/dev/null | awk 'NR==2 {print $2}') || continue
            if [[ "$fstype" == "btrfs" ]]; then
                echo -e "${YELLOW}Использование: $mnt${NC}"
                btrfs filesystem usage "$mnt" 2>/dev/null || true
                echo ""
            fi
        done || true  # Добавляем || true для цикла
    fi
}

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

show_large_directories() {
    print_header "7. Крупные каталоги (топ-$TOPN по каждой ФС)"

    get_mount_points | while read -r mnt; do
        [[ -z "$mnt" || ! -d "$mnt" ]] && continue

        device=$(df "$mnt" | awk 'NR==2 {print $1}')
        echo -e "${BLUE}${BOLD}▶ Монтирование: $mnt (устройство: $device)${NC}"

        printf "  %-50s %15s\n" "КАТАЛОГ" "РАЗМЕР"
        echo "  ────────────────────────────────────────────────────────────────────────────────"

        timeout 60 du -x -d 1 "$mnt" 2>/dev/null | sort -rn | head -n "$TOPN" | while read -r size path; do
            formatted_size=$(format_size $((size * 1024)))
            printf "  %-50s %15s\n" "$path" "$formatted_size"
        done || echo "  ${YELLOW}Timeout или ошибка доступа${NC}"

        echo ""
    done
}

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

show_logs_and_caches() {
    print_header "9. Журналы и кеши"

    if command -v journalctl &> /dev/null; then
        print_subheader "Журналы systemd"
        journalctl --disk-usage 2>/dev/null || echo "Недоступно"
        echo ""
    fi

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

show_containers_snaps() {
    print_header "10. Контейнеры и снапы"

    if command -v docker &> /dev/null; then
        print_subheader "Docker"
        docker system df 2>/dev/null || echo "Docker не запущен или недоступен"
        echo ""
    fi

    if command -v snap &> /dev/null; then
        print_subheader "Snap"
        snap list 2>/dev/null || echo "Snap не запущен или недоступен"
        echo ""
    fi

    if command -v flatpak &> /dev/null; then
        print_subheader "Flatpak"
        flatpak list 2>/dev/null || echo "Flatpak не установлен или не настроен"
        echo ""
    fi
}

show_deleted_files() {
    print_header "11. Удаленные, но открытые файлы (leaked disk usage)"

    if command -v lsof &> /dev/null; then
        lsof -nP | grep '(deleted)' || echo "Нет открытых удаленных файлов"
    else
        echo "lsof не установлен, пропущено"
    fi
    echo ""
}

show_swap_tmpfs() {
    print_header "12. Swap и tmpfs"

    print_subheader "Swap"
    swapon --show --bytes || echo "Swap не используется"
    echo ""

    print_subheader "tmpfs / shm"
    df -hT | grep -E "tmpfs|shm" || echo "tmpfs/shm не найдены"
    echo ""
}

show_smart_status() {
    if [[ "$WITH_SMART" != true ]]; then
        echo -e "${YELLOW}SMART не запрошен (--with-smart), пропуск.${NC}\n"
        return
    fi

    print_header "13. SMART статус дисков"

    if ! command -v smartctl &> /dev/null; then
        echo "smartctl не установлен, пропуск."
        return
    fi

    smartctl --scan | awk '{print $1}' | while read -r dev; do
        [[ -z "$dev" ]] && continue
        echo -e "${BLUE}${BOLD}▶ $dev${NC}"
        smartctl -H -A "$dev" || echo "Не удалось прочитать SMART"
        echo ""
    done
}

show_alerts() {
    print_header "14. Оповещения / предупреждения"

    alerts=()

    df -P | awk 'NR>1 {print $6, $5}' | while read -r mount use; do
        use_pct=${use%\%}
        if [[ "$use_pct" -ge 90 ]]; then
            alerts+=("Критично: $mount заполнен на ${use_pct}%")
        elif [[ "$use_pct" -ge 80 ]]; then
            alerts+=("Предупреждение: $mount заполнен на ${use_pct}%")
        fi
    done

    if [[ ${#alerts[@]} -eq 0 ]]; then
        echo "Нет предупреждений, всё хорошо."
    else
        for a in "${alerts[@]}"; do
            echo "- $a"
        done
    fi
    echo ""
}

show_fstab() {
    print_header "15. /etc/fstab"

    if [[ -f /etc/fstab ]]; then
        grep -v "^#" /etc/fstab | grep -v "^$" | column -t
    else
        echo "Файл /etc/fstab не найден"
    fi
    echo ""
}

################################################################################
# Функции экспорта (добавить перед MAIN)
################################################################################

export_txt() {
    local output_file="${1:-}"
    
    if [[ -n "$output_file" ]]; then
        # Перенаправляем весь вывод в файл
        {
            echo "=== DISK SPACE ANALYZER REPORT ==="
            echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo ""
            echo "This is a text export of the disk analysis."
            echo "For full details, run the script in interactive mode."
        } > "$output_file"
        echo "Текстовый отчет сохранен в: $output_file"
    fi
}

export_json() {
    local output_file="${1:-}"
    
    local json_output='{"timestamp":"'$(date -Iseconds)'","analysis":"disk_space"}'
    
    if [[ -n "$output_file" ]]; then
        echo "$json_output" > "$output_file"
        echo "JSON отчет сохранен в: $output_file"
    else
        echo "$json_output"
    fi
}

export_csv() {
    local output_file="${1:-}"
    
    local csv_header="Timestamp,Mount,Device,Type,Total,Used,Available,Use%"
    
    if [[ -n "$output_file" ]]; then
        echo "$csv_header" > "$output_file"
        echo "CSV отчет сохранен в: $output_file"
    else
        echo "$csv_header"
    fi
}
################################################################################
# MAIN
################################################################################

clear
echo -e "${BOLD}${CYAN}"
cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
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

print_header "ИТОГИ"

# Используем здесь-документ и process substitution вместо pipe
total_size=0
total_used=0
total_avail=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    # Пропускаем заголовок
    [[ "$line" =~ ^Filesystem ]] && continue
    
    if [[ "$EXCLUDE_PSEUDO" == true ]]; then
        # Получаем тип ФС из строки df -T
        fs_type=$(echo "$line" | awk '{print $2}')
        [[ "$fs_type" =~ ^(tmpfs|devtmpfs|proc|sysfs|devpts|securityfs|cgroup|pstore|bpf|tracefs|debugfs|hugetlbfs|mqueue|configfs|fusectl|fuse\.lxcfs)$ ]] && continue
    fi

    # Извлекаем значения (df -T выводит: Filesystem Type 1K-blocks Used Available Use% Mounted)
    total=$(echo "$line" | awk '{print $3}')
    used=$(echo "$line" | awk '{print $4}')
    avail=$(echo "$line" | awk '{print $5}')

    # Проверяем, что значения числовые
    if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$used" =~ ^[0-9]+$ ]] && [[ "$avail" =~ ^[0-9]+$ ]]; then
        total_size=$((total_size + total))
        total_used=$((total_used + used))
        total_avail=$((total_avail + avail))
    fi
done < <(df -T -k)

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

# Экспорт в нужном формате
case "$OUTPUT_FORMAT" in
    json)
        if [[ -n "$OUTPUT_FILE" ]]; then
            export_json "$OUTPUT_FILE"
        else
            export_json
        fi
        ;;
    csv)
        if [[ -n "$OUTPUT_FILE" ]]; then
            export_csv "$OUTPUT_FILE"
        else
            export_csv
        fi
        ;;
    txt)
        if [[ -n "$OUTPUT_FILE" ]]; then
            export_txt "$OUTPUT_FILE"
        fi
        # Для txt без файла ничего не делаем (вывод уже на экране)
        ;;
esac

exit 0
