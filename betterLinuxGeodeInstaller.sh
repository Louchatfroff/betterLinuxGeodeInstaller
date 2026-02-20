#!/usr/bin/env bash

set -euo pipefail

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

RED='\033[38;2;247;118;142m'
BLUE='\033[38;2;122;162;247m'
YELLOW='\033[38;2;224;175;104m'
CYAN='\033[38;2;115;218;202m'
DARKBLUE='\033[38;2;36;40;59m'
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
PY_CMD=""
JSON_TOOL=""

PROTON_VERSIONS_INTERNAL=()
PROTON_VERSIONS_DISPLAY=()
PROTON_VERSIONS_SOURCE=()


verbose_log() {
    [ -n "${1:-}" ] && [ "$VERBOSE" -eq 1 ] && echo -e "${DIM}[verbose]${NC} $1" || true
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
        die "python3 is not installed."
    fi

    if command -v jq &>/dev/null; then
        JSON_TOOL="jq"
    else
        JSON_TOOL="$PY_CMD"
    fi
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

    if command -v lsmod &>/dev/null && lsmod 2>/dev/null | grep -q '^nvidia '; then
        echo "nvidia"; return
    fi

    [ -f /proc/driver/nvidia/version ] && { echo "nvidia"; return; }

    local f
    for f in /sys/bus/pci/devices/*/vendor /sys/class/drm/card*/device/vendor; do
        [ -f "$f" ] || continue
        local v
        read -r v < "$f" 2>/dev/null || continue
        [ "$v" = "0x10de" ] && { echo "nvidia"; return; }
    done

    if command -v lspci &>/dev/null && lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | grep -qi 'nvidia'; then
        echo "nvidia"; return
    fi

    if command -v vulkaninfo &>/dev/null && vulkaninfo --summary 2>/dev/null | grep -qi 'nvidia'; then
        echo "nvidia"; return
    fi

    if command -v glxinfo &>/dev/null && glxinfo 2>/dev/null | grep -i 'vendor string' | grep -qi 'nvidia'; then
        echo "nvidia"; return
    fi

    echo "other"
}


detect_display_server() {
    case "${XDG_SESSION_TYPE:-}" in
        wayland) echo "wayland"; return ;;
        x11)     echo "x11";     return ;;
    esac

    [ -n "${WAYLAND_DISPLAY:-}" ] && { echo "wayland"; return; }

    local uid
    uid="$(id -u)"
    ls "/run/user/${uid}"/wayland-* &>/dev/null 2>&1 && { echo "wayland"; return; }

    if command -v loginctl &>/dev/null; then
        local st
        st="$(loginctl show-session \
            "$(loginctl list-sessions --no-legend 2>/dev/null \
               | awk -v u="$(whoami)" '$3==u {print $1; exit}')" \
            -p Type --value 2>/dev/null || true)"
        case "${st:-}" in
            wayland) echo "wayland"; return ;;
            x11|mir) echo "x11";    return ;;
        esac
    fi

    [ -n "${DISPLAY:-}" ] && { echo "x11"; return; }
    echo "x11"
}


find_steam_root() {
    [ -n "$STEAM_ROOT" ] && [ -f "$STEAM_ROOT/config/config.vdf" ] && return 0

    local DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

    local steam_pid
    steam_pid="$(pgrep -x steam 2>/dev/null | head -1 || true)"
    if [ -n "$steam_pid" ]; then
        local env_val
        env_val="$(tr '\0' '\n' < "/proc/$steam_pid/environ" 2>/dev/null \
            | grep '^STEAM_DATA_PATH=' | cut -d= -f2- || true)"
        if [ -n "$env_val" ] && [ -f "$env_val/config/config.vdf" ]; then
            STEAM_ROOT="$env_val"; verbose_log "Steam root (proc env): $STEAM_ROOT"; return 0
        fi
        local exe
        exe="$(readlink -f "/proc/$steam_pid/exe" 2>/dev/null || true)"
        if [ -n "$exe" ]; then
            local d try_root
            d="$(dirname "$exe")"
            for try_root in "$d" "$(dirname "$d")"; do
                if [ -f "$try_root/config/config.vdf" ]; then
                    STEAM_ROOT="$try_root"; verbose_log "Steam root (proc exe): $STEAM_ROOT"; return 0
                fi
            done
        fi
    fi

    local sc
    sc="$(command -v steam 2>/dev/null || true)"
    if [ -n "$sc" ]; then
        local rs d try_root
        rs="$(readlink -f "$sc" 2>/dev/null || true)"
        if [ -n "$rs" ]; then
            d="$(dirname "$rs")"
            for try_root in "$d" "$(dirname "$d")"; do
                if [ -f "$try_root/config/config.vdf" ]; then
                    STEAM_ROOT="$try_root"; verbose_log "Steam root (which steam): $STEAM_ROOT"; return 0
                fi
            done
        fi
    fi

    if command -v flatpak &>/dev/null && flatpak info com.valvesoftware.Steam &>/dev/null 2>&1; then
        local fp="$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
        if [ -f "$fp/config/config.vdf" ]; then
            STEAM_ROOT="$fp"; verbose_log "Steam root (flatpak): $STEAM_ROOT"; return 0
        fi
    fi

    local c
    for c in \
        "$DATA_HOME/Steam" \
        "$HOME/.steam/steam" \
        "$HOME/.steam/root" \
        "$HOME/Steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam" \
        "$HOME/snap/steam/common/.steam/steam"
    do
        if [ -f "$c/config/config.vdf" ]; then
            STEAM_ROOT="$c"; verbose_log "Steam root (static): $STEAM_ROOT"; return 0
        fi
    done

    return 1
}


collect_steam_library_paths() {
    local -a libs=()
    [ -n "$STEAM_ROOT" ] && libs+=("$STEAM_ROOT")

    local lf="$STEAM_ROOT/steamapps/libraryfolders.vdf"
    if [ -f "$lf" ]; then
        local line
        while IFS= read -r line; do
            line="$(echo "$line" | sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p')"
            [ -n "$line" ] && [ -d "$line" ] || continue
            local dup=0 e
            for e in "${libs[@]:-}"; do [ "$e" = "$line" ] && { dup=1; break; }; done
            [ "$dup" -eq 0 ] && libs+=("$line")
        done < "$lf"
    fi

    printf '%s\n' "${libs[@]:-}"
}


is_valid_gd_path() {
    if [ -z "${1:-}" ]; then LAST_VALID_GD_PATH_ERR="No path specified."; return 1; fi
    if [ ! -d "$1" ]; then LAST_VALID_GD_PATH_ERR="Path is not a directory."; return 1; fi
    if [ ! -f "$1/libcocos2d.dll" ] && [ ! -f "$1/GeometryDash.exe" ]; then
        LAST_VALID_GD_PATH_ERR="Path doesn't appear to contain Geometry Dash."
        return 1
    fi
    return 0
}


find_gd_installation() {
    find_steam_root || true

    if [ -n "$STEAM_ROOT" ]; then
        while IFS= read -r lib_root; do
            [ -n "$lib_root" ] || continue
            local candidate="$lib_root/steamapps/common/Geometry Dash"
            verbose_log "Testing $candidate"
            if is_valid_gd_path "$candidate"; then
                GD_PATH="$candidate"
                [[ "$candidate" == */snap/steam/* ]] && \
                    echo -e "${YELLOW}Warning:${NC} Steam via Snap is not officially supported."
                verbose_log "Found: $GD_PATH"
                return 0
            fi
        done < <(collect_steam_library_paths)
    fi

    local DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
    local c
    for c in "$HOME/Games/Geometry Dash" "$HOME/games/Geometry Dash" "$DATA_HOME/games/Geometry Dash"; do
        if is_valid_gd_path "$c"; then GD_PATH="$c"; verbose_log "Found (extra): $GD_PATH"; return 0; fi
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
            confirm "  Install ${YELLOW}Geode${NC} to ${YELLOW}$input${NC}?" && { GD_PATH="$input"; return 0; }
        else
            echo -e "  ${RED}Invalid:${NC} $LAST_VALID_GD_PATH_ERR"
        fi
    done
}


read_vdf_internal_name() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    $PY_CMD "$TEMP_DIR/vdf_edit.py" internal-name "$vdf" 2>/dev/null || true
}


read_vdf_display_name() {
    local vdf="$1"
    [ -f "$vdf" ] || return 1
    $PY_CMD "$TEMP_DIR/vdf_edit.py" display-name "$vdf" 2>/dev/null || true
}


_proton_has() {
    local needle="$1" i
    for i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
        [ "${PROTON_VERSIONS_INTERNAL[$i]}" = "$needle" ] && return 0
    done
    return 1
}


_proton_add() {
    local internal="$1" display="$2" source="$3"
    [ -n "$internal" ] || return 0
    _proton_has "$internal" && return 0
    PROTON_VERSIONS_INTERNAL+=("$internal")
    PROTON_VERSIONS_DISPLAY+=("$display")
    PROTON_VERSIONS_SOURCE+=("$source")
    verbose_log "Proton: [$internal] \"$display\" ($source)"
}


_scan_compat_dir() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || return 0

    local folder
    for folder in "$dir"/*/; do
        [ -d "$folder" ] || continue
        local vdf="${folder}compatibilitytool.vdf"
        [ -f "$vdf" ] || continue
        local internal display
        internal="$(read_vdf_internal_name "$vdf")"
        [ -n "$internal" ] || continue
        display="$(read_vdf_display_name "$vdf")"
        [ -n "$display" ] || display="$internal"
        _proton_add "$internal" "$display" "$label"
    done
}


_scan_steamapps_common() {
    local steamapps="$1"
    [ -d "$steamapps/common" ] || return 0

    local folder
    for folder in "$steamapps/common"/Proton*/; do
        [ -d "$folder" ] || continue
        local folder_name internal display
        folder_name="$(basename "$folder")"
        internal=""
        display=""

        local vdf="${folder}compatibilitytool.vdf"
        if [ -f "$vdf" ]; then
            internal="$(read_vdf_internal_name "$vdf")"
            display="$(read_vdf_display_name "$vdf")"
        fi

        if [ -z "$internal" ]; then
            case "$folder_name" in
                "Proton - Experimental"|"Proton - Beta"|"Proton Hotfix")
                    internal="proton_experimental" ;;
                *)
                    local ver
                    ver="$(echo "$folder_name" | grep -oE '[0-9]+' | head -1 || true)"
                    [ -n "$ver" ] && internal="proton_${ver}" || continue
                    ;;
            esac
        fi
        [ -n "$display" ] || display="$folder_name"
        _proton_add "$internal" "$display" "Steam ($steamapps)"
    done
}


collect_all_proton_versions() {
    verbose_log "Collecting Proton versions..."

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

    local seen_real=()
    local dir
    for dir in "${compat_dirs[@]}"; do
        [ -d "$dir" ] || continue
        local real_dir
        real_dir="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
        local dup=0 s
        for s in "${seen_real[@]:-}"; do [ "$s" = "$real_dir" ] && { dup=1; break; }; done
        [ "$dup" -eq 1 ] && continue
        seen_real+=("$real_dir")
        _scan_compat_dir "$dir" "$dir"
    done

    if [ -n "$STEAM_ROOT" ]; then
        while IFS= read -r lib_root; do
            [ -n "$lib_root" ] || continue
            _scan_steamapps_common "$lib_root/steamapps"
        done < <(collect_steam_library_paths)
    fi

    verbose_log "Total Proton versions: ${#PROTON_VERSIONS_INTERNAL[@]}"
}


_best_proton_index() {
    local -a tiers=(
        "^GE-Proton"
        "^proton-cachyos" "^Proton-CachyOS" "^proton_cachyos"
        "^Proton-tkg" "^proton-tkg"
        "^Proton-Sarek" "^proton-sarek"
        "^Proton-EM" "^proton-em"
        "^Kron4ek-Proton" "^kron4ek-proton"
        "^SteamTinkerLaunch"
        "^proton_experimental"
        "^proton_"
    )

    local tier
    for tier in "${tiers[@]}"; do
        local best_idx=-1 best_name="" i
        for i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
            local name="${PROTON_VERSIONS_INTERNAL[$i]}"
            echo "$name" | grep -qE "$tier" || continue
            if [ -z "$best_name" ]; then
                best_idx=$i; best_name="$name"
            else
                local winner
                winner="$(printf '%s\n%s\n' "$best_name" "$name" | sort -V | tail -1)"
                [ "$winner" = "$name" ] && { best_idx=$i; best_name="$name"; }
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
            echo -e "  ${RED}Not a directory.${NC}"; continue
        fi
        local internal display
        internal="$(read_vdf_internal_name "${input}/compatibilitytool.vdf")"
        display="$(read_vdf_display_name "${input}/compatibilitytool.vdf")"
        if [ -n "$internal" ]; then
            PROTON_NAME="$internal"
            CUSTOM_PROTON_PATH="$input"
            echo -e "  Found: ${GREEN}${display:-$internal}${NC}  (internal: $internal)"
            return 0
        fi
        echo -e "  ${YELLOW}Warning:${NC} No compatibilitytool.vdf found — using folder name."
        PROTON_NAME="$(basename "$input")"
        CUSTOM_PROTON_PATH="$input"
        return 0
    done
}


build_launch_opts() {
    LAUNCH_OPTS=""

    [ "$GPU_TYPE" = "nvidia" ] && \
        LAUNCH_OPTS="PROTON_ENABLE_NVAPI=1 PROTON_HIDE_NVIDIA_GPU=0 PROTON_ENABLE_NGX_UPDATER=1 PROTON_ENABLE_NVAPI_REFLEX=1 "

    [ "$DISPLAY_SERVER" = "wayland" ] && \
        LAUNCH_OPTS="${LAUNCH_OPTS}SDL_VIDEODRIVER=wayland "

    LAUNCH_OPTS="${LAUNCH_OPTS}DXVK_ASYNC=1 PROTON_NO_ESYNC=0 PROTON_NO_FSYNC=0 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 VKD3D_CONFIG=dxr11,dxr DXVK_CONFIG_FILE=\$HOME/.config/dxvk/dxvk.conf VKD3D_FEATURE_LEVEL=12_2 WINEDLLOVERRIDES=\"xinput1_4=n,b\" gamemoderun %command%"
}


run_autodetect() {
    echo -e "${DIM}Auto-detecting system configuration...${NC}"

    GPU_TYPE="$(detect_gpu_type)"
    verbose_log "GPU: $GPU_TYPE"

    DISPLAY_SERVER="$(detect_display_server)"
    verbose_log "Display: $DISPLAY_SERVER"

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
    verbose_log "Proton auto-best: ${PROTON_NAME:-(not found)}"

    echo -e "${DIM}Done.${NC}"
}


print_summary() {
    local proton_display="${PROTON_NAME:-(none)}"
    local verbose_display
    [ "$VERBOSE" -eq 1 ] && verbose_display="yes" || verbose_display="no"

    echo ""
    echo -e "${BLUE}┌─ Configuration summary ────────────────────────────────────────────────┐${NC}"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Channel:"   "$CHANNEL"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Game path:" "${GD_PATH:-(not found)}"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Proton:"    "$proton_display"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "GPU:"       "$GPU_TYPE"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Display:"   "$DISPLAY_SERVER"
    printf "${BLUE}│${NC}  %-14s ${YELLOW}%s${NC}\n" "Verbose:"   "$verbose_display"
    echo -e "${BLUE}│${NC}"
    echo -e "${BLUE}│${NC}  Launch options:"
    echo -e "${BLUE}│${NC}  ${CYAN}${LAUNCH_OPTS}${NC}"
    echo -e "${BLUE}└────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${YELLOW}Note:${NC} gamemoderun requires ${BLUE}gamemode${NC} — pacman -S / apt install / dnf install gamemode"
    echo -e "${YELLOW}Note:${NC} DXVK_CONFIG_FILE=\$HOME/.config/dxvk/dxvk.conf — file doesn't need to exist."
    echo ""
}


run_wizard() {
    echo -e "${BLUE}=== Setup Wizard ===${NC}"
    echo -e "${DIM}Each step shows the auto-detected value. Press Enter to accept.${NC}"


    section "Output mode"
    local default_verbose="Quiet"
    [ "$VERBOSE" -eq 1 ] && default_verbose="Verbose"
    pick_option "Output mode ${DIM}(detected: $default_verbose)${NC}" \
        "Quiet   — only show important messages" \
        "Verbose — show every step"
    [ "$PICKED_INDEX" -eq 1 ] && VERBOSE=1 || VERBOSE=0


    section "Geode channel"
    pick_option "Which build of Geode?" \
        "Nightly — latest development build" \
        "Stable  — latest official release"
    [ "$PICKED_INDEX" -eq 0 ] && CHANNEL="nightly" || CHANNEL="stable"


    section "GPU type"
    local gpu_label="AMD / Intel / Other"
    [ "$GPU_TYPE" = "nvidia" ] && gpu_label="Nvidia"
    pick_option "GPU type ${DIM}(detected: $gpu_label)${NC}" \
        "Use detected  [$gpu_label]" \
        "Nvidia  — NVAPI, NGX, Reflex" \
        "AMD / Intel / Other"
    case "$PICKED_INDEX" in
        0) ;;
        1) GPU_TYPE="nvidia" ;;
        2) GPU_TYPE="other" ;;
    esac


    section "Display server"
    pick_option "Display server ${DIM}(detected: $DISPLAY_SERVER)${NC}" \
        "Use detected  [$DISPLAY_SERVER]" \
        "Wayland — adds SDL_VIDEODRIVER=wayland" \
        "X11     — no extra variable"
    case "$PICKED_INDEX" in
        0) ;;
        1) DISPLAY_SERVER="wayland" ;;
        2) DISPLAY_SERVER="x11" ;;
    esac


    section "Geometry Dash location"
    if [ -n "$GD_PATH" ]; then
        pick_option "Game path ${DIM}(detected: $GD_PATH)${NC}" \
            "Use detected  [$GD_PATH]" \
            "Enter manually"
        [ "$PICKED_INDEX" -eq 1 ] && { GD_PATH=""; ask_gd_path; }
    else
        echo -e "  ${YELLOW}Could not auto-detect Geometry Dash.${NC}"
        echo -e "  Common: ${DIM}~/.local/share/Steam/steamapps/common/Geometry Dash${NC}"
        ask_gd_path
    fi


    section "Proton version"
    local _num_found="${#PROTON_VERSIONS_INTERNAL[@]}"

    if [ "$_num_found" -eq 0 ]; then
        echo -e "  ${YELLOW}No Proton versions found.${NC}"
        pick_option "Proton version" \
            "Skip — set manually in Steam later" \
            "Enter a custom Proton path now"
        [ "$PICKED_INDEX" -eq 1 ] && ask_custom_proton || PROTON_NAME=""
    else
        local _best_idx
        _best_idx="$(_best_proton_index || true)"

        local _auto_label="Auto-select best"
        [ -n "$_best_idx" ] && \
            _auto_label="Auto-select best  [${PROTON_VERSIONS_DISPLAY[$_best_idx]} / ${PROTON_VERSIONS_INTERNAL[$_best_idx]}]"

        local -a _opts=("$_auto_label")
        local _i
        for _i in "${!PROTON_VERSIONS_INTERNAL[@]}"; do
            _opts+=("${PROTON_VERSIONS_DISPLAY[$_i]}  ${DIM}(${PROTON_VERSIONS_INTERNAL[$_i]})${NC}  — ${PROTON_VERSIONS_SOURCE[$_i]}")
        done
        _opts+=("Enter a custom Proton path manually")

        echo -e "  Found ${CYAN}$_num_found${NC} Proton version(s)."
        pick_option "Which Proton to assign to Geometry Dash?" "${_opts[@]}"

        if [ "$PICKED_INDEX" -eq 0 ]; then
            [ -n "$_best_idx" ] && PROTON_NAME="${PROTON_VERSIONS_INTERNAL[$_best_idx]}" || PROTON_NAME=""
        elif [ "$PICKED_INDEX" -eq $(( _num_found + 1 )) ]; then
            PROTON_NAME=""; ask_custom_proton
        else
            local _sel=$(( PICKED_INDEX - 1 ))
            PROTON_NAME="${PROTON_VERSIONS_INTERNAL[$_sel]}"
        fi
    fi


    build_launch_opts
    print_summary

    confirm "Proceed with installation?" || { echo "Aborted."; exit 0; }
}


write_vdf_editor() {
    cat > "$TEMP_DIR/vdf_edit.py" << 'PYEOF'
import sys
import re


def find_closing_brace(text, open_pos):
    depth = 0
    i = open_pos
    in_str = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def find_open_brace(text, from_pos):
    in_str = False
    i = from_pos
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch == '{':
                return i
        i += 1
    return -1


def read_string_at(text, pos):
    if pos >= len(text) or text[pos] != '"':
        return None, pos
    i = pos + 1
    buf = []
    while i < len(text):
        ch = text[i]
        if ch == '\\' and i + 1 < len(text):
            buf.append(text[i + 1])
            i += 2
            continue
        if ch == '"':
            return ''.join(buf), i + 1
        buf.append(ch)
        i += 1
    return None, i


def skip_whitespace(text, pos):
    while pos < len(text) and text[pos] in ' \t\r\n':
        pos += 1
    return pos


def next_token(text, pos):
    pos = skip_whitespace(text, pos)
    if pos >= len(text):
        return None, pos, pos
    if text[pos] == '"':
        val, end = read_string_at(text, pos)
        return ('str', val), pos, end
    if text[pos] in '{}':
        return ('brace', text[pos]), pos, pos + 1
    return None, pos, pos + 1


def cmd_internal_name(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            content = f.read()

        m_ct = re.search(r'"compat_tools"\s*\{', content, re.IGNORECASE)
        if m_ct:
            open_b = find_open_brace(content, m_ct.start())
            if open_b != -1:
                close_b = find_closing_brace(content, open_b)
                if close_b != -1:
                    pos = open_b + 1
                    tok, _, _ = next_token(content[pos:close_b], 0)
                    if tok and tok[0] == 'str' and tok[1]:
                        print(tok[1])
                        return

        m_in = re.search(r'"internal_name"\s+"([^"]+)"', content, re.IGNORECASE)
        if m_in:
            print(m_in.group(1))
    except Exception:
        pass


def cmd_display_name(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            content = f.read()
        m = re.search(r'"display_name"\s+"([^"]+)"', content, re.IGNORECASE)
        if m:
            print(m.group(1))
    except Exception:
        pass


def set_or_insert_kv(block_text, key, value):
    pattern = re.compile(r'"' + re.escape(key) + r'"\s+"[^"]*"', re.IGNORECASE)
    m = pattern.search(block_text)
    replacement = '"' + key + '"\t\t"' + value + '"'
    if m:
        return block_text[:m.start()] + replacement + block_text[m.end():]

    lines = block_text.rstrip('\n').split('\n')
    indent = '\t\t\t\t\t\t'
    for line in reversed(lines):
        stripped = line.lstrip()
        if stripped and stripped not in ('{', '}'):
            m2 = re.match(r'^(\s+)', line)
            if m2:
                indent = m2.group(1)
            break
    return block_text.rstrip('\n') + '\n' + indent + replacement + '\n'


def get_or_create_app_block(content, section_open, section_close, appid):
    inner = content[section_open + 1:section_close]
    m = re.search(r'"' + re.escape(appid) + r'"\s*\{', inner)
    if m:
        rel_open = m.end() - 1
        abs_open = section_open + 1 + rel_open
        abs_close = find_closing_brace(content, abs_open)
        if abs_close == -1:
            return None, None, None
        return content, abs_open + 1, abs_close

    line_start = content.rfind('\n', 0, section_close)
    raw = content[line_start + 1:section_close] if line_start != -1 else ''
    m2 = re.match(r'^(\s*)', raw)
    outer = m2.group(1) if m2 else '\t\t\t\t\t'
    inner_ind = outer + '\t'
    new_block = outer + '"' + appid + '"\n' + outer + '{\n' + inner_ind + '\n' + outer + '}\n'
    new_content = content[:section_close] + new_block + content[section_close:]

    offset = section_open + 1
    inner2_end = section_close + len(new_block)
    inner2 = new_content[offset:inner2_end]
    m2b = re.search(r'"' + re.escape(appid) + r'"\s*\{', inner2)
    if not m2b:
        return None, None, None
    rel_open2 = m2b.end() - 1
    abs_open2 = offset + rel_open2
    abs_close2 = find_closing_brace(new_content, abs_open2)
    if abs_close2 == -1:
        return None, None, None
    return new_content, abs_open2 + 1, abs_close2


def cmd_launch_opts(path, appid, launch_opts):
    import shutil
    with open(path, encoding='utf-8', errors='replace') as f:
        content = f.read()

    m_apps = re.search(r'"[Aa]pps"\s*\{', content)
    if not m_apps:
        print("Error: Apps section not found in " + path, file=sys.stderr)
        sys.exit(1)

    apps_open = find_open_brace(content, m_apps.start())
    apps_close = find_closing_brace(content, apps_open)
    if apps_open == -1 or apps_close == -1:
        print("Error: Malformed Apps section.", file=sys.stderr)
        sys.exit(1)

    content, body_start, body_end = get_or_create_app_block(content, apps_open, apps_close, appid)
    if content is None:
        print("Error: Could not locate or create app block.", file=sys.stderr)
        sys.exit(1)

    body = content[body_start:body_end]
    new_body = set_or_insert_kv(body, 'LaunchOptions', launch_opts)
    content = content[:body_start] + new_body + content[body_end:]

    shutil.copy2(path, path + '.geode-backup')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print("OK")


def cmd_compat_tool(path, appid, tool_name):
    import shutil
    with open(path, encoding='utf-8', errors='replace') as f:
        content = f.read()

    m_ctm = re.search(r'"CompatToolMapping"\s*\{', content)
    if not m_ctm:
        print("Error: CompatToolMapping not found.", file=sys.stderr)
        sys.exit(1)

    ctm_open = find_open_brace(content, m_ctm.start())
    ctm_close = find_closing_brace(content, ctm_open)
    if ctm_open == -1 or ctm_close == -1:
        print("Error: Malformed CompatToolMapping.", file=sys.stderr)
        sys.exit(1)

    content, body_start, body_end = get_or_create_app_block(content, ctm_open, ctm_close, appid)
    if content is None:
        print("Error: Could not locate or create app block.", file=sys.stderr)
        sys.exit(1)

    body = content[body_start:body_end]
    body = set_or_insert_kv(body, 'name', tool_name)
    body = set_or_insert_kv(body, 'config', '')
    body = set_or_insert_kv(body, 'Priority', '250')
    content = content[:body_start] + body + content[body_end:]

    shutil.copy2(path, path + '.geode-backup')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print("OK")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(1)
    cmd = sys.argv[1]
    fpath = sys.argv[2]
    if cmd == 'internal-name':
        cmd_internal_name(fpath)
    elif cmd == 'display-name':
        cmd_display_name(fpath)
    elif len(sys.argv) == 5:
        appid, arg = sys.argv[3], sys.argv[4]
        if cmd == 'launch-opts':
            cmd_launch_opts(fpath, appid, arg)
        elif cmd == 'compat-tool':
            cmd_compat_tool(fpath, appid, arg)
        else:
            sys.exit(1)
    else:
        sys.exit(1)
PYEOF
    chmod +x "$TEMP_DIR/vdf_edit.py"
}


check_steam_closed() {
    if pgrep -x steam &>/dev/null || pgrep -x "steam.sh" &>/dev/null; then
        echo ""
        echo -e "${YELLOW}Steam is currently running.${NC}"
        echo "Steam must be closed before config files can be safely edited."
        if confirm "Close Steam now?"; then
            pkill -x steam 2>/dev/null || pkill -f "steam.sh" 2>/dev/null || true
            echo "Waiting for Steam to exit..."
            local tries=0
            while pgrep -x steam &>/dev/null && [ $tries -lt 10 ]; do
                sleep 1; tries=$((tries + 1))
            done
            if pgrep -x steam &>/dev/null; then
                echo -e "${YELLOW}Warning:${NC} Steam did not exit cleanly. Config changes may be overwritten."
            else
                echo "Steam closed."
            fi
        else
            echo -e "${YELLOW}Warning:${NC} Proceeding with Steam open — config changes may be overwritten."
        fi
    fi
}


configure_steam() {
    if ! find_steam_root; then
        echo -e "${YELLOW}Warning:${NC} Could not find Steam root. Set launch options manually:"
        echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
        return 0
    fi

    local config_vdf="$STEAM_ROOT/config/config.vdf"

    if [ -n "$PROTON_NAME" ] && [ -f "$config_vdf" ]; then
        echo -e "  Setting Proton to ${CYAN}$PROTON_NAME${NC}..."
        local result
        result="$($PY_CMD "$TEMP_DIR/vdf_edit.py" compat-tool "$config_vdf" "$GD_APP_ID" "$PROTON_NAME" 2>&1)"
        if echo "$result" | grep -q "^OK"; then
            verbose_log "config.vdf updated"
        else
            echo -e "  ${YELLOW}Warning:${NC} Failed to update config.vdf: $result"
            echo -e "  Set Proton manually: Steam > GD > Properties > Compatibility."
        fi
    elif [ -z "$PROTON_NAME" ]; then
        echo -e "  ${YELLOW}Warning:${NC} No Proton selected — skipping Proton config."
    fi

    local found_any=0
    for localconfig in "$STEAM_ROOT/userdata"/*/config/localconfig.vdf; do
        [ -f "$localconfig" ] || continue
        found_any=1
        local uid
        uid="$(basename "$(dirname "$(dirname "$localconfig")")")"
        echo -e "  Writing launch options (Steam user ${CYAN}$uid${NC})..."
        local result
        result="$($PY_CMD "$TEMP_DIR/vdf_edit.py" launch-opts "$localconfig" "$GD_APP_ID" "$LAUNCH_OPTS" 2>&1)"
        if echo "$result" | grep -q "^OK"; then
            verbose_log "localconfig.vdf updated for user $uid"
        else
            echo -e "  ${YELLOW}Warning:${NC} Failed to update localconfig.vdf for user $uid: $result"
        fi
    done

    if [ "$found_any" -eq 0 ]; then
        echo -e "  ${YELLOW}Warning:${NC} No localconfig.vdf found. Set launch options manually:"
        echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
    fi
}


resolve_tag() {
    if [ "$CHANNEL" = "nightly" ]; then
        TAG="nightly"
        verbose_log "Resolving nightly asset URL..."

        local release_json
        release_json="$(curl -sf 'https://api.github.com/repos/geode-sdk/geode/releases/tags/nightly' || true)"
        [ -n "$release_json" ] || die "Failed to fetch nightly release info."

        if [ "$JSON_TOOL" = "jq" ]; then
            DOWNLOAD_URL="$(echo "$release_json" | jq -r '[.assets[] | select(.name | test("win\\.zip$"))][0].browser_download_url' 2>/dev/null || true)"
        else
            DOWNLOAD_URL="$(echo "$release_json" | $PY_CMD -c \
                'import json,sys,re; a=json.load(sys.stdin)["assets"]; m=[x for x in a if re.search(r"win\.zip$",x["name"])]; print(m[0]["browser_download_url"] if m else "")' \
                2>/dev/null || true)"
        fi

        [ -n "${DOWNLOAD_URL:-}" ] && [ "$DOWNLOAD_URL" != "null" ] \
            || die "Could not find win.zip asset in nightly release."
        verbose_log "Asset URL: $DOWNLOAD_URL"
        return 0
    fi

    verbose_log "Fetching latest stable version..."
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
        if [ "$JSON_TOOL" = "jq" ]; then
            TAG="$(echo "$gh_json" | jq -r '.tag_name' 2>/dev/null || true)"
        else
            TAG="$(echo "$gh_json" | $PY_CMD -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)"
        fi
    fi

    [ -n "${TAG:-}" ] && [ "$TAG" != "null" ] || die "Failed to resolve stable version."
    DOWNLOAD_URL="https://github.com/geode-sdk/geode/releases/download/${TAG}/geode-${TAG}-win.zip"
}


install_geode() {
    [ -d "$GD_PATH" ] || die "GD path not set."
    [ -n "$TAG"     ] || die "Release tag not set."

    echo ""
    echo -e "Downloading ${YELLOW}Geode ${CYAN}${TAG}${NC}..."
    verbose_log "URL: $DOWNLOAD_URL"

    curl -L --progress-bar -o "$TEMP_DIR/geode.zip" "$DOWNLOAD_URL" || die "Download failed."

    echo "Extracting..."
    unzip -qq "$TEMP_DIR/geode.zip" -d "$TEMP_DIR/geode" || die "Failed to extract archive."

    echo "Copying files..."
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
MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMLOUCHATM
EOF
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
[ -n "$PROTON_NAME" ] && echo -e "Proton: ${CYAN}$PROTON_NAME${NC}"
echo ""
echo -e "If Geode doesn't load, verify launch options in Steam:"
echo -e "  Right-click GD > Properties > General > Launch Options:"
echo -e "  ${CYAN}${LAUNCH_OPTS}${NC}"
echo ""
echo "Have fun, larp :p"
#ALL CREDIT FOR ORIGINAL PROJECT, MOD REPO GOES TO GEODE TEAM <3
#ALL CREDIT FOR ORIGINAL PROJECT AND MOD DOCUMENTATION GOES TO GEODE TEAM <3
#ALL CREDIT FOR PROTON PATCHING GOES TO THAT ONE GUY ON REDDIT I DONT REMEMBER AND I CANT FIND <3
#ALL CREDIT FOR PROTON AND STEAM GOES TO VALVE <3
#ALL CREDIT FOR REPETITIVE AND ANNOYING TASKS AND STEAM FILES TROUBLESHOOTING GOES TO CLAUDE AI
