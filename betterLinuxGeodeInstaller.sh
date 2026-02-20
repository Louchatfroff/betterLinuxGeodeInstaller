#!/usr/bin/env bash

set -euo pipefail

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

GD_APP_ID="322170"

VERBOSE=0
CHANNEL="nightly"
GPU_TYPE="other"
DISPLAY_SERVER="x11"
CUSTOM_PROTON_PATH=""
LAUNCH_OPTS=""
DOWNLOAD_URL=""
GD_PATH=""
STEAM_ROOT=""
PROTON_NAME=""
TAG=""
PICKED_INDEX=0
PICKED_VALUE=""
LAST_VALID_GD_PATH_ERR=""

PROTON_VERSIONS_INTERNAL=()
PROTON_VERSIONS_DISPLAY=()
PROTON_VERSIONS_SOURCE=()


verbose_log() {
    if [ -n "${1:-}" ] && [ "$VERBOSE" -eq 1 ]; then
        echo -e "${DIM}[verbose]${NC} $1"
    fi
}

die() {
    echo -e "${RED}Error:${NC} $1" >&2
    exit 1
}


check_dependencies() {
    for cmd in unzip curl; do
        command -v "$cmd" &>/dev/null || die "$cmd is not installed."
    done

    if command -v python3 &>/dev/null; then
        PY_CMD="python3"
    elif command -v python &>/dev/null; then
        PY_CMD="python"
    else
        die "python3 is not installed. It is required for JSON parsing and Steam config editing."
    fi

    if command -v jq &>/dev/null; then
        JSON_TOOL="jq"
    else
        JSON_TOOL="$PY_CMD"
    fi

    verbose_log "JSON tool: $JSON_TOOL  |  Python: $PY_CMD"
}


pick_option() {
    local prompt="$1"; shift
    local options=("$@")
    local i reply

    echo -e "$prompt"
    for i in "${!options[@]}"; do
        echo -e "  ${CYAN}$((i+1))${NC}) ${options[$i]}"
    done

    while true; do
        read -r -p "  Choice [1-${#options[@]}]: " reply < /dev/tty
        if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#options[@]}" ]; then
            PICKED_INDEX=$((reply - 1))
            PICKED_VALUE="${options[$PICKED_INDEX]}"
            return 0
        fi
        echo -e "  ${RED}Invalid.${NC} Enter a number between 1 and ${#options[@]}."
    done
}


confirm() {
    local reply
    while true; do
        read -n1 -r -p "$(echo -e "$1") [Y/n]: " reply < /dev/tty
        echo ""
        case "$reply" in
            y|Y|"") return 0 ;;
            n|N)    return 1 ;;
        esac
    done
}


section() {
    echo ""
    echo -e "${BLUE}▸ $1${NC}"
}


detect_gpu_type() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        echo "nvidia"; return
    fi

    if command -v lsmod &>/dev/null; then
        if lsmod 2>/dev/null | grep -q '^nvidia '; then
            echo "nvidia"; return
        fi
    fi

    if [ -f /proc/driver/nvidia/version ]; then
        echo "nvidia"; return
    fi
    local vendor_file
    for vendor_file in /sys/bus/pci/devices/*/vendor; do
        [ -f "$vendor_file" ] || continue
        local vendor
        read -r vendor < "$vendor_file" 2>/dev/null || continue
        if [ "$vendor" = "0x10de" ]; then
            echo "nvidia"; return
        fi
    done

    local drm_vendor
    for drm_vendor in /sys/class/drm/card*/device/vendor; do
        [ -f "$drm_vendor" ] || continue
        local v
        read -r v < "$drm_vendor" 2>/dev/null || continue
        if [ "$v" = "0x10de" ]; then
            echo "nvidia"; return
        fi
    done

    if command -v lspci &>/dev/null; then
        if lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | grep -qi 'nvidia'; then
            echo "nvidia"; return
        fi
    fi

    if command -v vulkaninfo &>/dev/null; then
        if vulkaninfo --summary 2>/dev/null | grep -qi 'nvidia'; then
            echo "nvidia"; return
        fi
    fi

    if command -v glxinfo &>/dev/null; then
        if glxinfo 2>/dev/null | grep -i 'vendor string' | grep -qi 'nvidia'; then
            echo "nvidia"; return
        fi
    fi

    echo "other"
}


detect_display_server() {
    case "${XDG_SESSION_TYPE:-}" in
        wayland) echo "wayland"; return ;;
        x11)     echo "x11";     return ;;
    esac

    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "wayland"; return
    fi

    local uid
    uid="$(id -u)"
    if ls "/run/user/${uid}"/wayland-* &>/dev/null 2>&1; then
        echo "wayland"; return
    fi

    if command -v loginctl &>/dev/null; then
        local session_type
        session_type="$(loginctl show-session \
            "$(loginctl list-sessions --no-legend 2>/dev/null \
               | awk -v u="$(whoami)" '$3==u {print $1; exit}')" \
            -p Type --value 2>/dev/null || true)"
        case "${session_type:-}" in
            wayland) echo "wayland"; return ;;
            x11|mir) echo "x11";    return ;;
        esac
    fi

    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "x11"; return
    fi

    if [ -n "${DISPLAY:-}" ]; then
        echo "x11"; return
    fi

    echo "x11"
}

find_steam_root() {
    verbose_log "Searching for Steam root..."

    local DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

    local steam_pid
    steam_pid="$(pgrep -x steam 2>/dev/null | head -1 || true)"
    if [ -n "$steam_pid" ]; then
        local steam_home_env
        steam_home_env="$(tr '\0' '\n' < "/proc/$steam_pid/environ" 2>/dev/null \
            | grep '^STEAM_DATA_PATH=' | cut -d= -f2- || true)"
        if [ -n "$steam_home_env" ] && [ -f "$steam_home_env/config/config.vdf" ]; then
            STEAM_ROOT="$steam_home_env"
            verbose_log "Steam root from running process env: $STEAM_ROOT"
            return 0
        fi
        local steam_exe
        steam_exe="$(readlink -f "/proc/$steam_pid/exe" 2>/dev/null || true)"
        if [ -n "$steam_exe" ]; then
            local steam_bin_dir
            steam_bin_dir="$(dirname "$steam_exe")"
            for try_root in "$steam_bin_dir" "$(dirname "$steam_bin_dir")"; do
                if [ -f "$try_root/config/config.vdf" ]; then
                    STEAM_ROOT="$try_root"
                    verbose_log "Steam root from running process exe: $STEAM_ROOT"
                    return 0
                fi
            done
        fi
    fi

    local steam_cmd
    steam_cmd="$(command -v steam 2>/dev/null || true)"
    if [ -n "$steam_cmd" ]; then
        local real_steam
        real_steam="$(readlink -f "$steam_cmd" 2>/dev/null || true)"
        if [ -n "$real_steam" ]; then
            local bin_dir
            bin_dir="$(dirname "$real_steam")"
            for try_root in "$bin_dir" "$(dirname "$bin_dir")"; do
                if [ -f "$try_root/config/config.vdf" ]; then
                    STEAM_ROOT="$try_root"
                    verbose_log "Steam root from which steam: $STEAM_ROOT"
                    return 0
                fi
            done
        fi
    fi

    if command -v flatpak &>/dev/null; then
        if flatpak info com.valvesoftware.Steam &>/dev/null 2>&1; then
            local flatpak_steam="$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
            if [ -f "$flatpak_steam/config/config.vdf" ]; then
                STEAM_ROOT="$flatpak_steam"
                verbose_log "Steam root from Flatpak: $STEAM_ROOT"
                return 0
            fi
        fi
    fi

    local candidates=(
        "$DATA_HOME/Steam"
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
        "$HOME/Steam"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
        "$HOME/snap/steam/common/.steam/steam"
    )

    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c/config/config.vdf" ]; then
            STEAM_ROOT="$c"
            verbose_log "Steam root (static candidate): $STEAM_ROOT"
            return 0
        fi
    done

    return 1
}

collect_steam_library_paths() {
    local -a libs=()
    if [ -n "$STEAM_ROOT" ]; then
        libs+=("$STEAM_ROOT")
    fi
    local lf_vdf="$STEAM_ROOT/steamapps/libraryfolders.vdf"
    if [ -f "$lf_vdf" ]; then
        local path
        while IFS= read -r path; do
            path="${path#*\"path\"}"
            path="${path//\"/}"
            path="${path//	/}"
            path="${path// /}"
            true
        done < /dev/null

        while IFS= read -r line; do
            line="$(echo "$line" | sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p')"
            [ -n "$line" ] || continue
            [ -d "$line" ] || continue
            local already=0
            local existing
            for existing in "${libs[@]:-}"; do
                [ "$existing" = "$line" ] && { already=1; break; }
            done
            [ "$already" -eq 0 ] && libs+=("$line")
        done < "$lf_vdf"
    fi

    printf '%s\n' "${libs[@]:-}"
}

is_valid_gd_path() {
    if [ -z "${1:-}" ]; then
        LAST_VALID_GD_PATH_ERR="No path specified."
        return 1
    fi
    if [ ! -d "$1" ]; then
        LAST_VALID_GD_PATH_ERR="Path is not a directory."
        return 1
    fi
    if [ ! -f "$1/libcocos2d.dll" ] && [ ! -f "$1/GeometryDash.exe" ]; then
        LAST_VALID_GD_PATH_ERR="Path doesn't appear to contain Geometry Dash."
        return 1
    fi
    return 0
}


find_gd_installation() {
    verbose_log "Searching for Geometry Dash across all Steam libraries..."

    find_steam_root || true

    if [ -n "$STEAM_ROOT" ]; then
        while IFS= read -r lib_root; do
            [ -n "$lib_root" ] || continue
            local candidate="$lib_root/steamapps/common/Geometry Dash"
            verbose_log "Testing $candidate"
            if is_valid_gd_path "$candidate"; then
                GD_PATH="$candidate"
                case "$candidate" in
                    */snap/steam/*)
                        echo -e "${YELLOW}Warning:${NC} Steam via Snap is not officially supported. Consider Flatpak."
                        ;;
                esac
                verbose_log "Found: $GD_PATH"
                return 0
            fi
        done < <(collect_steam_library_paths)
    fi

    local DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    local extra_candidates=(
        "$HOME/Games/Geometry Dash"
        "$HOME/games/Geometry Dash"
        "$DATA_HOME/games/Geometry Dash"
    )
    local c
    for c in "${extra_candidates[@]}"; do
        if is_valid_gd_path "$c"; then
            GD_PATH="$c"
            verbose_log "Found (extra path): $GD_PATH"
            return 0
        fi
    done

    return 1
}


ask_gd_path() {
    local input=""
    while read -r -p "  Path to Geometry Dash folder (or drag it in): " input < /dev/tty; do
        input="${input%/GeometryDash.exe}"
        input="${input%/}"
        input="${input/#\~/$HOME}"
        if is_valid_gd_path "$input"; then
            if confirm "  Install ${YELLOW}Geode${NC} to ${YELLOW}$input${NC}?"; then
                GD_PATH="$input"
                return 0
            fi
        else
            echo -e "  ${RED}Invalid:${NC} $LAST_VALID_GD_PATH_ERR"
        fi
    done
}

read_internal_name() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    local name
    name="$(grep -m1 '"internal_name"' "$vdf" \
        | sed 's/.*"internal_name"[[:space:]]*"\([^"]*\)".*/\1/' || true)"
    [ -n "$name" ] && echo "$name"
}


read_display_name() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    local name
    name="$(grep -m1 '"display_name"' "$vdf" \
        | sed 's/.*"display_name"[[:space:]]*"\([^"]*\)".*/\1/' || true)"
    [ -n "$name" ] && echo "$name"
}


_proton_array_has_internal() {
    local needle="$1"
    local i
    for i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
        [ "${PROTON_VERSIONS_INTERNAL[$i]}" = "$needle" ] && return 0
    done
    return 1
}


_add_proton_entry() {
    local internal="$1" display="$2" source="$3"
    [ -n "$internal" ] || return 0
    _proton_array_has_internal "$internal" && return 0
    PROTON_VERSIONS_INTERNAL+=("$internal")
    PROTON_VERSIONS_DISPLAY+=("$display")
    PROTON_VERSIONS_SOURCE+=("$source")
    verbose_log "Found Proton: [$internal] \"$display\"  (from $source)"
}


_scan_compat_dir() {
    local dir="$1" source_label="$2"
    [ -d "$dir" ] || return 0

    local folder
    for folder in "$dir"/*/; do
        [ -d "$folder" ] || continue
        local vdf="$folder/compatibilitytool.vdf"
        local internal display
        internal="$(read_internal_name "$vdf" || true)"
        [ -n "$internal" ] || continue
        display="$(read_display_name "$vdf" || true)"
        [ -n "$display" ] || display="$(basename "$folder")"
        _add_proton_entry "$internal" "$display" "$source_label"
    done
}


_scan_steamapps_common() {
    local steamapps="$1"
    [ -d "$steamapps/common" ] || return 0

    local folder
    for folder in "$steamapps/common"/Proton*/; do
        [ -d "$folder" ] || continue
        local vdf="$folder/compatibilitytool.vdf"
        local internal display folder_name
        folder_name="$(basename "$folder")"

        internal="$(read_internal_name "$vdf" || true)"
        display="$(read_display_name "$vdf" || true)"

        if [ -z "$internal" ]; then
            case "$folder_name" in
                "Proton - Experimental") internal="proton_experimental" ;;
                "Proton - Beta")         internal="proton_experimental" ;;
                "Proton Hotfix")         internal="proton_experimental" ;;
                *)
                    local ver
                    ver="$(echo "$folder_name" | grep -oE '[0-9]+' | head -1 || true)"
                    [ -n "$ver" ] && internal="proton_${ver}" || continue
                    ;;
            esac
        fi
        [ -n "$display" ] || display="$folder_name"
        _add_proton_entry "$internal" "$display" "Steam ($steamapps)"
    done
}


collect_all_proton_versions() {
    verbose_log "Collecting all installed Proton versions..."

    PROTON_VERSIONS_INTERNAL=()
    PROTON_VERSIONS_DISPLAY=()
    PROTON_VERSIONS_SOURCE=()

    local DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    local -a compat_dirs=()

    [ -n "$STEAM_ROOT" ] && compat_dirs+=("$STEAM_ROOT/compatibilitytools.d")
    if [ -n "$STEAM_ROOT" ]; then
        while IFS= read -r lib_root; do
            [ -n "$lib_root" ] || continue
            [ -d "$lib_root/compatibilitytools.d" ] || continue
            compat_dirs+=("$lib_root/compatibilitytools.d")
        done < <(collect_steam_library_paths)
    fi

    compat_dirs+=(
        "$DATA_HOME/Steam/compatibilitytools.d"
        "$HOME/.steam/root/compatibilitytools.d"
        "$HOME/.steam/steam/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"
        "$HOME/snap/steam/common/.local/share/Steam/compatibilitytools.d"
        "$HOME/.snap/data/steam/common/.local/share/Steam/compatibilitytools.d"
        "/usr/share/steam/compatibilitytools.d"
        "/usr/local/share/steam/compatibilitytools.d"
    )

    local seen_dirs=()
    local dir
    for dir in "${compat_dirs[@]}"; do
        local already=0
        local s
        for s in "${seen_dirs[@]:-}"; do
            [ "$s" = "$dir" ] && { already=1; break; }
        done
        [ "$already" -eq 1 ] && continue
        seen_dirs+=("$dir")

        local real_dir
        real_dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
        local already_real=0
        for s in "${seen_dirs[@]:-}"; do
            local real_s
            real_s="$(readlink -f "$s" 2>/dev/null || echo "$s")"
            [ "$real_s" = "$real_dir" ] && [ "$s" != "$dir" ] && { already_real=1; break; }
        done
        [ "$already_real" -eq 1 ] && continue

        _scan_compat_dir "$dir" "$(dirname "$dir")"
    done

    if [ -n "$STEAM_ROOT" ]; then
        while IFS= read -r lib_root; do
            [ -n "$lib_root" ] || continue
            _scan_steamapps_common "$lib_root/steamapps"
        done < <(collect_steam_library_paths)
    fi

    verbose_log "Total Proton versions found: ${#PROTON_VERSIONS_INTERNAL[@]}"
}

_best_proton_index() {
    local -a tiers=(
        "^GE-Proton"
        "^proton-cachyos"
        "^Proton-CachyOS"
        "^proton_cachyos"
        "^Proton-tkg"
        "^proton-tkg"
        "^Proton-Sarek"
        "^proton-sarek"
        "^Proton-EM"
        "^proton-em"
        "^Kron4ek-Proton"
        "^kron4ek-proton"
        "^SteamTinkerLaunch"
        "^proton_experimental"
        "^proton_"
    )

    local tier
    for tier in "${tiers[@]}"; do
        local best_idx=-1
        local best_name=""
        local i
        for i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
            local name="${PROTON_VERSIONS_INTERNAL[$i]}"
            echo "$name" | grep -qE "$tier" || continue
            if [ -z "$best_name" ]; then
                best_idx=$i
                best_name="$name"
            else
                local winner
                winner="$(printf '%s\n%s\n' "$best_name" "$name" | sort -V | tail -1)"
                if [ "$winner" = "$name" ]; then
                    best_idx=$i
                    best_name="$name"
                fi
            fi
        done
        [ "$best_idx" -ge 0 ] && echo "$best_idx" && return 0
    done
}


ask_custom_proton() {
    local input
    while read -r -p "  Path to Proton version folder: " input < /dev/tty; do
        input="${input%/}"
        input="${input/#\~/$HOME}"
        if [ ! -d "$input" ]; then
            echo -e "  ${RED}Not a directory.${NC}"
            continue
        fi
        local internal display
        internal="$(read_internal_name "$input/compatibilitytool.vdf" || true)"
        display="$(read_display_name "$input/compatibilitytool.vdf" || true)"
        if [ -n "$internal" ]; then
            PROTON_NAME="$internal"
            CUSTOM_PROTON_PATH="$input"
            echo -e "  Found: ${GREEN}${display:-$internal}${NC}  (internal: $internal)"
            return 0
        fi
        echo -e "  ${YELLOW}Warning:${NC} No compatibilitytool.vdf found — using folder name as Proton ID."
        PROTON_NAME="$(basename "$input")"
        CUSTOM_PROTON_PATH="$input"
        return 0
    done
}

build_launch_opts() {
    LAUNCH_OPTS=""

    if [ "$GPU_TYPE" = "nvidia" ]; then
        LAUNCH_OPTS="PROTON_ENABLE_NVAPI=1 PROTON_HIDE_NVIDIA_GPU=0 PROTON_ENABLE_NGX_UPDATER=1 PROTON_ENABLE_NVAPI_REFLEX=1 "
    fi

    if [ "$DISPLAY_SERVER" = "wayland" ]; then
        LAUNCH_OPTS="${LAUNCH_OPTS}SDL_VIDEODRIVER=wayland "
    fi

    LAUNCH_OPTS="${LAUNCH_OPTS}DXVK_ASYNC=1 PROTON_NO_ESYNC=0 PROTON_NO_FSYNC=0 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 VKD3D_CONFIG=dxr11,dxr DXVK_CONFIG_FILE=\$HOME/.config/dxvk/dxvk.conf VKD3D_FEATURE_LEVEL=12_2 WINEDLLOVERRIDES=\"xinput1_4=n,b\" gamemoderun %command%"
}

run_autodetect() {
    echo -e "${DIM}Auto-detecting system configuration...${NC}"

    GPU_TYPE="$(detect_gpu_type)"
    verbose_log "GPU: $GPU_TYPE"

    DISPLAY_SERVER="$(detect_display_server)"
    verbose_log "Display server: $DISPLAY_SERVER"

    find_steam_root || true
    verbose_log "Steam root: ${STEAM_ROOT:-(not found)}"

    find_gd_installation || true
    verbose_log "GD path: ${GD_PATH:-(not found)}"

    collect_all_proton_versions || true
    local best_idx
    best_idx="$(_best_proton_index || true)"
    if [ -n "$best_idx" ] && [ "${#PROTON_VERSIONS_INTERNAL[@]}" -gt 0 ]; then
        PROTON_NAME="${PROTON_VERSIONS_INTERNAL[$best_idx]}"
    fi
    verbose_log "Proton (auto-best): ${PROTON_NAME:-(not found)}"

    echo -e "${DIM}Done.${NC}"
}


print_summary() {
    local proton_display="${PROTON_NAME:-auto-detect}"
    local verbose_display
    [ "$VERBOSE" -eq 1 ] && verbose_display="yes" || verbose_display="no"

    echo ""
    echo -e "${BLUE}┌─ Configuration summary ────────────────────────────────────────────────┐${NC}"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Channel:"    "$CHANNEL"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Game path:"  "${GD_PATH:-(not found)}"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Proton:"     "$proton_display"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "GPU:"        "$GPU_TYPE"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Display:"    "$DISPLAY_SERVER"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Verbose:"    "$verbose_display"
    echo -e "${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}  Launch options:"
    echo -e "${BLUE}│${NC}  ${CYAN}${LAUNCH_OPTS}${NC}"
    echo -e "${BLUE}└────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    if echo "$LAUNCH_OPTS" | grep -q "gamemoderun"; then
        echo -e "${YELLOW}Note:${NC} gamemoderun requires the ${BLUE}gamemode${NC} package."
        echo -e "      ${DIM}sudo apt install gamemode   /   sudo pacman -S gamemode   /   sudo dnf install gamemode${NC}"
    fi
    if echo "$LAUNCH_OPTS" | grep -q "DXVK_CONFIG_FILE"; then
        echo -e "${YELLOW}Note:${NC} DXVK_CONFIG_FILE points to ${BLUE}\$HOME/.config/dxvk/dxvk.conf${NC}."
        echo -e "      ${DIM}That file doesn't need to exist — DXVK uses defaults if missing.${NC}"
    fi
    echo ""
}


run_wizard() {
    echo -e "${BLUE}=== Setup Wizard ===${NC}"
    echo -e "${DIM}Each step shows the auto-detected value as the default. Press Enter to accept.${NC}"


    section "Output mode"
    local default_verbose="Quiet"
    [ "$VERBOSE" -eq 1 ] && default_verbose="Verbose"
    pick_option "How much output? ${DIM}(detected: $default_verbose)${NC}" \
        "Quiet   — only show important messages" \
        "Verbose — show every step"
    [ "$PICKED_INDEX" -eq 1 ] && VERBOSE=1 || VERBOSE=0


    section "Geode channel"
    pick_option "Which build of Geode?" \
        "Nightly — latest development build ${DIM}(default)${NC}" \
        "Stable  — latest official release"
    [ "$PICKED_INDEX" -eq 0 ] && CHANNEL="nightly" || CHANNEL="stable"


    section "GPU type"
    local gpu_label="AMD / Intel / Other"
    [ "$GPU_TYPE" = "nvidia" ] && gpu_label="Nvidia"
    pick_option "GPU type ${DIM}(detected: $gpu_label)${NC}" \
        "Use detected value  [$gpu_label]" \
        "Nvidia  — enables NVAPI, NGX updater, Reflex" \
        "AMD / Intel / Other"
    case "$PICKED_INDEX" in
        0) ;;
        1) GPU_TYPE="nvidia" ;;
        2) GPU_TYPE="other" ;;
    esac


    section "Display server"
    pick_option "Display server ${DIM}(detected: $DISPLAY_SERVER)${NC}" \
        "Use detected value  [$DISPLAY_SERVER]" \
        "Wayland — adds SDL_VIDEODRIVER=wayland" \
        "X11     — no extra variable added"
    case "$PICKED_INDEX" in
        0) ;;
        1) DISPLAY_SERVER="wayland" ;;
        2) DISPLAY_SERVER="x11" ;;
    esac


    section "Geometry Dash location"
    if [ -n "$GD_PATH" ]; then
        pick_option "Game path ${DIM}(detected: $GD_PATH)${NC}" \
            "Use detected path  [$GD_PATH]" \
            "Enter manually"
        if [ "$PICKED_INDEX" -eq 1 ]; then
            GD_PATH=""
            ask_gd_path
        fi
    else
        echo -e "  ${YELLOW}Could not auto-detect Geometry Dash.${NC}"
        echo -e "  Common path: ${DIM}~/.local/share/Steam/steamapps/common/Geometry Dash${NC}"
        ask_gd_path
    fi


    section "Proton version"
    local _num_found="${#PROTON_VERSIONS_INTERNAL[@]}"

    if [ "$_num_found" -eq 0 ]; then
        echo -e "  ${YELLOW}No Proton versions found automatically.${NC}"
        pick_option "Proton version" \
            "Skip — set manually in Steam later" \
            "Enter a custom Proton path now"
        [ "$PICKED_INDEX" -eq 1 ] && ask_custom_proton || PROTON_NAME=""
    else
        local _best_idx
        _best_idx="$(_best_proton_index || true)"

        local _auto_label="Auto-select best"
        if [ -n "$_best_idx" ]; then
            _auto_label="Auto-select best  [${PROTON_VERSIONS_DISPLAY[$_best_idx]} / ${PROTON_VERSIONS_INTERNAL[$_best_idx]}]"
        fi

        local -a _opts=("$_auto_label")
        local _i
        for _i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
            local _src="${PROTON_VERSIONS_SOURCE[$_i]}"
            _opts+=("${PROTON_VERSIONS_DISPLAY[$_i]}  ${DIM}(${PROTON_VERSIONS_INTERNAL[$_i]}) — $_src${NC}")
        done
        _opts+=("Enter a custom Proton path manually")

        echo -e "  Found ${CYAN}$_num_found${NC} Proton installation(s)."
        pick_option "Which Proton version to assign to Geometry Dash?" "${_opts[@]}"

        if [ "$PICKED_INDEX" -eq 0 ]; then
            if [ -n "$_best_idx" ]; then
                PROTON_NAME="${PROTON_VERSIONS_INTERNAL[$_best_idx]}"
            else
                PROTON_NAME=""
            fi
        elif [ "$PICKED_INDEX" -eq $(( _num_found + 1 )) ]; then
            PROTON_NAME=""
            ask_custom_proton
        else
            local _sel=$(( PICKED_INDEX - 1 ))
            PROTON_NAME="${PROTON_VERSIONS_INTERNAL[$_sel]}"
        fi
    fi


    build_launch_opts
    print_summary

    if ! confirm "Proceed with installation?"; then
        echo "Aborted."
        exit 0
    fi
}

write_vdf_editor() {
    cat > "$TEMP_DIR/vdf_edit.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Minimal Steam VDF editor.
Usage:
  vdf_edit.py launch-opts <localconfig.vdf> <appid> <launch_opts>
  vdf_edit.py compat-tool <config.vdf>      <appid> <tool_name>
"""
import sys
import re
import shutil


def find_block_end(content, start):
    depth = 0
    i = start
    in_str = False
    while i < len(content):
        c = content[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def set_kv_in_block(block_body, key, value):
    pattern = re.compile(r'("' + re.escape(key) + r'"\s+)"[^"]*"')
    m = pattern.search(block_body)
    if m:
        return block_body[:m.start()] + m.group(1) + '"' + value + '"' + block_body[m.end():]

    closing = block_body.rfind('}')
    if closing == -1:
        return block_body
    line_start = block_body.rfind('\n', 0, closing)
    raw = block_body[line_start+1:closing] if line_start != -1 else block_body[:closing]
    m2 = re.match(r'^(\s*)', raw)
    indent = (m2.group(1) if m2 else '\t') + '\t'
    insertion = indent + '"' + key + '"\t\t"' + value + '"\n'
    return block_body[:closing] + insertion + block_body[closing:]


def edit_app_block(content, section_open, section_close, appid, mutate_fn):
    inner_start = section_open + 1
    inner = content[inner_start:section_close]
    m_app = re.search(r'"' + re.escape(appid) + r'"\s*(\{)', inner)

    if m_app:
        abs_open = inner_start + m_app.start(1)
        abs_close = find_block_end(content, abs_open)
        if abs_close == -1:
            return content
        body = content[abs_open+1:abs_close]
        new_body = mutate_fn(body)
        return content[:abs_open+1] + new_body + content[abs_close:]
    else:
        line_start = content.rfind('\n', 0, section_close)
        raw = content[line_start+1:section_close] if line_start != -1 else ''
        m_ind = re.match(r'^(\s*)', raw)
        outer = m_ind.group(1) if m_ind else '\t\t\t\t\t'
        new_body = mutate_fn(None)
        if new_body is None:
            new_body = ''
        block = (outer + '"' + appid + '"\n' +
                 outer + '{\n' +
                 new_body +
                 outer + '}\n')
        return content[:section_close] + block + content[section_close:]


def cmd_launch_opts(path, appid, launch_opts):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    m_apps = re.search(r'"[Aa]pps"\s*\{', content)
    if not m_apps:
        print("Error: Apps section not found.", file=sys.stderr)
        sys.exit(1)

    apps_open = m_apps.end() - 1
    apps_close = find_block_end(content, apps_open)
    if apps_close == -1:
        print("Error: Malformed Apps section.", file=sys.stderr)
        sys.exit(1)

    def mutate(body):
        if body is None:
            return '\t\t\t\t\t\t"LaunchOptions"\t\t"' + launch_opts + '"\n'
        return set_kv_in_block(body, 'LaunchOptions', launch_opts)

    new_content = edit_app_block(content, apps_open, apps_close, appid, mutate)

    shutil.copy2(path, path + '.geode-backup')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_content)
    print("OK")


def cmd_compat_tool(path, appid, tool_name):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    m_ctm = re.search(r'"CompatToolMapping"\s*\{', content)
    if not m_ctm:
        print("Error: CompatToolMapping not found.", file=sys.stderr)
        sys.exit(1)

    ctm_open = m_ctm.end() - 1
    ctm_close = find_block_end(content, ctm_open)
    if ctm_close == -1:
        print("Error: Malformed CompatToolMapping.", file=sys.stderr)
        sys.exit(1)

    def mutate(body):
        if body is None:
            return ('\t\t\t\t\t"name"\t\t"' + tool_name + '"\n' +
                    '\t\t\t\t\t"config"\t\t""\n' +
                    '\t\t\t\t\t"Priority"\t\t"250"\n')
        body = set_kv_in_block(body, 'name', tool_name)
        body = set_kv_in_block(body, 'config', '')
        body = set_kv_in_block(body, 'Priority', '250')
        return body

    new_content = edit_app_block(content, ctm_open, ctm_close, appid, mutate)

    shutil.copy2(path, path + '.geode-backup')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_content)
    print("OK")


if __name__ == '__main__':
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)
    cmd, fpath, appid, arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    if cmd == 'launch-opts':
        cmd_launch_opts(fpath, appid, arg)
    elif cmd == 'compat-tool':
        cmd_compat_tool(fpath, appid, arg)
    else:
        print(__doc__)
        sys.exit(1)
PYEOF
    chmod +x "$TEMP_DIR/vdf_edit.py"
}

check_steam_closed() {
    if pgrep -x steam &>/dev/null || pgrep -x "steam.sh" &>/dev/null; then
        echo ""
        echo -e "${YELLOW}Steam is currently running.${NC}"
        echo -e "Steam must be closed before config files can be safely edited."
        if confirm "Close Steam now?"; then
            pkill -x steam 2>/dev/null || pkill -f "steam.sh" 2>/dev/null || true
            echo "Waiting for Steam to exit..."
            local tries=0
            while pgrep -x steam &>/dev/null && [ $tries -lt 10 ]; do
                sleep 1
                tries=$((tries + 1))
            done
            if pgrep -x steam &>/dev/null; then
                echo -e "${YELLOW}Warning:${NC} Steam did not exit cleanly. Config changes may be overwritten."
            else
                echo "Steam closed."
            fi
        else
            echo -e "${YELLOW}Warning:${NC} Proceeding with Steam open — config changes may be overwritten on Steam exit."
        fi
    fi
}

configure_steam() {
    if ! find_steam_root; then
        echo -e "${YELLOW}Warning:${NC} Could not find Steam root. Skipping automatic Steam configuration."
        echo -e "  Set launch options manually in Steam > GD Properties > General:"
        echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
        return 0
    fi

    local config_vdf="$STEAM_ROOT/config/config.vdf"

    if [ -n "$PROTON_NAME" ] && [ -f "$config_vdf" ]; then
        echo -e "  Setting Proton to ${CYAN}$PROTON_NAME${NC}..."
        if $PY_CMD "$TEMP_DIR/vdf_edit.py" compat-tool "$config_vdf" "$GD_APP_ID" "$PROTON_NAME" 2>&1 | grep -q OK; then
            verbose_log "config.vdf updated (backup saved)"
        else
            echo -e "  ${YELLOW}Warning:${NC} Failed to update config.vdf. Set Proton manually in Steam > GD Properties > Compatibility."
        fi
    elif [ -z "$PROTON_NAME" ]; then
        echo -e "  ${YELLOW}Warning:${NC} No Proton selected — skipping Proton config."
        echo -e "  Install GE-Proton via ProtonPlus or ProtonUp-Qt, or enable Proton Experimental in Steam."
    fi

    local found_any=0
    for localconfig in "$STEAM_ROOT/userdata"/*/config/localconfig.vdf; do
        [ -f "$localconfig" ] || continue
        found_any=1
        local uid
        uid="$(basename "$(dirname "$(dirname "$localconfig")")")"
        echo -e "  Writing launch options (Steam user ${CYAN}$uid${NC})..."
        # shellcheck disable=SC2090
        if $PY_CMD "$TEMP_DIR/vdf_edit.py" launch-opts "$localconfig" "$GD_APP_ID" \
                "$LAUNCH_OPTS" 2>&1 | grep -q OK; then
            verbose_log "localconfig.vdf updated for user $uid (backup saved)"
        else
            echo -e "  ${YELLOW}Warning:${NC} Failed to update localconfig.vdf for user $uid."
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        echo -e "  ${YELLOW}Warning:${NC} No localconfig.vdf found. Set launch options manually:"
        echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
    fi
}

json_extract_tag() {
    local json="$1"
    if [ "$JSON_TOOL" = "jq" ]; then
        echo "$json" | jq -r '.tag_name' 2>/dev/null
    else
        echo "$json" | $PY_CMD -c \
            'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null
    fi
}


resolve_tag() {
    if [ "$CHANNEL" = "nightly" ]; then
        TAG="nightly"
        verbose_log "Resolving nightly asset URL from GitHub API..."

        local release_json
        release_json="$(curl -sf 'https://api.github.com/repos/geode-sdk/geode/releases/tags/nightly' || true)"

        [ -n "$release_json" ] || die "Failed to fetch nightly release info from GitHub API."

        if [ "$JSON_TOOL" = "jq" ]; then
            DOWNLOAD_URL="$(echo "$release_json" | jq -r '[.assets[] | select(.name | test("win\\.zip$"))][0].browser_download_url' 2>/dev/null || true)"
        else
            DOWNLOAD_URL="$(echo "$release_json" | $PY_CMD -c \
                'import json,sys,re; assets=json.load(sys.stdin)["assets"]; m=[a for a in assets if re.search(r"win\.zip$",a["name"])]; print(m[0]["browser_download_url"] if m else "")' \
                2>/dev/null || true)"
        fi

        [ -n "${DOWNLOAD_URL:-}" ] && [ "$DOWNLOAD_URL" != "null" ] \
            || die "Could not find a win.zip asset in the nightly release."

        verbose_log "Asset URL: $DOWNLOAD_URL"
        return 0
    fi

    verbose_log "Fetching latest stable version from Geode Index..."
    local index_json
    index_json="$(curl -sf 'https://api.geode-sdk.org/v1/loader/versions/latest?platform=win' || true)"

    if [ -n "$index_json" ]; then
        if [ "$JSON_TOOL" = "jq" ]; then
            TAG="$(echo "$index_json" | jq -r 'if (.payload | type) == "object" then .payload.tag else empty end' 2>/dev/null || true)"
        else
            TAG="$(echo "$index_json" | $PY_CMD -c \
                'import json,sys; d=json.load(sys.stdin); p=d.get("payload"); print(p["tag"] if isinstance(p, dict) else "")' \
                2>/dev/null || true)"
        fi
    fi

    if [ -z "${TAG:-}" ] || [ "${TAG:-}" = "null" ]; then
        verbose_log "Geode Index failed, falling back to GitHub API..."
        local gh_json
        gh_json="$(curl -sf 'https://api.github.com/repos/geode-sdk/geode/releases/latest' || true)"
        TAG="$(json_extract_tag "$gh_json" || true)"
    fi

    [ -n "${TAG:-}" ] && [ "$TAG" != "null" ] \
        || die "Failed to resolve latest stable version from Geode Index or GitHub."

    DOWNLOAD_URL="https://github.com/geode-sdk/geode/releases/download/${TAG}/geode-${TAG}-win.zip"
}


install_geode() {
    [ -d "$GD_PATH" ] || die "GD path is not set or doesn't exist."
    [ -n "$TAG"     ] || die "Release tag is not set."

    echo ""
    echo -e "Downloading ${YELLOW}Geode ${CYAN}${TAG}${NC}..."
    verbose_log "URL: $DOWNLOAD_URL"

    curl -L --progress-bar -o "$TEMP_DIR/geode.zip" "$DOWNLOAD_URL" \
        || die "Download failed."

    echo "Extracting..."
    unzip -qq "$TEMP_DIR/geode.zip" -d "$TEMP_DIR/geode" \
        || die "Failed to extract archive."

    echo "Copying files to Geometry Dash folder..."
    cp -r "$TEMP_DIR/geode"/. "$GD_PATH/"

    echo -e "${GREEN}Done.${NC}"
}


print_banner() {
cat << "EOF"
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
MMMMWKkxkKWMMMMMMMMMMMMMMMMMMMMWKkxkKWMM
MMMMXoxKWM%%%%MMMMMMMMMMMMMMMMMMMMMMMXox
MMWXK,.. ..MXMMMMMMMMMMMMMMMMWK,.. .XMMM
MMNo. . c .,xKWMMMMMMMMMMMMWXx;. c .cXMM
MMXl..;kKl. .oXMMMMMMMMMMWKx;..,ok:.'o0W
WKx,.cKWNk;..lXMMMMMMMMWKx;..,o0NXl. .oN
No. .lXMMWKc.,dKWMMMMMMNo..;d0NWMNx,..lX
Nk:,:kNMMMNk:,ckNMMMMMMNxcxXWMMMMMN0ockN
MWNNNWMMMMMWNNNWMMMMMMMMWWWMMMMMMMMMWWWM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
MMMMMMMNXKXNWMMMMMMMMMMMWNKOKWMMMMMMMMMM
MMMMMMWKdccxXMMMMMMMMMMW0o'.oXMMMMMMMMMM
MMMMMMMNO:.'o0NKkkkkkOXXo. .lXMMMMMMMMMM
MMMMMMMMNx,..;o;.    .:o,..;kNMMMMMMMMMM
MMMMMMMMMNO:     ...     .cKWMMMMMMMMMMM
MMMMMMMMMMNx,. .;dk:.   .;kNMMMMMMMMMMMM
MMMMMMMMMMMN0ocxXWNkl:,:xXWMMMMMMMMMMMMM
MMMMMMMMMMMMMWNWMMMWWNNNWMMMMMMMMMMMMMMM
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM
}


check_dependencies
write_vdf_editor

print_banner
echo ""

run_autodetect

run_wizard

echo ""
echo "Resolving Geode version..."
resolve_tag
echo -e "Tag: ${CYAN}${TAG}${NC}"

check_steam_closed
install_geode

echo ""
echo "Configuring Steam..."
configure_steam

echo ""
echo -e "${GREEN}Geode installed successfully${NC} at ${YELLOW}$GD_PATH${NC}."
if [ -n "$PROTON_NAME" ]; then
    echo -e "Proton: ${CYAN}$PROTON_NAME${NC}"
fi
echo ""
echo -e "Launch options have been written to your Steam config."
echo -e "If Geode doesn't load, verify manually in Steam:"
echo -e "  Right-click GD > Properties > General > Launch Options:"
echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
echo ""
echo "Have fun, larp :P"
