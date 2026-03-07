#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Rofi Wallpaper Selector
# Target: Arch Linux / Hyprland / Dusky / UWSM
# -----------------------------------------------------------------------------

set -Eeuo pipefail

readonly APP_NAME="Wallpaper Menu"
readonly SCRIPT_NAME="${0##*/}"

readonly LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rofi-wallpaper-selector.lock"

readonly WALLPAPER_DIR="$HOME/Pictures/wallpapers"
readonly SETTINGS_DIR="$HOME/.config/dusky/settings"
readonly FAVORITES_FILE="$SETTINGS_DIR/wal_fav_rofi"

readonly THUMB_SIZE=300
readonly CACHE_VERSION=4
readonly CACHE_DIR="$HOME/.cache/rofi-wallpaper-thumbs/v${CACHE_VERSION}-${THUMB_SIZE}"
readonly THUMB_DIR="$CACHE_DIR/thumbs"
readonly CACHE_FILE="$CACHE_DIR/rofi_input.cache"
readonly FAVORITES_CACHE_FILE="$CACHE_DIR/rofi_input_fav.cache"
readonly SOURCE_STATE_FILE="$CACHE_DIR/source.state"
readonly PLACEHOLDER="$CACHE_DIR/_placeholder.png"

readonly ROFI_THEME="$HOME/.config/rofi/wallpaper.rasi"
readonly LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rofi-wallpaper-selector"
readonly LOG_FILE="$LOG_DIR/wallpaper-selector.log"

readonly -a MATUGEN_ARGS=(--mode dark)

declare -ag TEMP_FILES=()
declare -gi SHOW_FAVORITES=0
declare -gi FORCE_REBUILD=0
declare -gi MAX_JOBS=1

log() {
  local level=$1
  shift

  local ts line
  printf -v ts '%(%F %T)T' -1
  printf -v line '[%s] [%s] [pid=%s] %s' "$ts" "$level" "$BASHPID" "$*"

  printf '%s\n' "$line" >&2
  { printf '%s\n' "$line" >>"$LOG_FILE"; } 2>/dev/null || true
}

log_output() {
  local level=$1
  local prefix=$2
  local text=${3-}
  local line

  if [[ -z $text ]]; then
    log "$level" "$prefix"
    return 0
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    log "$level" "${prefix}${line}"
  done <<<"$text"
}

notify() {
  local summary=$1
  local body=${2-}
  local urgency=${3:-low}
  local timeout=${4:-1500}

  if command -v notify-send >/dev/null 2>&1; then
    if [[ -n $body ]]; then
      notify-send -a "$APP_NAME" "$summary" "$body" -u "$urgency" -t "$timeout" >/dev/null 2>&1 || true
    else
      notify-send -a "$APP_NAME" "$summary" -u "$urgency" -t "$timeout" >/dev/null 2>&1 || true
    fi
  else
    if [[ -n $body ]]; then
      printf '%s: %s\n' "$summary" "$body" >&2
    else
      printf '%s\n' "$summary" >&2
    fi
  fi
}

die() {
  local summary=$1
  local body=${2-}
  local notify_body

  if [[ -n $body ]]; then
    log_output ERROR "${summary}: " "$body"
    notify_body="${body}"$'\n'"Log: $LOG_FILE"
  else
    log ERROR "$summary"
    notify_body="Log: $LOG_FILE"
  fi

  notify "$summary" "$notify_body" critical 5000
  exit 1
}

register_temp() {
  TEMP_FILES+=("$1")
}

cleanup_temps() {
  local tmp
  for tmp in "${TEMP_FILES[@]}"; do
    [[ -n $tmp ]] && rm -f -- "$tmp"
  done
}

on_err() {
  local rc=$?
  set +e
  log ERROR "Unhandled error at line ${BASH_LINENO[0]} while running: ${BASH_COMMAND} (exit ${rc})"
  exit "$rc"
}

trap cleanup_temps EXIT

setup_logging() {
  mkdir -p -- "$LOG_DIR" 2>/dev/null || true
  touch -- "$LOG_FILE" 2>/dev/null || true
  log INFO "===== ${SCRIPT_NAME} start ====="
  log INFO "Log file: $LOG_FILE"
}

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    log INFO "Another instance is already running."
    notify "Wallpaper selector already running."
    exit 0
  fi
}

parse_args() {
  while (($#)); do
    case $1 in
      fav|favorites)
        SHOW_FAVORITES=1
        ;;
      --rebuild-cache|rebuild-cache)
        FORCE_REBUILD=1
        ;;
      -h|--help)
        printf 'Usage: %s [fav|favorites] [--rebuild-cache]\n' "$SCRIPT_NAME"
        exit 0
        ;;
      *)
        die "Unknown argument." "$1"
        ;;
    esac
    shift
  done
}

check_dependencies() {
  local -a missing=()
  local cmd

  for cmd in rofi swww magick matugen uwsm-app setsid flock sha256sum find sort xargs cmp stat nproc; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if ((${#missing[@]})); then
    local joined
    printf -v joined '%s, ' "${missing[@]}"
    die "Missing dependency." "${joined%, }"
  fi
}

initialize_runtime() {
  MAX_JOBS=$(nproc)
  ((MAX_JOBS > 0)) || MAX_JOBS=1
  log INFO "Parallel thumbnail jobs: $MAX_JOBS"
}

validate_config() {
  [[ -d "$WALLPAPER_DIR" ]] || die "Wallpaper directory not found." "$WALLPAPER_DIR"
  [[ -r "$WALLPAPER_DIR" ]] || die "Wallpaper directory is not readable." "$WALLPAPER_DIR"

  mkdir -p -- \
    "$CACHE_DIR" \
    "$THUMB_DIR" \
    "$SETTINGS_DIR" \
    "$(dirname -- "$LOCK_FILE")" \
    "$LOG_DIR"
}

ensure_placeholder() {
  [[ -f "$PLACEHOLDER" ]] && return 0

  local tmp output
  tmp=$(mktemp --tmpdir="$CACHE_DIR" --suffix=.png placeholder.tmp.XXXXXX)
  register_temp "$tmp"

  if ! output=$(magick \
    -size "${THUMB_SIZE}x${THUMB_SIZE}" \
    xc:"#333333" \
    "$tmp" 2>&1); then
    die "Failed to create placeholder thumbnail." "$output"
  fi

  mv -f -- "$tmp" "$PLACEHOLDER"
  log INFO "Created placeholder thumbnail."
}

is_supported_rel_path() {
  local rel=$1

  [[ -n $rel ]] || return 1
  [[ $rel != /* ]] || return 1
  [[ $rel != *$'\n'* ]] || return 1
  [[ $rel != *$'\r'* ]] || return 1
  [[ $rel != *$'\t'* ]] || return 1
  [[ ! $rel =~ (^|/)\.\.(/|$) ]] || return 1
}

find_wallpapers() {
  find "$WALLPAPER_DIR" -type f \
    \( -iname '*.jpg' \
    -o -iname '*.jpeg' \
    -o -iname '*.png' \
    -o -iname '*.webp' \
    -o -iname '*.gif' \) \
    "$@"
}

scan_candidate_files() {
  local out_file=$1

  if ! find_wallpapers -print0 | LC_ALL=C sort -z >"$out_file"; then
    return 1
  fi
}

write_source_state() {
  local out_file=$1

  if ! find_wallpapers -printf '%P\t%s\t%T@\t%i\0' | LC_ALL=C sort -z >"$out_file"; then
    return 1
  fi
}

cache_is_current() {
  [[ -f "$CACHE_FILE" ]] || return 1
  [[ -f "$SOURCE_STATE_FILE" ]] || return 1

  local state_tmp
  state_tmp=$(mktemp --tmpdir="$CACHE_DIR" source.state.check.tmp.XXXXXX)
  register_temp "$state_tmp"

  if ! write_source_state "$state_tmp"; then
    log ERROR "Failed to build source state for cache validation."
    return 1
  fi

  cmp -s -- "$SOURCE_STATE_FILE" "$state_tmp"
}

thumb_path() {
  local rel=$1
  local digest

  digest=$(printf '%s' "$rel" | sha256sum)
  printf '%s/%s.png\n' "$THUMB_DIR" "${digest%% *}"
}

generate_thumb() {
  local file=$1
  local rel thumb tmp output

  rel=${file#"$WALLPAPER_DIR"/}
  is_supported_rel_path "$rel" || return 0

  thumb=$(thumb_path "$rel")

  if [[ -f "$thumb" && "$thumb" -nt "$file" ]]; then
    return 0
  fi

  tmp=$(mktemp --tmpdir="$THUMB_DIR" --suffix=.png thumb.tmp.XXXXXX) || return 1

  if output=$(nice -n 19 magick \
    -limit thread 1 \
    "$file" \
    -auto-orient \
    -strip \
    -thumbnail "${THUMB_SIZE}x${THUMB_SIZE}^" \
    -gravity center \
    -extent "${THUMB_SIZE}x${THUMB_SIZE}" \
    "$tmp" 2>&1); then
    mv -f -- "$tmp" "$thumb"
    return 0
  fi

  rm -f -- "$tmp"
  log_output WARN "Thumbnail generation failed for '$rel': " "$output"
  return 1
}

generate_thumb_safe() {
  generate_thumb "$1" || true
}

export WALLPAPER_DIR THUMB_DIR THUMB_SIZE LOG_FILE
export -f log log_output is_supported_rel_path thumb_path generate_thumb generate_thumb_safe

cleanup_orphan_thumbs() {
  local -n rels_ref=$1
  local -A keep=()
  local rel thumb existing_thumb

  for rel in "${rels_ref[@]}"; do
    thumb=$(thumb_path "$rel")
    keep["$thumb"]=1
  done

  while IFS= read -r -d '' existing_thumb; do
    [[ ${keep[$existing_thumb]+_} ]] && continue
    rm -f -- "$existing_thumb"
  done < <(find "$THUMB_DIR" -maxdepth 1 -type f -name '*.png' -print0)
}

build_cache() {
  log INFO "Building wallpaper cache."
  notify "Building wallpaper cache..."

  local scan_tmp state_tmp cache_tmp
  local -a files=()
  local -a valid_files=()
  local -a valid_rels=()
  local file rel thumb
  local -i skipped=0

  scan_tmp=$(mktemp --tmpdir="$CACHE_DIR" scan.tmp.XXXXXX)
  state_tmp=$(mktemp --tmpdir="$CACHE_DIR" source.state.tmp.XXXXXX)
  cache_tmp=$(mktemp --tmpdir="$CACHE_DIR" rofi_input.cache.tmp.XXXXXX)
  register_temp "$scan_tmp"
  register_temp "$state_tmp"
  register_temp "$cache_tmp"

  if ! scan_candidate_files "$scan_tmp"; then
    die "Failed to scan wallpaper directory." "$WALLPAPER_DIR"
  fi

  if ! write_source_state "$state_tmp"; then
    die "Failed to build wallpaper source state." "$WALLPAPER_DIR"
  fi

  mapfile -d '' files <"$scan_tmp"

  if ((${#files[@]} == 0)); then
    : >"$cache_tmp"
    mv -f -- "$cache_tmp" "$CACHE_FILE"
    mv -f -- "$state_tmp" "$SOURCE_STATE_FILE"
    rm -f -- "$FAVORITES_CACHE_FILE"
    find "$THUMB_DIR" -maxdepth 1 -type f -name '*.png' -delete
    notify "No wallpapers found." "$WALLPAPER_DIR"
    log INFO "No wallpapers found."
    return 1
  fi

  for file in "${files[@]}"; do
    rel=${file#"$WALLPAPER_DIR"/}

    if ! is_supported_rel_path "$rel"; then
      ((skipped += 1))
      continue
    fi

    valid_files+=("$file")
    valid_rels+=("$rel")
  done

  if ((${#valid_files[@]} == 0)); then
    : >"$cache_tmp"
    mv -f -- "$cache_tmp" "$CACHE_FILE"
    mv -f -- "$state_tmp" "$SOURCE_STATE_FILE"
    rm -f -- "$FAVORITES_CACHE_FILE"
    find "$THUMB_DIR" -maxdepth 1 -type f -name '*.png' -delete
    notify "No supported wallpapers found." "$WALLPAPER_DIR"
    log INFO "Only unsupported wallpaper names were found."
    return 1
  fi

  if ! printf '%s\0' "${valid_files[@]}" |
    xargs -0 -r -n 1 -P "$MAX_JOBS" bash -c 'set -Eeuo pipefail; generate_thumb_safe "$1"' _; then
    die "Thumbnail worker failed unexpectedly."
  fi

  : >"$cache_tmp"

  for rel in "${valid_rels[@]}"; do
    thumb=$(thumb_path "$rel")
    [[ -f "$thumb" ]] || thumb="$PLACEHOLDER"

    printf '%s\0icon\x1f%s\x1finfo\x1f%s\n' \
      "${rel##*/}" "$thumb" "$rel" >>"$cache_tmp"
  done

  mv -f -- "$cache_tmp" "$CACHE_FILE"
  mv -f -- "$state_tmp" "$SOURCE_STATE_FILE"
  cleanup_orphan_thumbs valid_rels
  rm -f -- "$FAVORITES_CACHE_FILE"

  if ((skipped > 0)); then
    notify \
      "Skipped unsupported wallpaper names." \
      "${skipped} file(s) contain tabs, newlines, carriage returns, or unsafe path components."
  fi

  log INFO "Wallpaper cache built: ${#valid_rels[@]} supported, ${skipped} skipped."
}

collect_favorites() {
  local -n favorites_ref=$1
  local fav
  local -A seen=()

  favorites_ref=()

  [[ -f "$FAVORITES_FILE" ]] || return 1

  while IFS= read -r fav || [[ -n $fav ]]; do
    [[ -n $fav ]] || continue
    is_supported_rel_path "$fav" || continue
    [[ -f "$WALLPAPER_DIR/$fav" ]] || continue
    [[ ${seen[$fav]+_} ]] && continue

    seen["$fav"]=1
    favorites_ref+=("$fav")
  done <"$FAVORITES_FILE"
}

write_favorites_file() {
  local -n favorites_ref=$1
  local tmp fav

  tmp=$(mktemp --tmpdir="$SETTINGS_DIR" wal_fav_rofi.tmp.XXXXXX)
  register_temp "$tmp"
  : >"$tmp"

  for fav in "${favorites_ref[@]}"; do
    printf '%s\n' "$fav" >>"$tmp"
  done

  mv -f -- "$tmp" "$FAVORITES_FILE"
}

build_favorites_cache() {
  local -a favorites=()
  local rel thumb tmp

  collect_favorites favorites || true
  write_favorites_file favorites

  if ((${#favorites[@]} == 0)); then
    rm -f -- "$FAVORITES_CACHE_FILE"
    notify "No favorites found."
    log INFO "No favorites found."
    return 1
  fi

  tmp=$(mktemp --tmpdir="$CACHE_DIR" rofi_input_fav.cache.tmp.XXXXXX)
  register_temp "$tmp"
  : >"$tmp"

  for rel in "${favorites[@]}"; do
    generate_thumb "$WALLPAPER_DIR/$rel" || true
    thumb=$(thumb_path "$rel")
    [[ -f "$thumb" ]] || thumb="$PLACEHOLDER"

    printf '%s\0icon\x1f%s\x1finfo\x1f%s\n' \
      "${rel##*/}" "$thumb" "$rel" >>"$tmp"
  done

  mv -f -- "$tmp" "$FAVORITES_CACHE_FILE"
  printf '%s\n' "$FAVORITES_CACHE_FILE"
}

toggle_favorite() {
  local rel=$1
  local -a favorites=()
  local -a updated=()
  local fav
  local removed=0

  is_supported_rel_path "$rel" || {
    notify "Cannot favorite this wallpaper." "$rel"
    log WARN "Rejected favorite toggle for unsupported path: $rel"
    return 1
  }

  [[ -f "$WALLPAPER_DIR/$rel" ]] || {
    notify "Cannot favorite missing wallpaper." "$rel"
    log WARN "Rejected favorite toggle for missing file: $rel"
    return 1
  }

  collect_favorites favorites || true

  for fav in "${favorites[@]}"; do
    if [[ $fav == "$rel" ]]; then
      removed=1
      continue
    fi
    updated+=("$fav")
  done

  if ((removed == 0)); then
    updated+=("$rel")
    write_favorites_file updated
    rm -f -- "$FAVORITES_CACHE_FILE"
    notify "Added favorite." "$rel"
    log INFO "Added favorite: $rel"
  else
    write_favorites_file updated
    rm -f -- "$FAVORITES_CACHE_FILE"
    notify "Removed favorite." "$rel"
    log INFO "Removed favorite: $rel"
  fi
}

resolve_path() {
  local rel=$1
  local full_path

  is_supported_rel_path "$rel" || return 1

  full_path="$WALLPAPER_DIR/$rel"
  [[ -f "$full_path" ]] || return 1

  printf '%s\n' "$full_path"
}

# --- NEW FUNCTION: Extract active wallpaper directly from daemon ---
get_active_wallpaper_filename() {
  local swww_out current_image
  
  if swww_out=$(swww query 2>/dev/null | head -n 1); then
    if [[ "$swww_out" == *image:* ]]; then
      current_image="${swww_out##*image: }"
      # Trim leading/trailing whitespace defensively
      current_image="${current_image#"${current_image%%[![:space:]]*}"}"
      current_image="${current_image%"${current_image##*[![:space:]]}"}"
      
      printf '%s\n' "${current_image##*/}"
      return 0
    fi
  fi
  return 1
}

# Modified show_menu to accept an initial selection
show_menu() {
  local mode=$1
  local input=$2
  local selection=${3:-} # Injects the active wallpaper filename here
  local prompt message
  local new_selection=""
  local exit_code
  local -a rofi_cmd

  while true; do
    if [[ $mode == favorites ]]; then
      prompt="Favorites"
      message="Enter: Apply | Alt+U: Unfavorite | Alt+Y: Rebuild | Alt+T: All Wallpapers"
    else
      prompt="Wallpaper"
      message="Enter: Apply | Alt+U: Favorite | Alt+Y: Rebuild | Alt+T: Favorites"
    fi

    rofi_cmd=(
      rofi
      -dmenu
      -no-custom
      -i
      -show-icons
      -format i
      -p "$prompt"
      -mesg "$message"
      -kb-custom-1 "Alt+u"
      -kb-custom-2 "Alt+y"
      -kb-custom-3 "Alt+t"
    )

    if [[ -f "$ROFI_THEME" ]]; then
      rofi_cmd+=(-theme "$ROFI_THEME")
    fi

    # Rofi uses `-select` to match the display string. 
    # Because our cache uses ${rel##*/} for display, passing the filename works perfectly.
    if [[ -n $selection ]]; then
      rofi_cmd+=(-select "${selection##*/}")
    fi

    if new_selection="$("${rofi_cmd[@]}" <"$input")"; then
      exit_code=0
    else
      exit_code=$?
    fi

    if [[ -n $new_selection && "$new_selection" =~ ^[0-9]+$ ]]; then
      selection=$(sed -n "$((new_selection + 1))p" "$input" | sed 's/.*\x1finfo\x1f//')
    else
      selection=""
    fi

    case $exit_code in
      0)
        [[ -n $selection ]] || return 1
        printf '%s\n' "$selection"
        return 0
        ;;
      1)
        return 1
        ;;
      10)
        [[ -n $selection ]] || continue
        toggle_favorite "$selection" || true

        if [[ $mode == favorites ]]; then
          if ! input=$(build_favorites_cache); then
            mode="all"
            input="$CACHE_FILE"
            selection=""
          fi
        fi
        ;;
      11)
        build_cache || true

        if [[ $mode == favorites ]]; then
          if ! input=$(build_favorites_cache); then
            mode="all"
            input="$CACHE_FILE"
            selection=""
          fi
        else
          input="$CACHE_FILE"
          [[ -s "$input" ]] || return 1
        fi
        ;;
      12)
        selection=""
        if [[ $mode == all ]]; then
          if input=$(build_favorites_cache); then
            mode="favorites"
          else
            continue
          fi
        else
          mode="all"
          input="$CACHE_FILE"
          [[ -s "$input" ]] || return 1
        fi
        ;;
      *)
        log WARN "Rofi exited with unexpected code: $exit_code"
        return 1
        ;;
    esac
  done
}

apply_selection() {
  local full_path=$1
  local output

  log INFO "Applying wallpaper: $full_path"

  if ! output=$(swww img "$full_path" \
    --transition-type grow \
    --transition-duration 2 \
    --transition-fps 60 2>&1); then
    die "Failed to set wallpaper." "$output"
  fi

  [[ -n $output ]] && log_output INFO "swww: " "$output"

  if ! output=$(setsid uwsm-app -- matugen "${MATUGEN_ARGS[@]}" image "$full_path" 2>&1); then
    die "Failed to apply Matugen theme." "$output"
  fi

  [[ -n $output ]] && log_output INFO "matugen: " "$output"
}

ensure_cache() {
  if ((FORCE_REBUILD)); then
    log INFO "Forced cache rebuild requested."
    build_cache || true
    return 0
  fi

  if cache_is_current; then
    log INFO "Wallpaper cache is current."
    return 0
  fi

  log INFO "Wallpaper cache is missing or stale. Rebuilding."
  build_cache || true
}

main() {
  setup_logging
  trap on_err ERR

  parse_args "$@"
  check_dependencies
  initialize_runtime
  validate_config
  acquire_lock
  ensure_placeholder
  ensure_cache

  if [[ ! -s "$CACHE_FILE" ]]; then
    log INFO "No wallpaper entries to display."
    exit 0
  fi

  local mode="all"
  local input="$CACHE_FILE"
  local selection
  local full_path
  local active_wal=""

  # Fetch the currently rendered image to center the menu
  active_wal=$(get_active_wallpaper_filename) || true

  if ((SHOW_FAVORITES)); then
    mode="favorites"
    if ! input=$(build_favorites_cache); then
      exit 0
    fi
  fi

  # Pass active_wal as the third argument to seed the selection
  if ! selection=$(show_menu "$mode" "$input" "$active_wal"); then
    log INFO "Menu closed without selection."
    exit 0
  fi

  log INFO "Selected wallpaper: $selection"

  if ! full_path=$(resolve_path "$selection"); then
    die "Failed to resolve wallpaper path." "$selection"
  fi

  apply_selection "$full_path"
  log INFO "Wallpaper applied successfully."
}

main "$@"
exit 0
