#!/usr/bin/env bash
# Arch Linux (EFI + Btrfs root) | Limine core setup
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

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$1" >&2
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

hook_present() {
    local needle="$1"
    local hook
    for hook in "${EFFECTIVE_HOOKS[@]}"; do
        [[ "$hook" == "$needle" ]] && return 0
    done
    return 1
}

detect_esp_mountpoint() {
    # 1. Prefer bootctl as recommended by Arch Wiki
    if command -v bootctl >/dev/null 2>&1; then
        local esp
        esp="$(bootctl --print-esp-path 2>/dev/null || true)"
        if [[ -n "$esp" ]]; then
            printf '%s\n' "$esp"
            return 0
        fi
    fi

    # 2. Fallback loop for manual discovery
    local candidate fstype
    for candidate in /efi /boot /boot/efi; do
        if mountpoint -q "$candidate"; then
            fstype="$(findmnt -M "$candidate" -no FSTYPE)"
            case "$fstype" in
                vfat|fat|msdos)
                    printf '%s\n' "$candidate"
                    return 0
                    ;;
            esac
        fi
    done
    return 1
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

install_kernel_headers_if_needed() {
    local has_dkms=false
    local moddir pkgbase headers_pkg

    pacman -Q dkms >/dev/null 2>&1 && has_dkms=true
    compgen -G '/var/lib/dkms/*' >/dev/null 2>&1 && has_dkms=true

    [[ "$has_dkms" == true ]] || return 0

    moddir="/usr/lib/modules/$(uname -r)"
    [[ -r "${moddir}/pkgbase" ]] || {
        warn "DKMS detected, but ${moddir}/pkgbase was not found. Skipping header auto-install."
        return 0
    }

    pkgbase="$(<"${moddir}/pkgbase")"
    headers_pkg="${pkgbase}-headers"

    if pacman -Q "$headers_pkg" >/dev/null 2>&1; then
        info "Kernel headers already installed: $headers_pkg"
        return 0
    fi

    if pacman -Si "$headers_pkg" >/dev/null 2>&1; then
        info "DKMS detected; installing matching kernel headers: $headers_pkg"
        sudo pacman -S --needed --noconfirm "$headers_pkg"
    else
        warn "DKMS detected, but no repo package named $headers_pkg was found."
    fi
}

install_repo_packages() {
    sudo pacman -S --needed --noconfirm \
        limine \
        efibootmgr \
        kernel-modules-hook \
        btrfs-progs

    install_kernel_headers_if_needed
}

install_aur_packages() {
    if command -v paru >/dev/null 2>&1; then
        paru -S --needed --noconfirm --skipreview limine-mkinitcpio-hook
    elif command -v yay >/dev/null 2>&1; then
        yay -S --needed --noconfirm \
            --answerdiff None \
            --answerclean None \
            --answeredit None \
            limine-mkinitcpio-hook
    else
        fatal "No supported AUR helper found. Install paru or yay first."
    fi
}

configure_cmdline() {
    local root_source mount_opts root_subvol
    local mapper_name backing_dev luks_uuid root_uuid
    local kernel_cmdline tmp

    get_effective_hooks

    root_source="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
    mount_opts="$(findmnt -no OPTIONS /)"
    root_subvol="$(extract_subvol "$mount_opts" || true)"

    kernel_cmdline="rw rootfstype=btrfs"

    if [[ -n "$root_subvol" ]]; then
        kernel_cmdline+=" rootflags=subvol=/${root_subvol#/}"
    fi

    if [[ "$root_source" == /dev/mapper/* ]]; then
        mapper_name="${root_source##*/}"
        backing_dev="$(sudo cryptsetup status "$root_source" | awk '$1 == "device:" { print $2 }')"
        [[ -n "$backing_dev" ]] || fatal "Root is mapped, but the backing LUKS device could not be determined."

        luks_uuid="$(sudo blkid -s UUID -o value "$backing_dev" || true)"
        [[ -n "$luks_uuid" ]] || fatal "Could not determine the LUKS UUID for $backing_dev"

        if hook_present sd-encrypt; then
            kernel_cmdline+=" rd.luks.name=${luks_uuid}=${mapper_name} root=/dev/mapper/${mapper_name}"
        elif hook_present encrypt; then
            kernel_cmdline+=" cryptdevice=UUID=${luks_uuid}:${mapper_name} root=/dev/mapper/${mapper_name}"
        else
            fatal "Root is on LUKS, but mkinitcpio has neither encrypt nor sd-encrypt in HOOKS."
        fi
    else
        root_uuid="$(findmnt -no UUID / || true)"
        [[ -n "$root_uuid" ]] || root_uuid="$(sudo blkid -s UUID -o value "$root_source" || true)"
        [[ -n "$root_uuid" ]] || fatal "Could not determine the Btrfs UUID for root."
        kernel_cmdline+=" root=UUID=${root_uuid}"
    fi

    if ! hook_present microcode; then
        shopt -s nullglob
        local -a ucode_imgs=(/boot/*-ucode.img)
        shopt -u nullglob
        local img
        for img in "${ucode_imgs[@]}"; do
            kernel_cmdline+=" initrd=/$(basename "$img")"
        done
    fi

    if [[ -n "${EXTRA_KERNEL_CMDLINE:-}" ]]; then
        kernel_cmdline+=" ${EXTRA_KERNEL_CMDLINE}"
    fi

    sudo mkdir -p /etc/kernel
    tmp="$(mktemp)"
    printf '%s\n' "$kernel_cmdline" > "$tmp"

    if ! sudo cmp -s "$tmp" /etc/kernel/cmdline 2>/dev/null; then
        backup_file /etc/kernel/cmdline
        sudo install -m 0644 "$tmp" /etc/kernel/cmdline
        info "Updated /etc/kernel/cmdline"
    else
        info "/etc/kernel/cmdline is already up to date."
    fi

    rm -f "$tmp"
}

configure_limine_defaults() {
    local limine_defaults="/etc/default/limine"
    local esp_target

    if [[ -f /etc/limine-entry-tool.conf && ! -f "$limine_defaults" ]]; then
        sudo install -m 0644 /etc/limine-entry-tool.conf "$limine_defaults"
    else
        sudo touch "$limine_defaults"
    fi

    esp_target="$(detect_esp_mountpoint)" || fatal "Could not detect a mounted ESP at /efi, /boot, or /boot/efi."

    backup_file "$limine_defaults"
    set_shell_var "$limine_defaults" ESP_PATH "$esp_target"
    info "Configured ESP_PATH=${esp_target} in $limine_defaults"
}

get_boot_entries_for_loader() {
    local needle="$1"
    sudo efibootmgr -v | awk -v needle="$needle" '
        BEGIN { IGNORECASE=1 }
        $0 ~ /^Boot[0-9A-F]{4}\*/ && index(tolower($0), tolower(needle)) {
            code = $1
            sub(/^Boot/, "", code)
            sub(/\*.*/, "", code)
            print code
        }
    '
}

has_named_limine_nvram_entry() {
    sudo efibootmgr -v | grep -Eiq '\\EFI\\limine\\limine_x64\.efi'
}

dedupe_named_limine_entries() {
    local -a entries=()
    mapfile -t entries < <(get_boot_entries_for_loader '\\efi\\limine\\limine_x64.efi')

    if ((${#entries[@]} <= 1)); then
        return 0
    fi

    local keep="${entries[0]}"
    local entry
    warn "Multiple NVRAM entries point to \\EFI\\limine\\limine_x64.efi. Keeping Boot${keep} and deleting the extras."

    for entry in "${entries[@]:1}"; do
        sudo efibootmgr -b "$entry" -B >/dev/null
    done
}

rename_fallback_limine_label() {
    local -a entries=()
    mapfile -t entries < <(
        sudo efibootmgr -v | awk '
            BEGIN { IGNORECASE=1 }
            $0 ~ /^Boot[0-9A-F]{4}\*/ &&
            $0 ~ /\\EFI\\BOOT\\BOOTX64\.EFI/ &&
            $0 ~ /\* Limine([[:space:]]|$)/ {
                code = $1
                sub(/^Boot/, "", code)
                sub(/\*.*/, "", code)
                print code
            }
        '
    )

    local entry
    for entry in "${entries[@]}"; do
        sudo efibootmgr -b "$entry" -L "Limine Fallback" >/dev/null
    done
}

deploy_limine() {
    local esp_target
    esp_target="$(detect_esp_mountpoint)" || fatal "Could not detect the ESP mount point."

    dedupe_named_limine_entries

    if [[ ! -f "${esp_target}/EFI/limine/limine_x64.efi" ]] || ! has_named_limine_nvram_entry; then
        info "Installing Limine EFI entry."
        sudo limine-install
    else
        info "Existing Limine EFI entry detected; skipping redundant limine-install."
    fi

    sudo limine-update
    rename_fallback_limine_label

    [[ -f /boot/limine.conf ]] || fatal "Expected /boot/limine.conf was not created."
    info "Limine deployment and update completed successfully."
}

preflight_checks() {
    require_cmd sudo
    require_cmd pacman
    require_cmd findmnt
    require_cmd mountpoint
    require_cmd blkid
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

execute "Install Limine core packages" install_repo_packages
execute "Generate /etc/kernel/cmdline" configure_cmdline
execute "Configure /etc/default/limine" configure_limine_defaults
execute "Install limine-mkinitcpio-hook from the AUR" install_aur_packages
require_cmd limine-install
require_cmd limine-update
execute "Deploy and update Limine" deploy_limine
