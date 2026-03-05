#!/usr/bin/env bash
# Arch Linux (Btrfs root) | Root Snapper isolated @snapshots setup
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

strip_subvol_opts() {
    local opts="$1"
    local opt
    local -a parts=()
    local -a kept=()

    IFS=',' read -r -a parts <<< "$opts"
    for opt in "${parts[@]}"; do
        case "$opt" in
            subvol=*|subvolid=*)
                ;;
            *)
                kept+=("$opt")
                ;;
        esac
    done

    local joined=""
    if ((${#kept[@]} > 0)); then
        joined="${kept[0]}"
        local i
        for ((i = 1; i < ${#kept[@]}; i++)); do
            joined+=",${kept[i]}"
        done
    fi
    printf '%s\n' "$joined"
}

get_root_source() {
    findmnt -no SOURCE / | sed 's/\[.*\]//'
}

get_root_uuid() {
    findmnt -no UUID /
}

get_root_mount_opts() {
    findmnt -no OPTIONS /
}

install_packages() {
    sudo pacman -S --needed --noconfirm snapper btrfs-progs
}

ensure_root_snapper_config() {
    if sudo snapper -c root get-config >/dev/null 2>&1; then
        info "Snapper root config already exists."
    else
        sudo snapper -c root create-config /
        info "Created Snapper root config."
    fi
}

ensure_top_level_snapshots_subvolume() {
    local root_source tmp_mnt
    root_source="$(get_root_source)"
    [[ -n "$root_source" ]] || fatal "Could not determine the root source device."

    tmp_mnt="$(mktemp -d)"
    sudo mount -o subvolid=5 "$root_source" "$tmp_mnt"

    if sudo btrfs subvolume show "${tmp_mnt}/@snapshots" >/dev/null 2>&1; then
        info "Top-level subvolume @snapshots already exists."
    else
        sudo btrfs subvolume create "${tmp_mnt}/@snapshots"
        info "Created top-level subvolume @snapshots."
    fi

    sudo umount "$tmp_mnt"
    rmdir "$tmp_mnt"
}

remove_nested_root_snapshots_subvolume() {
    sudo umount /.snapshots 2>/dev/null || true

    if sudo btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        local -a child_ids=()
        mapfile -t child_ids < <(sudo btrfs subvolume list -o /.snapshots | awk '{print $2}' | sort -rn || true)

        local id
        for id in "${child_ids[@]}"; do
            [[ -n "$id" ]] || continue
            sudo btrfs subvolume delete --subvolid "$id" /
        done

        sudo btrfs subvolume delete /.snapshots
        info "Removed nested /.snapshots subvolume."
    fi

    sudo mkdir -p /.snapshots
}

ensure_fstab_entry_for_root_snapshots() {
    local fs_uuid root_opts cleaned_opts mount_opts newline tmp
    fs_uuid="$(get_root_uuid)"
    [[ -n "$fs_uuid" ]] || fatal "Could not determine the Btrfs UUID for /"

    root_opts="$(get_root_mount_opts)"
    cleaned_opts="$(strip_subvol_opts "$root_opts")"

    mount_opts="$cleaned_opts"
    [[ -n "$mount_opts" ]] && mount_opts+=","
    mount_opts+="subvol=/@snapshots"

    newline="UUID=${fs_uuid} /.snapshots btrfs ${mount_opts} 0 0"

    backup_file /etc/fstab
    tmp="$(mktemp)"
    awk -v mp='/.snapshots' -v newline="$newline" '
        BEGIN { done = 0 }
        $0 ~ /^[[:space:]]*#/ { print; next }
        $2 == mp {
            if (!done) {
                print newline
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print newline
            }
        }
    ' /etc/fstab > "$tmp"

    sudo install -m 0644 "$tmp" /etc/fstab
    rm -f "$tmp"
    sudo systemctl daemon-reload
    info "Ensured /.snapshots entry in /etc/fstab"
}

mount_root_snapshots() {
    sudo mkdir -p /.snapshots
    sudo mount /.snapshots

    findmnt -M /.snapshots >/dev/null 2>&1 || fatal "Mount of /.snapshots failed."
    sudo chmod 750 /.snapshots

    local mounted_opts mounted_subvol
    mounted_opts="$(findmnt -M /.snapshots -no OPTIONS)"
    mounted_subvol="$(extract_subvol "$mounted_opts" || true)"
    [[ "$mounted_subvol" == "@snapshots" ]] || fatal "/.snapshots is mounted, but not from subvol=/@snapshots"

    info "/.snapshots is mounted from @snapshots"
}

tune_snapper() {
    sudo snapper -c root set-config \
        TIMELINE_CREATE="no" \
        NUMBER_CLEANUP="yes" \
        NUMBER_LIMIT="10" \
        NUMBER_LIMIT_IMPORTANT="5" \
        SPACE_LIMIT="0.0" \
        FREE_LIMIT="0.0"

    sudo btrfs quota disable / 2>/dev/null || true
    info "Applied Snapper retention settings for root."
}

preflight_checks() {
    require_cmd sudo
    require_cmd pacman
    require_cmd findmnt
    require_cmd mountpoint
    require_cmd btrfs
    require_cmd snapper
    require_cmd awk
    require_cmd sed

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

execute "Install Snapper packages" install_packages
execute "Create Snapper root config" ensure_root_snapper_config
execute "Create top-level @snapshots subvolume" ensure_top_level_snapshots_subvolume
execute "Remove any nested /.snapshots subvolume" remove_nested_root_snapshots_subvolume
execute "Write /.snapshots mount to /etc/fstab" ensure_fstab_entry_for_root_snapshots
execute "Mount /.snapshots from @snapshots" mount_root_snapshots
execute "Apply Snapper cleanup settings" tune_snapper
