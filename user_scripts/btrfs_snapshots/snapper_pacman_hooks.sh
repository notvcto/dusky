#!/usr/bin/env bash
# Arch Linux (EFI + Btrfs root) | OverlayFS + snap-pac + limine-snapper-sync
# Bash 5.3+

set -Eeuo pipefail
export LC_ALL=C
trap 'printf "\n\033[1;31m[FATAL]\033[0m Script failed at line %d. Command: %s\n" "$LINENO" "$BASH_COMMAND" >&2; trap - ERR' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

declare -A BACKED_UP=()

fatal() {
    printf '\033[1;31m[FATAL]\033[0m %s\n' "$1" >&2
    exit 1
}

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$1"
}

cleanup() {
    kill "${SUDO_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -r -p "Execute this step? [Y/n] " response || fatal "Input closed; aborting."
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then
            info "Skipped."
            return 0
        fi
        "$@"
    fi
}

backup_file() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    [[ -n "${BACKED_UP["$file"]+x}" ]] && return 0
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    sudo cp -a -- "$file" "${file}.bak.${stamp}"
    BACKED_UP["$file"]=1
    info "Backup created: ${file}.bak.${stamp}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

extract_subvol() {
    local opts="$1"
    local opt value
    local -a parts=()

    IFS=',' read -r -a parts <<< "$opts"
    for opt in "${parts[@]}"; do
        case "$opt" in
            subvol=*)
                value="${opt#subvol=}"
                value="${value#/}"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done
    return 1
}

collect_mkinitcpio_files() {
    local -a files=("/etc/mkinitcpio.conf")
    local file

    shopt -s nullglob
    for file in /etc/mkinitcpio.conf.d/*.conf; do
        files+=("$file")
    done
    shopt -u nullglob

    printf '%s\n' "${files[@]}"
}

find_last_hooks_file() {
    local file line last_file=""
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*HOOKS[[:space:]]*= ]] && last_file="$file"
        done < "$file"
    done < <(collect_mkinitcpio_files)

    [[ -n "$last_file" ]] || return 1
    printf '%s\n' "$last_file"
}

EFFECTIVE_HOOKS=()

get_effective_hooks() {
    local hooks_file hooks_line contents
    hooks_file="$(find_last_hooks_file)" || fatal "Could not find an active HOOKS= line in mkinitcpio config."

    hooks_line="$(grep -E '^[[:space:]]*HOOKS[[:space:]]*=' "$hooks_file" | tail -n1 || true)"
    [[ -n "$hooks_line" ]] || fatal "Could not read HOOKS= from $hooks_file"

    if [[ "$hooks_line" =~ ^[[:space:]]*HOOKS[[:space:]]*=[[:space:]]*\((.*)\)[[:space:]]*$ ]]; then
        contents="${BASH_REMATCH[1]}"
    else
        fatal "Unsupported HOOKS= format in $hooks_file"
    fi

    EFFECTIVE_HOOKS=()
    read -r -a EFFECTIVE_HOOKS <<< "$contents"
}

write_hooks_file() {
    local file="$1"
    shift
    local -a hooks=("$@")
    local new_line="HOOKS=(${hooks[*]})"
    local tmp

    tmp="$(mktemp)"
    awk -v newline="$new_line" '
        /^[[:space:]]*HOOKS[[:space:]]*=/ { last = NR }
        { lines[NR] = $0 }
        END {
            if (!last) {
                lines[++NR] = newline
                last = NR
            }
            for (i = 1; i <= NR; i++) {
                if (i == last) {
                    print newline
                } else {
                    print lines[i]
                }
            }
        }
    ' "$file" > "$tmp"

    sudo install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

set_shell_var() {
    local file="$1"
    local key="$2"
    local value="$3"
    local escaped_value
    escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    escaped_value="${escaped_value//|/\\|}"

    sudo touch "$file"

    if sudo grep -qE "^[[:space:]]*${key}=" "$file"; then
        sudo sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${escaped_value}\"|" "$file"
    else
        printf '%s="%s"\n' "$key" "$value" | sudo tee -a "$file" >/dev/null
    fi
}

set_ini_key() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    local tmp

    sudo touch "$file"
    tmp="$(mktemp)"

    awk -v section="$section" -v key="$key" -v value="$value" '
        function print_key() {
            print key " = " value
            key_written = 1
        }

        BEGIN {
            in_section = 0
            section_found = 0
            key_written = 0
        }

        /^\[[^]]+\][[:space:]]*$/ {
            if (in_section && !key_written) {
                print_key()
            }

            current = $0
            gsub(/^\[/, "", current)
            gsub(/\]$/, "", current)

            in_section = (current == section)
            if (in_section) {
                section_found = 1
                key_written = 0
            }

            print
            next
        }

        {
            if (in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!key_written) {
                    print_key()
                }
                next
            }
            print
        }

        END {
            if (in_section && !key_written) {
                print_key()
            } else if (!section_found) {
                print ""
                print "[" section "]"
                print key " = " value
            }
        }
    ' "$file" > "$tmp"

    sudo install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

install_snap_pac() {
    sudo pacman -S --needed --noconfirm snap-pac
}

install_aur_packages() {
    local -a pkgs=(limine-snapper-sync)
    command -v limine-update >/dev/null 2>&1 || pkgs+=(limine-mkinitcpio-hook)

    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm --skipreview "${pkgs[@]}"
    elif command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm \
            --answerdiff None \
            --answerclean None \
            --answeredit None \
            "${pkgs[@]}"
    else
        fatal "No supported AUR helper found. Install paru or yay first."
    fi
}

configure_mkinitcpio_overlay_hook() {
    local hooks_file
    hooks_file="$(find_last_hooks_file)" || fatal "Could not find the active mkinitcpio HOOKS file."

    get_effective_hooks

    local target_hook="btrfs-overlayfs"
    local hook
    for hook in "${EFFECTIVE_HOOKS[@]}"; do
        if [[ "$hook" == "systemd" ]]; then
            target_hook="sd-btrfs-overlayfs"
            break
        fi
    done

    local -a filtered_hooks=()
    local found_filesystems=false
    for hook in "${EFFECTIVE_HOOKS[@]}"; do
        case "$hook" in
            btrfs-overlayfs|sd-btrfs-overlayfs)
                continue
                ;;
        esac
        filtered_hooks+=("$hook")
        [[ "$hook" == "filesystems" ]] && found_filesystems=true
    done

    [[ "$found_filesystems" == true ]] || fatal "'filesystems' is missing from mkinitcpio HOOKS."

    local -a final_hooks=()
    for hook in "${filtered_hooks[@]}"; do
        final_hooks+=("$hook")
        if [[ "$hook" == "filesystems" ]]; then
            final_hooks+=("$target_hook")
        fi
    done

    if [[ "${EFFECTIVE_HOOKS[*]}" == "${final_hooks[*]}" ]]; then
        info "${target_hook} is already configured in ${hooks_file}"
        return 0
    fi

    backup_file "$hooks_file"
    write_hooks_file "$hooks_file" "${final_hooks[@]}"
    info "Injected ${target_hook} into ${hooks_file}"
}

rebuild_initramfs() {
    sudo limine-update
}

configure_sync_daemon() {
    local conf_file="/etc/limine-snapper-sync.conf"
    local root_subvol root_subvol_path

    [[ -f "$conf_file" ]] || fatal "$conf_file was not found. limine-snapper-sync is probably not installed."

    root_subvol="$(extract_subvol "$(findmnt -no OPTIONS /)" || true)"
    if [[ -n "$root_subvol" ]]; then
        root_subvol_path="/${root_subvol#/}"
    else
        root_subvol_path="/"
    fi

    backup_file "$conf_file"
    set_shell_var "$conf_file" ROOT_SUBVOLUME_PATH "$root_subvol_path"
    set_shell_var "$conf_file" ROOT_SNAPSHOTS_PATH "/@snapshots"
    info "Configured limine-snapper-sync paths."
}

configure_snap_pac() {
    local ini="/etc/snap-pac.ini"
    backup_file "$ini"
    set_ini_key "$ini" root snapshot yes
    set_ini_key "$ini" home snapshot no
    info "Configured snap-pac."
}

enable_services_and_sync() {
    findmnt -M /.snapshots >/dev/null 2>&1 || fatal "/.snapshots is not mounted."
    sudo snapper -c root get-config >/dev/null 2>&1 || fatal "Snapper root config is missing."

    sudo systemctl daemon-reload
    sudo systemctl enable --now snapper-cleanup.timer
    sudo systemctl enable --now limine-snapper-sync.service

    local snapshot_count
    snapshot_count="$(sudo snapper -c root list | awk '$1 ~ /^[0-9]+$/ { count++ } END { print count + 0 }')"

    if (( snapshot_count == 0 )); then
        sudo snapper -c root create -t single -c important -d "Baseline after Limine + Snapper integration"
        info "Created baseline root snapshot."
    else
        info "Root snapshots already exist; not creating a duplicate baseline."
    fi

    sudo limine-snapper-sync
    info "Boot menu sync completed."
}

preflight_checks() {
    require_cmd sudo
    require_cmd pacman
    require_cmd findmnt
    require_cmd awk
    require_cmd sed

    [[ -d /sys/firmware/efi ]] || fatal "System is not booted in EFI mode."
    [[ "$(stat -f -c %T /)" == "btrfs" ]] || fatal "Root filesystem is not Btrfs."

    sudo -v || fatal "Cannot obtain sudo privileges."
    (
        while true; do
            sudo -n -v 2>/dev/null || exit
            sleep 240
        done
    ) &
    SUDO_PID=$!
}

preflight_checks

execute "Install snap-pac from the repo" install_snap_pac
execute "Install limine-snapper-sync from the AUR" install_aur_packages
require_cmd limine-update
require_cmd limine-snapper-sync
execute "Inject the correct OverlayFS hook into mkinitcpio" configure_mkinitcpio_overlay_hook
execute "Rebuild initramfs and Limine config" rebuild_initramfs
execute "Configure limine-snapper-sync" configure_sync_daemon
execute "Configure snap-pac" configure_snap_pac
execute "Enable cleanup + sync services and perform initial sync" enable_services_and_sync
