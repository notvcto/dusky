#!/usr/bin/env bash
# ==============================================================================
# Script Name: tty_autologin_manager.sh
# Description: Manages systemd TTY1 autologin for Arch Linux (Hyprland/UWSM).
#              Surgically idempotent, non-interactive capable, chroot-safe,
#              safe against sudo stripping, and maintains state for dusky.
#              Automatically targets all identified standard users.
# ==============================================================================

set -euo pipefail

# --- Constants & Styling ---
readonly SYSTEMD_UNIT="getty@tty1.service"
readonly SYSTEMD_DIR="/etc/systemd/system/${SYSTEMD_UNIT}.d"
readonly OVERRIDE_FILE="${SYSTEMD_DIR}/override.conf"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly BLUE=$'\033[0;34m'
readonly YELLOW=$'\033[1;33m'
readonly NC=$'\033[0m'

# --- State Variables ---
MODE_AUTO=false
MODE_REVERT=false
CONFIRMED=false
TARGET_USER_OVERRIDE=""

# --- Logging ---
log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- CLI Parsing ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--auto)       MODE_AUTO=true ;;
            -r|--revert)     MODE_REVERT=true ;;
            -u|--user)       TARGET_USER_OVERRIDE="$2"; shift ;;
            --_confirmed)    CONFIRMED=true ;; # Internal flag for sudo escalation
            -h|--help)
                printf "Usage: %s [OPTIONS]\n" "${0##*/}"
                printf "Options:\n"
                printf "  -a, --auto        Run non-interactively (skip prompts)\n"
                printf "  -r, --revert      Revert autologin and restore standard TTY/SDDM\n"
                printf "  -u, --user <name> Explicitly set target user (Overrides auto-detection)\n"
                printf "  -h, --help        Show this help message\n"
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done
}

# --- Environment Detection ---

# Check if SDDM is installed by inspecting the unit file on disk.
sddm_is_installed() {
    [[ -f "/usr/lib/systemd/system/sddm.service" ]]
}

# Determine if systemd is the active init system for THIS root namespace.
is_systemd_active() {
    local pid1_comm pid1_root_inode our_root_inode

    pid1_comm=$(cat /proc/1/comm 2>/dev/null) || return 1
    [[ "${pid1_comm}" == "systemd" ]] || return 1

    pid1_root_inode=$(stat -Lc %i /proc/1/root 2>/dev/null) || return 1
    our_root_inode=$(stat -c %i /              2>/dev/null) || return 1

    [[ "${pid1_root_inode}" == "${our_root_inode}" ]]
}

# --- Helpers ---
sync_state_file() {
    local user="$1"
    local state="$2"
    local user_home
    local user_group

    user_home=$(getent passwd "${user}" | cut -d: -f6)
    user_group=$(id -gn "${user}")

    if [[ -z "${user_home}" ]]; then
        log_error "Could not determine home directory for user: ${user}"
        exit 1
    fi

    local config_dir="${user_home}/.config"
    local state_dir="${config_dir}/dusky/settings"
    local state_file="${state_dir}/auto_login_tty"

    if [[ ! -d "${config_dir}" ]]; then
        mkdir -p "${config_dir}"
        chown "${user}:${user_group}" "${config_dir}"
    fi

    mkdir -p "${state_dir}"
    echo "${state}" > "${state_file}"
    chown -R "${user}:${user_group}" "${config_dir}/dusky"

    log_info "Dusky state synced: ${state_file} -> [${state}]"
}

# --- Interactivity ---
prompt_user() {
    local action="$1"
    local target_list="$2"

    [[ "${MODE_AUTO}" == true || "${CONFIRMED}" == true ]] && return 0

    printf "\n${YELLOW}Arch Linux TTY1 Autologin Manager${NC}\n"

    if [[ "${action}" == "setup" ]]; then
        printf "Action: ${GREEN}ENABLE${NC} autologin for user(s): ${GREEN}%s${NC}\n" "${target_list}"
    else
        printf "Action: ${RED}REVERT${NC} autologin and restore default behavior.\n"
    fi

    read -r -p "Proceed? [y/N] " response
    if [[ ! "${response}" =~ ^[yY](es)?$ ]]; then
        log_info "Operation cancelled by user."
        exit 0
    fi
}

# --- Core Logic ---
do_setup() {
    local user="$1"
    log_info "Configuring TTY1 autologin for: ${user}"

    if sddm_is_installed && systemctl is-enabled --quiet sddm.service 2>/dev/null; then
        log_info "Disabling SDDM..."
        systemctl disable sddm.service --quiet 2>/dev/null || true
        log_success "SDDM disabled."
    fi

    local expected_exec="ExecStart=-/usr/bin/agetty --autologin ${user} --noclear --noissue %I \$TERM"
    if [[ -f "${OVERRIDE_FILE}" ]] && grep -qF -- "${expected_exec}" "${OVERRIDE_FILE}"; then
        sync_state_file "${user}" "true"
        log_success "Autologin is already correctly configured for ${user}. Nothing to do."
        return 0
    fi

    mkdir -p "${SYSTEMD_DIR}"

    cat > "${OVERRIDE_FILE}" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${user} --noclear --noissue %I \$TERM
EOF

    if is_systemd_active; then
        systemctl daemon-reload
        log_info "systemd daemon reloaded."
    else
        log_info "Non-live environment detected; skipping daemon-reload (will take effect on boot)."
    fi

    sync_state_file "${user}" "true"
    log_success "Autologin configured successfully for ${user}."
}

do_revert() {
    local user="$1"
    log_info "Reverting TTY1 autologin configuration for ${user}..."
    local changed=false

    if [[ -f "${OVERRIDE_FILE}" ]]; then
        rm -f "${OVERRIDE_FILE}"
        rmdir --ignore-fail-on-non-empty "${SYSTEMD_DIR}" 2>/dev/null || true
        if is_systemd_active; then
            systemctl daemon-reload
            log_info "systemd daemon reloaded."
        else
            log_info "Non-live environment detected; skipping daemon-reload."
        fi
        changed=true
        log_success "Removed autologin drop-in override for ${SYSTEMD_UNIT}."
    fi

    if sddm_is_installed && ! systemctl is-enabled --quiet sddm.service 2>/dev/null; then
        log_info "Re-enabling SDDM..."
        systemctl enable sddm.service --quiet 2>/dev/null || true
        changed=true
        log_success "SDDM enabled."
    fi

    sync_state_file "${user}" "false"

    if [[ "${changed}" == true ]]; then
        log_success "Revert complete. Standard TTY login / Display Manager restored."
    else
        log_success "System already in default state. Nothing to revert."
    fi
}

# --- Entry Point ---
main() {
    parse_args "$@"

    # 1. Determine Target Context (Autonomous Discovery)
    local -a target_users=()

    if [[ -n "${TARGET_USER_OVERRIDE}" ]]; then
        target_users=("${TARGET_USER_OVERRIDE}")
    else
        # Dynamically identify all standard users (UID >= 1000, excluding nobody/nfsnobody)
        mapfile -t target_users < <(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd)

        if [[ ${#target_users[@]} -eq 0 ]]; then
            log_error "No standard human users (UID >= 1000) identified on this system."
            log_error "Create a user first, or specify one explicitly with '-u <username>'."
            exit 1
        fi
    fi

    # 2. Validate User Existence
    for target in "${target_users[@]}"; do
        if ! id -u "${target}" &>/dev/null; then
            log_error "User '${target}' does not exist on this system."
            exit 1
        fi
    done

    # 3. State Resolution & Prompting
    local action_type="setup"
    [[ "${MODE_REVERT}" == true ]] && action_type="revert"

    # Convert array to space-separated string for prompt message
    prompt_user "${action_type}" "${target_users[*]}"

    # 4. Privilege Escalation
    if [[ "${EUID}" -ne 0 ]]; then
        log_info "Escalating privileges..."

        if [[ ! -f "$0" ]] || [[ ! -r "$0" ]]; then
            log_error "Cannot re-execute: script path '$0' is not a regular readable file."
            exit 1
        fi

        local exec_args=("--_confirmed")
        [[ -n "${TARGET_USER_OVERRIDE}" ]] && exec_args+=("-u" "${TARGET_USER_OVERRIDE}")
        [[ "${MODE_AUTO}" == true ]] && exec_args+=("--auto")
        [[ "${MODE_REVERT}" == true ]] && exec_args+=("--revert")

        exec sudo "$0" "${exec_args[@]}"
    fi

    # 5. Execution Routine (Targets every identified user)
    for target in "${target_users[@]}"; do
        if [[ "${MODE_REVERT}" == true ]]; then
            do_revert "${target}"
        else
            do_setup "${target}"
        fi
    done
}

main "$@"
