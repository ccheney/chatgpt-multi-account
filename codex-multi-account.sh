#!/usr/bin/env bash
set -euo pipefail

# Run additional Codex Desktop instances with separate OAuth accounts.
#
# Default behavior:
#   - primary Codex home:   ~/.codex
#   - secondary Codex home: ~/.codex-multi-2
#   - secondary Chromium profile: ~/Library/Application Support/Codex-Multi-2
#   - no symlinks or shared history unless --symlink-history is provided

PRIMARY_HOME="${CODEX_PRIMARY_HOME:-$HOME/.codex}"
ACCOUNT_NAME="${CODEX_ACCOUNT_NAME:-multi-2}"
ACCOUNT_EXPLICIT=0
ACCOUNTS_TOTAL=""
SECONDARY_HOME_OVERRIDE="${CODEX_SECONDARY_HOME:-}"
PROFILE_DIR_OVERRIDE="${CODEX_PROFILE_DIR:-}"
SECONDARY_HOME_EXPLICIT=0
PROFILE_DIR_EXPLICIT=0
CODEX_APP="${CODEX_APP:-/Applications/Codex.app}"
REGISTRY_DIR="${CODEX_MULTI_REGISTRY_DIR:-$HOME/.codex-multi-account}"
REGISTRY_FILE="${CODEX_MULTI_REGISTRY_FILE:-$REGISTRY_DIR/instances.tsv}"
MARKER_FILE=".codex-multi-account-managed"
LAUNCH=1
DRY_RUN=0
VERBOSE=1
SHARE_RUNTIME_DBS=0
SYMLINK_HISTORY=0
RESET=0
BACKUP=1
FULL_BACKUP=0

if [ -n "$SECONDARY_HOME_OVERRIDE" ]; then
  SECONDARY_HOME_EXPLICIT=1
fi

if [ -n "${CODEX_ACCOUNT_NAME:-}" ]; then
  ACCOUNT_EXPLICIT=1
fi

if [ -n "$PROFILE_DIR_OVERRIDE" ]; then
  PROFILE_DIR_EXPLICIT=1
fi

usage() {
  cat <<'EOF'
Usage: codex-multi-account.sh [options]

Set up and optionally launch one or more additional Codex Desktop instances
with separate OAuth accounts.

Options:
  --account NAME           Secondary account suffix. Default: multi-2
                            Example: --account work uses ~/.codex-work
                            and ~/Library/Application Support/Codex-work.
  --accounts N             Prepare/launch N total accounts, counting the normal
                            primary Codex app as account 1. For example,
                            --accounts 5 launches multi-2 through multi-5.
  --primary-home PATH       Primary Codex home. Default: ~/.codex
  --secondary-home PATH     Secondary Codex home. Default: ~/.codex-multi-2
                            Cannot be combined with --accounts.
  --profile-dir PATH        Secondary Chromium profile dir. Default:
                            ~/Library/Application Support/Codex-Multi-2
                            Cannot be combined with --accounts.
  --codex-app PATH          Codex.app path. Default: /Applications/Codex.app
  --symlink-history         Opt in to sharing project/sidebar history with the
                            primary Codex profile via symlinks. Unsupported.
  --reset                   Remove generated secondary Codex homes/profiles,
                            then exit. With no account flags, remove every
                            managed instance created by this script.
  --no-launch               Only set up account homes/profiles; do not launch.
  --dry-run                 Print what would change, but do not change files.
  --quiet                   Print less output.
  --no-backup               With --symlink-history, do not back up secondary home.
  --full-backup             With --symlink-history, copy the entire secondary
                            home before changes. Default is targeted backup.
  --share-runtime-dbs       Also share logs_*.sqlite, goals_*.sqlite, and
                            memories_*.sqlite. Requires --symlink-history.
  -h, --help                Show this help.

Environment overrides:
  CODEX_PRIMARY_HOME
  CODEX_ACCOUNT_NAME
  CODEX_SECONDARY_HOME
  CODEX_PROFILE_DIR
  CODEX_APP
  CODEX_MULTI_REGISTRY_DIR
  CODEX_MULTI_REGISTRY_FILE

Examples:
  ./codex-multi-account.sh
  ./codex-multi-account.sh --account work
  ./codex-multi-account.sh --accounts 5
  ./codex-multi-account.sh --symlink-history
  ./codex-multi-account.sh --reset --account work
  ./codex-multi-account.sh --reset --accounts 5
  ./codex-multi-account.sh --secondary-home "$HOME/.codex-work" \
    --profile-dir "$HOME/Library/Application Support/Codex-Work"
  ./codex-multi-account.sh --dry-run --no-launch
EOF
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    printf '%s\n' "$*"
  fi
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

expand_tilde() {
  case "$1" in
    \~) printf '%s\n' "$HOME" ;;
    \~/*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

validate_account_name() {
  account="$1"
  case "$account" in
    ""|*".."*|*/*|*\\*|*" "*)
      die "account name must be a simple suffix without spaces or path separators"
      ;;
  esac

  if ! [[ "$account" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "account name may only contain letters, numbers, dots, underscores, and dashes"
  fi
}

profile_suffix_for_account() {
  account="$1"
  if [[ "$account" =~ ^multi-([0-9]+)$ ]]; then
    printf 'Multi-%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$account"
  fi
}

set_paths_for_account() {
  account="$1"
  validate_account_name "$account"

  if [ "$SECONDARY_HOME_EXPLICIT" -eq 1 ]; then
    SECONDARY_HOME="$(expand_tilde "$SECONDARY_HOME_OVERRIDE")"
  else
    SECONDARY_HOME="$HOME/.codex-$account"
  fi

  if [ "$PROFILE_DIR_EXPLICIT" -eq 1 ]; then
    PROFILE_DIR="$(expand_tilde "$PROFILE_DIR_OVERRIDE")"
  else
    PROFILE_DIR="$HOME/Library/Application Support/Codex-$(profile_suffix_for_account "$account")"
  fi
}

validate_accounts_total() {
  value="$1"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    die "--accounts must be a positive integer"
  fi

  if [ "$value" -lt 2 ]; then
    die "--accounts counts the primary app as account 1, so it must be at least 2"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --account)
      [ "$#" -ge 2 ] || die "--account requires a name"
      ACCOUNT_NAME="$2"
      ACCOUNT_EXPLICIT=1
      shift 2
      ;;
    --accounts)
      [ "$#" -ge 2 ] || die "--accounts requires a number"
      ACCOUNTS_TOTAL="$2"
      shift 2
      ;;
    --primary-home)
      [ "$#" -ge 2 ] || die "--primary-home requires a path"
      PRIMARY_HOME="$2"
      shift 2
      ;;
    --secondary-home)
      [ "$#" -ge 2 ] || die "--secondary-home requires a path"
      SECONDARY_HOME_OVERRIDE="$2"
      SECONDARY_HOME_EXPLICIT=1
      shift 2
      ;;
    --profile-dir)
      [ "$#" -ge 2 ] || die "--profile-dir requires a path"
      PROFILE_DIR_OVERRIDE="$2"
      PROFILE_DIR_EXPLICIT=1
      shift 2
      ;;
    --codex-app)
      [ "$#" -ge 2 ] || die "--codex-app requires a path"
      CODEX_APP="$2"
      shift 2
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --quiet)
      VERBOSE=0
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --full-backup)
      FULL_BACKUP=1
      shift
      ;;
    --share-runtime-dbs)
      SHARE_RUNTIME_DBS=1
      shift
      ;;
    --symlink-history)
      SYMLINK_HISTORY=1
      shift
      ;;
    --reset)
      RESET=1
      LAUNCH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

PRIMARY_HOME="$(expand_tilde "$PRIMARY_HOME")"
CODEX_APP="$(expand_tilde "$CODEX_APP")"
REGISTRY_DIR="$(expand_tilde "$REGISTRY_DIR")"
REGISTRY_FILE="$(expand_tilde "$REGISTRY_FILE")"

CODEX_CLI="$CODEX_APP/Contents/Resources/codex"
CODEX_EXE="$CODEX_APP/Contents/MacOS/Codex"

if [ "$RESET" -ne 1 ]; then
  [ -d "$PRIMARY_HOME" ] || die "primary Codex home does not exist: $PRIMARY_HOME"
  [ -d "$CODEX_APP" ] || die "Codex.app not found: $CODEX_APP"
  [ -x "$CODEX_CLI" ] || die "Codex CLI not executable: $CODEX_CLI"
  [ -x "$CODEX_EXE" ] || die "Codex app executable not found: $CODEX_EXE"
fi

if [ "$SHARE_RUNTIME_DBS" -eq 1 ] && [ "$SYMLINK_HISTORY" -ne 1 ]; then
  die "--share-runtime-dbs requires --symlink-history"
fi

refuse_dangerous_reset_path() {
  path="$1"
  label="$2"

  [ -n "$path" ] || die "refusing to reset empty $label path"

  clean="$path"
  while [ "$clean" != "/" ] && [ "${clean%/}" != "$clean" ]; do
    clean="${clean%/}"
  done

  case "$clean" in
    "/"|"$HOME"|"$PRIMARY_HOME"|"$HOME/.codex"|"$HOME/Library/Application Support/Codex")
      die "refusing to reset protected $label path: $clean"
      ;;
  esac
}

write_managed_marker() {
  dir="$1"
  kind="$2"
  marker="$dir/$MARKER_FILE"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: write managed marker %q\n' "$marker"
    return 0
  fi

  {
    printf 'tool=codex-multi-account\n'
    printf 'kind=%s\n' "$kind"
    printf 'account=%s\n' "$ACCOUNT_NAME"
    printf 'secondary_home=%s\n' "$SECONDARY_HOME"
    printf 'profile_dir=%s\n' "$PROFILE_DIR"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$marker"
}

register_instance() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: register managed instance %q %q %q\n' "$ACCOUNT_NAME" "$SECONDARY_HOME" "$PROFILE_DIR"
    return 0
  fi

  mkdir -p "$(dirname "$REGISTRY_FILE")"
  tmp="$(mktemp -t codex-multi-registry.XXXXXX)"

  if [ -f "$REGISTRY_FILE" ]; then
    awk -F '\t' -v account="$ACCOUNT_NAME" -v home="$SECONDARY_HOME" -v profile="$PROFILE_DIR" '
      !($1 == account || $2 == home || $3 == profile) { print }
    ' "$REGISTRY_FILE" > "$tmp"
  fi

  printf '%s\t%s\t%s\n' "$ACCOUNT_NAME" "$SECONDARY_HOME" "$PROFILE_DIR" >> "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

unregister_instance_paths() {
  home="$1"
  profile="$2"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: unregister managed instance %q %q\n' "$home" "$profile"
    return 0
  fi

  [ -f "$REGISTRY_FILE" ] || return 0

  tmp="$(mktemp -t codex-multi-registry.XXXXXX)"
  awk -F '\t' -v home="$home" -v profile="$profile" '
    !($2 == home || $3 == profile) { print }
  ' "$REGISTRY_FILE" > "$tmp"

  if [ -s "$tmp" ]; then
    mv "$tmp" "$REGISTRY_FILE"
  else
    rm -f "$tmp" "$REGISTRY_FILE"
    rmdir "$(dirname "$REGISTRY_FILE")" 2>/dev/null || true
  fi
}

marker_value() {
  key="$1"
  file="$2"
  awk -F '=' -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$file"
}

collect_marker_instances() {
  for marker in \
    "$HOME"/.codex-*/"$MARKER_FILE" \
    "$HOME/Library/Application Support"/Codex-*/"$MARKER_FILE"
  do
    [ -f "$marker" ] || continue

    account="$(marker_value "account" "$marker")"
    home="$(marker_value "secondary_home" "$marker")"
    profile="$(marker_value "profile_dir" "$marker")"

    [ -n "$account" ] || account="$(basename "$(dirname "$marker")")"
    [ -n "$home" ] || continue
    [ -n "$profile" ] || continue

    printf '%s\t%s\t%s\n' "$account" "$home" "$profile"
  done
}

collect_known_pattern_instances() {
  for home in "$HOME"/.codex-multi-[0-9]*; do
    [ -e "$home" ] || [ -L "$home" ] || continue
    account="${home##*/.codex-}"
    [[ "$account" =~ ^multi-[0-9]+$ ]] || continue
    profile="$HOME/Library/Application Support/Codex-$(profile_suffix_for_account "$account")"
    printf '%s\t%s\t%s\n' "$account" "$home" "$profile"
  done

  for profile in "$HOME/Library/Application Support"/Codex-Multi-[0-9]*; do
    [ -e "$profile" ] || [ -L "$profile" ] || continue
    suffix="${profile##*/Codex-Multi-}"
    [[ "$suffix" =~ ^[0-9]+$ ]] || continue
    account="multi-$suffix"
    home="$HOME/.codex-$account"
    printf '%s\t%s\t%s\n' "$account" "$home" "$profile"
  done

}

collect_managed_instances() {
  if [ -f "$REGISTRY_FILE" ]; then
    awk -F '\t' 'NF >= 3 && $2 != "" && $3 != "" { print $1 "\t" $2 "\t" $3 }' "$REGISTRY_FILE"
  fi

  collect_marker_instances
  collect_known_pattern_instances
}

detect_db_path_with_doctor() {
  db_kind="$1"
  doctor_key="$2"

  if command -v python3 >/dev/null 2>&1; then
    CODEX_HOME="$PRIMARY_HOME" "$CODEX_CLI" doctor --json 2>/dev/null | python3 -c '
import json, os, sys
key = sys.argv[1]
try:
    data = json.load(sys.stdin)
    value = data["checks"]["state.paths"]["details"].get(key, "")
except Exception:
    value = ""
if value.endswith(" (file)") or value.endswith(" (missing)"):
    value = value.rsplit(" (", 1)[0]
print(value)
' "$doctor_key"
    return 0
  fi

  return 1
}

detect_db_base() {
  db_kind="$1"
  doctor_key="$2"
  expected=""

  expected="$(detect_db_path_with_doctor "$db_kind" "$doctor_key" || true)"
  if [ -n "$expected" ]; then
    case "$(basename "$expected")" in
      "$db_kind"_*.sqlite)
        printf '%s\n' "$(basename "$expected")"
        return 0
        ;;
    esac
  fi

  # If doctor output is unavailable, pick the highest numeric suffix present
  # in the primary Codex home.
  find "$PRIMARY_HOME" -maxdepth 1 -type f -name "$db_kind"'_*.sqlite' -print 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | awk -v kind="$db_kind" '
        $0 ~ "^" kind "_[0-9]+\\.sqlite$" {
          v=$0
          sub("^" kind "_", "", v)
          sub("\\.sqlite$", "", v)
          print v "\t" $0
        }
      ' \
    | sort -nr \
    | awk 'NR == 1 {print $2}'
}

link_path() {
  src="$1"
  dst="$2"

  run rm -rf "$dst"
  run ln -s "$src" "$dst"
}

copy_for_backup() {
  src="$1"
  rel="${src#"$SECONDARY_HOME"/}"
  dst="$2/$rel"

  if [ -L "$src" ]; then
    run mkdir -p "$(dirname "$dst")"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'dry-run: ln -s %q %q\n' "$(readlink "$src")" "$dst"
    else
      rm -rf "$dst"
      ln -s "$(readlink "$src")" "$dst"
    fi
  elif [ -d "$src" ]; then
    run mkdir -p "$(dirname "$dst")"
    run cp -R -P "$src" "$dst"
  elif [ -f "$src" ]; then
    run mkdir -p "$(dirname "$dst")"
    run cp -p "$src" "$dst"
  fi
}

backup_secondary_home() {
  backup_path="$1"

  if [ "$FULL_BACKUP" -eq 1 ]; then
    log "backup secondary home (full): $backup_path"
    run cp -R -P "$SECONDARY_HOME" "$backup_path"
    return 0
  fi

  log "backup secondary home (targeted): $backup_path"
  run mkdir -p "$backup_path"

  # Back up account identity/config and every path this script may replace.
  # This avoids copying large runtime bundles and caches on every launch.
  for rel in \
    auth.json \
    config.toml \
    installation_id \
    .codex-global-state.json \
    sessions \
    archived_sessions \
    attachments \
    session_index.jsonl \
    history.jsonl \
    shell_snapshots \
    generated_images \
    worktrees
  do
    if [ -e "$SECONDARY_HOME/$rel" ] || [ -L "$SECONDARY_HOME/$rel" ]; then
      copy_for_backup "$SECONDARY_HOME/$rel" "$backup_path"
    fi
  done

  if [ -d "$SECONDARY_HOME" ]; then
    while IFS= read -r path; do
      copy_for_backup "$path" "$backup_path"
    done < <(
      find "$SECONDARY_HOME" -maxdepth 1 \( \
        -name 'state_*.sqlite' -o -name 'state_*.sqlite-wal' -o -name 'state_*.sqlite-shm' -o \
        -name 'logs_*.sqlite' -o -name 'logs_*.sqlite-wal' -o -name 'logs_*.sqlite-shm' -o \
        -name 'goals_*.sqlite' -o -name 'goals_*.sqlite-wal' -o -name 'goals_*.sqlite-shm' -o \
        -name 'memories_*.sqlite' -o -name 'memories_*.sqlite-wal' -o -name 'memories_*.sqlite-shm' \
      \) -print
    )
  fi
}

profile_is_running() {
  marker="$CODEX_APP/Contents/"
  profile_arg="--user-data-dir=$PROFILE_DIR"
  ps ax -o pid= -o command= | awk -v self="$$" -v marker="$marker" -v profile_arg="$profile_arg" '
    $1 == self { next }
    index($0, marker) && index($0, profile_arg) { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

clear_stale_profile_singletons() {
  if profile_is_running; then
    log "secondary Chromium profile already appears to be in use"
    return 0
  fi

  for rel in SingletonLock SingletonSocket SingletonCookie; do
    path="$PROFILE_DIR/$rel"
    if [ -e "$path" ] || [ -L "$path" ]; then
      log "remove stale profile lock: $path"
      run rm -f "$path"
    fi
  done
}

ensure_source_dir() {
  src="$1"
  if [ ! -e "$src" ]; then
    run mkdir -p "$src"
  elif [ ! -d "$src" ]; then
    die "expected a directory at $src"
  fi
}

share_dir() {
  rel="$1"
  src="$PRIMARY_HOME/$rel"
  dst="$SECONDARY_HOME/$rel"

  ensure_source_dir "$src"
  run mkdir -p "$(dirname "$dst")"
  link_path "$src" "$dst"
}

share_file_if_present() {
  rel="$1"
  src="$PRIMARY_HOME/$rel"
  dst="$SECONDARY_HOME/$rel"

  if [ ! -e "$src" ]; then
    log "skip missing optional file: $rel"
    return 0
  fi

  [ -f "$src" ] || [ -L "$src" ] || die "expected a file at $src"
  run mkdir -p "$(dirname "$dst")"
  link_path "$src" "$dst"
}

share_db_family() {
  kind="$1"
  doctor_key="$2"
  base="$(detect_db_base "$kind" "$doctor_key")"

  [ -n "$base" ] || die "could not detect current $kind SQLite filename"

  log "share $kind DB family: $base"

  # Remove old versions for this DB family from the secondary home so upgrades
  # like state_5.sqlite -> state_6.sqlite do not leave stale files behind.
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -d "$SECONDARY_HOME" ]; then
      find "$SECONDARY_HOME" -maxdepth 1 \( -name "$kind"'_*.sqlite' -o -name "$kind"'_*.sqlite-wal' -o -name "$kind"'_*.sqlite-shm' \) -print 2>/dev/null \
        | while IFS= read -r stale; do
            printf 'dry-run: rm -rf %q\n' "$stale"
          done
    fi
  else
    find "$SECONDARY_HOME" -maxdepth 1 \( -name "$kind"'_*.sqlite' -o -name "$kind"'_*.sqlite-wal' -o -name "$kind"'_*.sqlite-shm' \) -exec rm -rf {} +
  fi

  link_path "$PRIMARY_HOME/$base" "$SECONDARY_HOME/$base"
  link_path "$PRIMARY_HOME/$base-wal" "$SECONDARY_HOME/$base-wal"
  link_path "$PRIMARY_HOME/$base-shm" "$SECONDARY_HOME/$base-shm"
}

setup_current_account() {
  log "account:        $ACCOUNT_NAME"
  log "primary home:   $PRIMARY_HOME"
  log "secondary home: $SECONDARY_HOME"
  log "profile dir:    $PROFILE_DIR"
  log "Codex app:      $CODEX_APP"

  if [ "$PRIMARY_HOME" = "$SECONDARY_HOME" ]; then
    die "primary and secondary homes must be different"
  fi

  SECONDARY_EXISTED=0
  if [ -e "$SECONDARY_HOME" ]; then
    SECONDARY_EXISTED=1
  fi

  run mkdir -p "$SECONDARY_HOME" "$PROFILE_DIR"
  write_managed_marker "$SECONDARY_HOME" "codex-home"
  write_managed_marker "$PROFILE_DIR" "chromium-profile"
  register_instance

  if [ "$SYMLINK_HISTORY" -eq 1 ]; then
    if [ "$BACKUP" -eq 1 ] && [ "$SECONDARY_EXISTED" -eq 1 ] && [ -d "$SECONDARY_HOME" ]; then
      stamp="$(date +%Y%m%d-%H%M%S)"
      backup_path="$SECONDARY_HOME.backup.$stamp"
      backup_secondary_home "$backup_path"
    fi

    share_file_if_present ".codex-global-state.json"
    share_db_family "state" "state DB"

    share_dir "sessions"
    share_dir "archived_sessions"
    share_dir "attachments"
    share_file_if_present "session_index.jsonl"
    share_file_if_present "history.jsonl"
    share_dir "shell_snapshots"
    share_dir "generated_images"
    share_dir "worktrees"

    if [ "$SHARE_RUNTIME_DBS" -eq 1 ]; then
      log "sharing runtime DBs because --share-runtime-dbs was supplied"
      share_db_family "logs" "log DB"
      share_db_family "goals" "goals DB"
      share_db_family "memories" "memories DB"
    else
      log "leaving runtime DBs separate: logs_*.sqlite, goals_*.sqlite, memories_*.sqlite"
    fi
  else
    log "history sharing disabled; no symlinks will be created"
  fi

  log "leaving auth separate: $SECONDARY_HOME/auth.json"

  if [ "$LAUNCH" -eq 1 ]; then
    log_file="/tmp/codex-$(basename "$SECONDARY_HOME").log"
    if profile_is_running; then
      log "Codex already appears to be running for this profile: $PROFILE_DIR"
      log "done"
      return 0
    fi
    clear_stale_profile_singletons
    log "launching secondary Codex instance"
    log "log file: $log_file"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'dry-run: CODEX_HOME=%q nohup %q --user-data-dir=%q >%q 2>&1 &\n' \
        "$SECONDARY_HOME" "$CODEX_EXE" "$PROFILE_DIR" "$log_file"
    else
      CODEX_HOME="$SECONDARY_HOME" nohup "$CODEX_EXE" \
        --user-data-dir="$PROFILE_DIR" \
        >"$log_file" 2>&1 &
      log "started pid: $!"
    fi
  fi

  log "done"
}

reset_current_account() {
  log "reset account:  $ACCOUNT_NAME"
  log "secondary home: $SECONDARY_HOME"
  log "profile dir:    $PROFILE_DIR"

  refuse_dangerous_reset_path "$SECONDARY_HOME" "secondary home"
  refuse_dangerous_reset_path "$PROFILE_DIR" "profile dir"

  if profile_is_running; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "dry-run: Codex appears to be running for this profile; real reset would stop here"
    else
      die "Codex appears to be running for this profile. Quit it first: $PROFILE_DIR"
    fi
  fi

  if [ -e "$SECONDARY_HOME" ] || [ -L "$SECONDARY_HOME" ]; then
    run rm -rf "$SECONDARY_HOME"
  else
    log "skip missing secondary home"
  fi

  if [ -e "$PROFILE_DIR" ] || [ -L "$PROFILE_DIR" ]; then
    run rm -rf "$PROFILE_DIR"
  else
    log "skip missing profile dir"
  fi

  unregister_instance_paths "$SECONDARY_HOME" "$PROFILE_DIR"
  log "reset done"
}

reset_all_managed_accounts() {
  log "reset mode: all managed instances"

  managed_tmp="$(mktemp -t codex-multi-reset.XXXXXX)"
  collect_managed_instances \
    | awk -F '\t' 'NF >= 3 && $2 != "" && $3 != "" && !seen[$2 "\t" $3]++ { print $1 "\t" $2 "\t" $3 }' \
    > "$managed_tmp"

  if [ ! -s "$managed_tmp" ]; then
    rm -f "$managed_tmp"
    log "no managed Codex multi-account instances found"
    return 0
  fi

  if [ "$DRY_RUN" -ne 1 ]; then
    running_tmp="$(mktemp -t codex-multi-running.XXXXXX)"
    while IFS=$'\t' read -r account home profile; do
      ACCOUNT_NAME="$account"
      SECONDARY_HOME="$home"
      PROFILE_DIR="$profile"
      if profile_is_running; then
        printf '%s\t%s\n' "$ACCOUNT_NAME" "$PROFILE_DIR" >> "$running_tmp"
      fi
    done < "$managed_tmp"

    if [ -s "$running_tmp" ]; then
      while IFS=$'\t' read -r account profile; do
        printf 'error: Codex appears to be running for %s: %s\n' "$account" "$profile" >&2
      done < "$running_tmp"
      rm -f "$managed_tmp" "$running_tmp"
      die "quit matching secondary Codex windows before reset"
    fi
    rm -f "$running_tmp"
  fi

  while IFS=$'\t' read -r account home profile; do
    ACCOUNT_NAME="$account"
    SECONDARY_HOME="$home"
    PROFILE_DIR="$profile"
    reset_current_account
  done < "$managed_tmp"

  rm -f "$managed_tmp"

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: remove registry %q\n' "$REGISTRY_FILE"
  else
    rm -f "$REGISTRY_FILE"
    rmdir "$(dirname "$REGISTRY_FILE")" 2>/dev/null || true
  fi
}

handle_current_account() {
  if [ "$RESET" -eq 1 ]; then
    reset_current_account
  else
    setup_current_account
  fi
}

if [ "$RESET" -eq 1 ] \
  && [ -z "$ACCOUNTS_TOTAL" ] \
  && [ "$ACCOUNT_EXPLICIT" -eq 0 ] \
  && [ "$SECONDARY_HOME_EXPLICIT" -eq 0 ] \
  && [ "$PROFILE_DIR_EXPLICIT" -eq 0 ]; then
  reset_all_managed_accounts
elif [ -n "$ACCOUNTS_TOTAL" ]; then
  validate_accounts_total "$ACCOUNTS_TOTAL"
  if [ "$SECONDARY_HOME_EXPLICIT" -eq 1 ] || [ "$PROFILE_DIR_EXPLICIT" -eq 1 ]; then
    die "--accounts cannot be combined with --secondary-home or --profile-dir"
  fi

  i=2
  while [ "$i" -le "$ACCOUNTS_TOTAL" ]; do
    ACCOUNT_NAME="multi-$i"
    set_paths_for_account "$ACCOUNT_NAME"
    handle_current_account
    i=$((i + 1))
  done
else
  set_paths_for_account "$ACCOUNT_NAME"
  handle_current_account
fi
