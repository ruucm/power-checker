#!/usr/bin/env bash
# Power Checker - macOS 실시간 전원 모니터링 CLI 도구
# macOS bash 3.2 호환 (associative array 미사용)

set -uo pipefail

# ── 색상 및 스타일 ──
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
WHITE='\033[37m'

# ── 설정 ──
REFRESH_INTERVAL=2
MIN_REFRESH=1
MAX_REFRESH=10

# ── 배터리 데이터 (글로벌 변수) ──
B_CAPACITY=0
B_MAX_CAPACITY=100
B_DESIGN_CAPACITY=0
B_NOMINAL_CAPACITY=0
B_IS_CHARGING="No"
B_EXTERNAL="No"
B_FULLY_CHARGED="No"
B_CYCLE_COUNT=0
B_TEMPERATURE=0
B_VOLTAGE=0
B_AMPERAGE=0
B_TIME_TO_FULL=0
B_TIME_TO_EMPTY=0
B_ADAPTER_WATTS=0
B_ADAPTER_VOLTAGE=0

# ── 터미널 설정/복원 ──
setup_terminal() {
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    stty -echo -icanon min 0 time 0 2>/dev/null || true
}

restore_terminal() {
    stty sane 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
    printf '\033[?25h'
}

trap restore_terminal EXIT INT TERM

# ── ioreg 데이터 파싱 ──
parse_ioreg() {
    local ioreg_output
    ioreg_output=$(ioreg -rn AppleSmartBattery 2>/dev/null) || return 1

    # 최상위 필드 추출 ("Key" = Value 포맷)
    _get() {
        echo "$ioreg_output" | sed -n 's/.*"'"$1"'" = \(.*\)/\1/p' | head -1
    }

    # AdapterDetails 중첩 필드 ("Key"=Value 포맷)
    _get_adapter() {
        echo "$ioreg_output" | grep '"AdapterDetails" = ' | sed -n 's/.*"'"$1"'"=\([0-9]*\).*/\1/p' | head -1
    }

    B_CAPACITY=$(_get CurrentCapacity)
    B_MAX_CAPACITY=$(_get MaxCapacity)
    B_DESIGN_CAPACITY=$(_get DesignCapacity)
    B_NOMINAL_CAPACITY=$(_get NominalChargeCapacity)
    B_IS_CHARGING=$(_get IsCharging)
    B_EXTERNAL=$(_get ExternalConnected)
    B_FULLY_CHARGED=$(_get FullyCharged)
    B_CYCLE_COUNT=$(_get CycleCount)
    B_TEMPERATURE=$(_get Temperature)
    B_VOLTAGE=$(_get AppleRawBatteryVoltage)
    B_TIME_TO_FULL=$(_get AvgTimeToFull)
    B_TIME_TO_EMPTY=$(_get AvgTimeToEmpty)

    # Amperage: ioreg는 음수를 unsigned 64-bit로 반환 → signed 변환
    local raw_amp
    raw_amp=$(_get Amperage)
    if [[ -n "$raw_amp" ]] && [[ $(echo "$raw_amp > 9223372036854775807" | bc 2>/dev/null) == "1" ]]; then
        B_AMPERAGE=$(echo "$raw_amp - 18446744073709551616" | bc)
    else
        B_AMPERAGE="${raw_amp:-0}"
    fi

    # AdapterDetails 중첩 필드
    B_ADAPTER_WATTS=$(_get_adapter Watts)
    B_ADAPTER_VOLTAGE=$(_get_adapter AdapterVoltage)

    # 빈 값 기본값 처리
    B_CAPACITY=${B_CAPACITY:-0}
    B_MAX_CAPACITY=${B_MAX_CAPACITY:-100}
    B_DESIGN_CAPACITY=${B_DESIGN_CAPACITY:-0}
    B_NOMINAL_CAPACITY=${B_NOMINAL_CAPACITY:-0}
    B_IS_CHARGING=${B_IS_CHARGING:-No}
    B_EXTERNAL=${B_EXTERNAL:-No}
    B_FULLY_CHARGED=${B_FULLY_CHARGED:-No}
    B_CYCLE_COUNT=${B_CYCLE_COUNT:-0}
    B_TEMPERATURE=${B_TEMPERATURE:-0}
    B_VOLTAGE=${B_VOLTAGE:-0}
    B_TIME_TO_FULL=${B_TIME_TO_FULL:-0}
    B_TIME_TO_EMPTY=${B_TIME_TO_EMPTY:-0}
    B_ADAPTER_WATTS=${B_ADAPTER_WATTS:-0}
    B_ADAPTER_VOLTAGE=${B_ADAPTER_VOLTAGE:-0}
}

# ── 프로그레스바 생성 ──
progress_bar() {
    local percent=$1
    local width=${2:-26}
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local color

    if (( percent <= 20 )); then
        color=$RED
    elif (( percent <= 50 )); then
        color=$YELLOW
    else
        color=$GREEN
    fi

    bar+="${color}${BOLD}"
    local i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    bar+="${RESET}${DIM}"
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    bar+="${RESET}"

    echo -e "$bar"
}

# ── 시간 포맷 ──
format_time() {
    local minutes=$1
    if [[ -z "$minutes" ]] || (( minutes <= 0 || minutes == 65535 )); then
        echo "Calculating..."
        return
    fi
    local hours=$(( minutes / 60 ))
    local mins=$(( minutes % 60 ))
    if (( hours > 0 )); then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# ── 온도 변환 (÷100 → °C) ──
format_temp() {
    local raw=$1
    if [[ -z "$raw" ]] || (( raw == 0 )); then
        echo "N/A"
        return
    fi
    local whole=$(( raw / 100 ))
    local frac=$(( (raw % 100) / 10 ))
    echo "${whole}.${frac}°C"
}

# ── 전압 변환 (mV → V) ──
format_voltage() {
    local mv=$1
    if [[ -z "$mv" ]] || (( mv == 0 )); then
        echo "N/A"
        return
    fi
    local whole=$(( mv / 1000 ))
    local frac=$(( (mv % 1000) / 10 ))
    printf "%d.%02dV" "$whole" "$frac"
}

# ── 전력 계산 (W) ──
calc_power() {
    local voltage=$1  # mV
    local amperage=$2  # mA (signed)
    if [[ -z "$voltage" ]] || [[ -z "$amperage" ]] || (( voltage == 0 )); then
        echo "N/A"
        return
    fi
    # 절대값
    local amp=${amperage#-}
    # W = V * A = (mV/1000) * (mA/1000) = mV*mA / 1000000
    local power_mw=$(( voltage * amp ))
    local power_w=$(( power_mw / 1000000 ))
    local power_frac=$(( (power_mw % 1000000) / 10000 ))
    printf "~%d.%dW" "$power_w" "$power_frac"
}

# ── 건강도 상태 텍스트 ──
health_status() {
    local health=$1
    if (( health >= 80 )); then
        echo -e "${GREEN}Normal${RESET}"
    elif (( health >= 60 )); then
        echo -e "${YELLOW}Fair${RESET}"
    else
        echo -e "${RED}Poor${RESET}"
    fi
}

# ── 화면 그리기 ──
render() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 54)
    if (( cols < 54 )); then cols=54; fi

    # 화면 클리어
    printf '\033[H\033[2J'

    local now
    now=$(date '+%H:%M:%S')

    # ── 헤더 ──
    local pad=$(( cols - 30 ))
    if (( pad < 0 )); then pad=0; fi
    printf "${BOLD}${CYAN}⚡ Power Checker${RESET}"
    printf "%*s" "$pad" ""
    printf "${DIM}[Live] ${REFRESH_INTERVAL}s refresh  ${now}${RESET}\n"
    printf "${DIM}"
    local i
    local line_w=$cols
    if (( line_w > 54 )); then line_w=54; fi
    for ((i = 0; i < line_w; i++)); do printf "━"; done
    printf "${RESET}\n\n"

    # ── 충전률 계산 ──
    local percent=0
    if (( B_MAX_CAPACITY > 0 )); then
        percent=$(( B_CAPACITY * 100 / B_MAX_CAPACITY ))
    fi
    if (( percent > 100 )); then percent=100; fi

    # ── 건강도 계산 (NominalChargeCapacity / DesignCapacity) ──
    local health=100
    if (( B_DESIGN_CAPACITY > 0 && B_NOMINAL_CAPACITY > 0 )); then
        health=$(( B_NOMINAL_CAPACITY * 100 / B_DESIGN_CAPACITY ))
    fi
    if (( health > 100 )); then health=100; fi

    # ── 상태 텍스트 ──
    local status_icon status_text status_color
    if [[ "$B_IS_CHARGING" == "Yes" ]]; then
        status_icon="⚡"
        status_text="Charging"
        status_color=$GREEN
    elif [[ "$B_FULLY_CHARGED" == "Yes" ]]; then
        status_icon="✓"
        status_text="Fully Charged"
        status_color=$CYAN
    elif [[ "$B_EXTERNAL" == "Yes" ]]; then
        status_icon="●"
        status_text="On AC (Not Charging)"
        status_color=$BLUE
    else
        status_icon="🔋"
        status_text="On Battery"
        if (( percent <= 20 )); then
            status_color=$RED
        elif (( percent <= 50 )); then
            status_color=$YELLOW
        else
            status_color=$WHITE
        fi
    fi

    # ── 배터리 섹션 ──
    printf "${BOLD}🔋 Battery${RESET}\n"
    local bar
    bar=$(progress_bar "$percent")
    printf "  ${BOLD}Charge:${RESET}        ${BOLD}%d%%${RESET} %b\n" "$percent" "$bar"
    printf "  ${BOLD}Status:${RESET}        ${status_color}${status_icon} ${status_text}${RESET}\n"
    printf "  ${BOLD}Health:${RESET}        %d%% (%b) · %d cycles\n" "$health" "$(health_status $health)" "$B_CYCLE_COUNT"
    printf "  ${BOLD}Temperature:${RESET}   %s\n" "$(format_temp "$B_TEMPERATURE")"

    # 잔여시간
    if [[ "$B_IS_CHARGING" == "Yes" ]]; then
        printf "  ${BOLD}Time to Full:${RESET}  %s\n" "$(format_time "$B_TIME_TO_FULL")"
    elif [[ "$B_EXTERNAL" != "Yes" ]]; then
        printf "  ${BOLD}Time Left:${RESET}     %s\n" "$(format_time "$B_TIME_TO_EMPTY")"
    fi

    printf "  ${BOLD}Design Cap:${RESET}    %d mAh\n" "$B_DESIGN_CAPACITY"
    printf "\n"

    # ── 충전기 섹션 ──
    printf "${BOLD}🔌 AC Charger${RESET}\n"
    if [[ "$B_EXTERNAL" == "Yes" ]]; then
        printf "  ${BOLD}Connected:${RESET}     ${GREEN}✓ Yes${RESET}\n"
        if (( B_ADAPTER_WATTS > 0 )); then
            printf "  ${BOLD}Wattage:${RESET}       %dW\n" "$B_ADAPTER_WATTS"
        fi
        if (( B_ADAPTER_VOLTAGE > 0 )); then
            printf "  ${BOLD}Voltage:${RESET}       %s\n" "$(format_voltage "$B_ADAPTER_VOLTAGE")"
        fi
        if [[ "$B_IS_CHARGING" == "Yes" ]]; then
            printf "  ${BOLD}Charging:${RESET}      ${GREEN}Yes${RESET}\n"
        elif [[ "$B_FULLY_CHARGED" == "Yes" ]]; then
            printf "  ${BOLD}Charging:${RESET}      ${CYAN}Complete${RESET}\n"
        else
            printf "  ${BOLD}Charging:${RESET}      ${YELLOW}No (Maintaining)${RESET}\n"
        fi
    else
        printf "  ${BOLD}Connected:${RESET}     ${DIM}✗ No${RESET}\n"
    fi
    printf "\n"

    # ── 전력 사용 섹션 ──
    printf "${BOLD}📊 Power Draw${RESET}\n"
    local amp_abs=${B_AMPERAGE#-}
    local amp_sign=""
    if [[ "$B_AMPERAGE" == -* ]]; then
        amp_sign="-"
    fi
    printf "  ${BOLD}Current:${RESET}       %s%s mA\n" "$amp_sign" "$amp_abs"
    printf "  ${BOLD}Voltage:${RESET}       %s\n" "$(format_voltage "$B_VOLTAGE")"
    printf "  ${BOLD}Power:${RESET}         %s\n" "$(calc_power "$B_VOLTAGE" "$B_AMPERAGE")"
    printf "\n"

    # ── 하단 안내 ──
    printf "${DIM}"
    for ((i = 0; i < line_w; i++)); do printf "━"; done
    printf "${RESET}\n"
    printf "${DIM}Press ${BOLD}q${RESET}${DIM} to quit, ${BOLD}+${RESET}${DIM}/${BOLD}-${RESET}${DIM} to adjust refresh rate${RESET}\n"
}

# ── 키 입력 처리 ──
handle_input() {
    local key=""
    read -rsn1 -t 0.05 key 2>/dev/null || true

    case "$key" in
        q|Q)
            return 1
            ;;
        +|=)
            if (( REFRESH_INTERVAL > MIN_REFRESH )); then
                REFRESH_INTERVAL=$(( REFRESH_INTERVAL - 1 ))
            fi
            ;;
        -|_)
            if (( REFRESH_INTERVAL < MAX_REFRESH )); then
                REFRESH_INTERVAL=$(( REFRESH_INTERVAL + 1 ))
            fi
            ;;
    esac
    return 0
}

# ── 메인 ──
main() {
    if [[ "$(uname)" != "Darwin" ]]; then
        echo "Error: power-checker는 macOS에서만 동작합니다."
        exit 1
    fi

    local ioreg_check
    ioreg_check=$(ioreg -rn AppleSmartBattery 2>/dev/null) || true
    if [[ "$ioreg_check" != *"BatteryInstalled"* ]]; then
        echo "Error: 배터리를 찾을 수 없습니다."
        exit 1
    fi

    setup_terminal

    # 최초 데이터 로드 및 렌더
    parse_ioreg
    render

    local tick=0
    local ticks_per_refresh=$(( REFRESH_INTERVAL * 10 ))

    while true; do
        if ! handle_input; then
            break
        fi

        sleep 0.1
        tick=$(( tick + 1 ))

        # 갱신 간격 체크 (tick 기반, bc 불필요)
        ticks_per_refresh=$(( REFRESH_INTERVAL * 10 ))
        if (( tick >= ticks_per_refresh )); then
            parse_ioreg
            render
            tick=0
        fi
    done
}

main "$@"
