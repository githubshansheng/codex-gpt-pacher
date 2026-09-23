#!/usr/bin/env bash
# Linux lightweight Codex setup: no Python, Node.js, or Desktop patch.
#
# It safely rewrites the user-level custom Responses provider and changes only
# session provider metadata (JSONL session_meta.payload.model_provider and
# SQLite threads.model_provider) to "custom". It deliberately does not touch
# CC Switch's database, model catalogs, the Desktop app bundle, or session body.

set -u
set -o pipefail
umask 077

readonly SCRIPT_NAME="codex-lightweight-linux"
# ===== BEGIN EDITABLE SETTINGS =====
readonly MANAGED_BASE_URL="https://ai2.heigh.vip/v1"
readonly MANAGED_API_KEY="sk-REPLACE_WITH_YOUR_API_KEY"
readonly DEFAULT_MODEL="gpt-5.6-terra"
readonly DEFAULT_REASONING_EFFORT="xhigh"
# ===== END EDITABLE SETTINGS =====
readonly TARGET_PROVIDER="custom"

PERL_BIN=""
SQLITE_BIN=""
SHA256_BIN=""
SHA256_KIND=""

declare -a ROLLBACK_KIND=()
declare -a ROLLBACK_SOURCE=()
declare -a ROLLBACK_BACKUP=()
declare -a JSONL_PATHS=()
declare -a SQLITE_PATHS=()
declare -a CANDIDATE_HOME=()
declare -a CANDIDATE_SOURCE=()
declare -a CANDIDATE_JSONL=()
declare -a CANDIDATE_THREADS=()

ROLLBACK_ENABLED=0
RUN_SUCCEEDED=0
LEDGER_DIR=""
SELECTED_HOME=""
START_EPOCH="$(date +%s)"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s][%s][%s] %s\n' "$SCRIPT_NAME" "$(timestamp)" "$1" "$2"
}

step() {
  log 'STEP' "$1"
}

trace() {
  log 'TRACE' "$1"
}

warn() {
  log 'WARNING' "$1" >&2
}

die() {
  log 'ERROR' "$1" >&2
  exit 1
}

sha256_file() {
  if [[ "$SHA256_KIND" == 'sha256sum' ]]; then
    "$SHA256_BIN" "$1"
  else
    "$SHA256_BIN" -a 256 "$1"
  fi | awk '{print $1}'
}

sha256_stdin() {
  if [[ "$SHA256_KIND" == 'sha256sum' ]]; then
    "$SHA256_BIN"
  else
    "$SHA256_BIN" -a 256
  fi | awk '{print $1}'
}

short_hash() {
  local value="$1"
  if [[ ${#value} -le 16 ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "${value:0:16}"
  fi
}

file_state() {
  # GNU/BusyBox stat format: size, mtime seconds, ctime seconds, inode.
  stat -c '%s:%Y:%Z:%i' "$1"
}

same_file_state() {
  [[ "$(file_state "$1")" == "$2" ]]
}

sql_quote() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'\n" "$value"
}

pause_before_exit() {
  if [[ -t 0 && "${CODEX_LIGHTWEIGHT_NO_PAUSE:-}" != "1" ]]; then
    printf '\nPress Return to close…'
    local ignored=''
    read -r ignored || true
  fi
}

append_manifest() {
  [[ -n "$LEDGER_DIR" ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$LEDGER_DIR/entries.tsv"
}

remember_rollback() {
  ROLLBACK_KIND+=("$1")
  ROLLBACK_SOURCE+=("$2")
  ROLLBACK_BACKUP+=("$3")
}

atomic_restore_file() {
  local source="$1"
  local backup="$2"
  local directory="${source%/*}"
  local base="${source##*/}"
  local temporary
  temporary="$(mktemp "$directory/.${base}.rollback.XXXXXX")" || return 1
  cp -p "$backup" "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$source"
}

restore_sqlite_backup() {
  local source="$1"
  local backup="$2"
  "$SQLITE_BIN" "$source" ".restore $(sql_quote "$backup")" >/dev/null
}

rollback() {
  [[ "$ROLLBACK_ENABLED" == "1" ]] || return 0
  (( ${#ROLLBACK_KIND[@]} > 0 )) || return 0
  warn "A failure occurred; restoring ${#ROLLBACK_KIND[@]} changed artifact(s)."
  local index kind source backup failed=0
  for (( index=${#ROLLBACK_KIND[@]} - 1; index>=0; index-- )); do
    kind="${ROLLBACK_KIND[$index]}"
    source="${ROLLBACK_SOURCE[$index]}"
    backup="${ROLLBACK_BACKUP[$index]}"
    case "$kind" in
      file)
        if atomic_restore_file "$source" "$backup"; then
          trace "ROLLBACK restored file: $source"
        else
          warn "ROLLBACK failed for file: $source"
          failed=1
        fi
        ;;
      created-file)
        if rm -f "$source"; then
          trace "ROLLBACK removed newly-created file: $source"
        else
          warn "ROLLBACK failed while removing new file: $source"
          failed=1
        fi
        ;;
      sqlite)
        if restore_sqlite_backup "$source" "$backup"; then
          trace "ROLLBACK restored SQLite database: $source"
        else
          warn "ROLLBACK failed for SQLite database: $source"
          failed=1
        fi
        ;;
      *)
        warn "ROLLBACK found an unknown entry kind: $kind"
        failed=1
        ;;
    esac
  done
  if [[ -n "$LEDGER_DIR" ]]; then
    if (( failed == 0 )); then
      printf '%s\n' 'status=rolled_back' > "$LEDGER_DIR/status.txt"
    else
      printf '%s\n' 'status=rollback_failed' > "$LEDGER_DIR/status.txt"
    fi
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  if (( exit_code != 0 )); then
    rollback
    log 'ERROR' "Setup failed. Exit code: $exit_code. Review the timestamped ERROR/ROLLBACK lines above before retrying." >&2
  elif [[ "$RUN_SUCCEEDED" == "1" ]]; then
    printf '\n================================================================\n'
    printf '  IMPORTANT: FULLY QUIT AND RESTART CODEX / CHATGPT NOW.\n'
    printf '================================================================\n'
  fi
  pause_before_exit
  exit "$exit_code"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap on_exit EXIT
fi

require_system_tools() {
  (( BASH_VERSINFO[0] >= 4 )) || die 'Bash 4 or newer is required. No file was changed.'
  [[ -n "${HOME:-}" ]] || die 'HOME is not set. No file was changed.'
  [[ -n "$MANAGED_BASE_URL" ]] || die 'Editable setting MANAGED_BASE_URL is empty. No file was changed.'
  [[ -n "$MANAGED_API_KEY" ]] || die 'Editable setting MANAGED_API_KEY is empty. No file was changed.'
  [[ -n "$DEFAULT_MODEL" ]] || die 'Editable setting DEFAULT_MODEL is empty. No file was changed.'
  [[ -n "$DEFAULT_REASONING_EFFORT" ]] || die 'Editable setting DEFAULT_REASONING_EFFORT is empty. No file was changed.'
  local required
  for required in awk chmod cmp cp cut date find mkdir mktemp mv ps rm sed sleep stat tail tr; do
    command -v "$required" >/dev/null 2>&1 || die "Required Linux command is missing: $required. No file was changed."
  done
  PERL_BIN="$(command -v perl 2>/dev/null)" || die 'Perl is required. Install perl before retrying; no file was changed.'
  SQLITE_BIN="$(command -v sqlite3 2>/dev/null || true)"
  "$PERL_BIN" -MJSON::PP -e 1 >/dev/null 2>&1 || die 'Perl JSON::PP is required; no file was changed.'
  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_BIN="$(command -v sha256sum)"
    SHA256_KIND='sha256sum'
  elif command -v shasum >/dev/null 2>&1; then
    SHA256_BIN="$(command -v shasum)"
    SHA256_KIND='shasum'
  else
    die 'sha256sum or shasum is required. No file was changed.'
  fi
  stat -c '%s' "$0" >/dev/null 2>&1 || die 'GNU/BusyBox-compatible stat -c is required. No file was changed.'
  trace "Prerequisites: bash=$BASH_VERSION; perl=$PERL_BIN; sqlite3=${SQLITE_BIN:-<not-installed>}; sha256=$SHA256_KIND"
}

count_jsonl_files() {
  local codex_data_dir="$1"
  local count=0 session_scan_root
  for session_scan_root in "$codex_data_dir/sessions" "$codex_data_dir/archived_sessions"; do
    [[ -d "$session_scan_root" ]] || continue
    while IFS= read -r -d '' ignored; do
      (( count++ ))
    done < <(find "$session_scan_root" -type f -name '*.jsonl' -print0 2>/dev/null)
  done
  printf '%s\n' "$count"
}

threads_count_for_database() {
  local database="$1" exists count
  [[ -f "$database" ]] || { printf '%s\n' '0'; return 0; }
  [[ -n "$SQLITE_BIN" ]] || return 2
  exists="$("$SQLITE_BIN" "$database" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='threads';" 2>/dev/null)" || return 3
  [[ "$exists" == '1' ]] || { printf '%s\n' '0'; return 0; }
  count="$("$SQLITE_BIN" "$database" 'SELECT count(*) FROM threads;' 2>/dev/null)" || return 3
  [[ "$count" =~ ^[0-9]+$ ]] || return 3
  printf '%s\n' "$count"
}

add_candidate() {
  local raw="$1" source="$2" allow_missing="$3" candidate_dir jsonl threads prior
  if [[ -d "$raw" ]]; then
    candidate_dir="$(cd "$raw" && pwd -P)" || return 0
  elif [[ "$allow_missing" == '1' ]]; then
    candidate_dir="$raw"
  else
    return 0
  fi
  for prior in "${CANDIDATE_HOME[@]:-}"; do
    [[ -n "$prior" ]] || continue
    [[ "$prior" == "$candidate_dir" ]] && return 0
  done
  jsonl="$(count_jsonl_files "$candidate_dir")"
  threads="$(threads_count_for_database "$candidate_dir/state_5.sqlite")"
  local thread_status=$?
  if (( thread_status == 2 )); then
    die "SQLite state exists but sqlite3 CLI is missing: $candidate_dir/state_5.sqlite. Install sqlite3 and retry; no file was changed."
  elif (( thread_status != 0 )); then
    die "SQLite state could not be inspected safely: $candidate_dir/state_5.sqlite. No file was changed."
  fi
  CANDIDATE_HOME+=("$candidate_dir")
  CANDIDATE_SOURCE+=("$source")
  CANDIDATE_JSONL+=("$jsonl")
  CANDIDATE_THREADS+=("$threads")
  trace "DISCOVERY candidate: codex_data_dir=$candidate_dir; source=$source; jsonl=$jsonl; sqlite_threads=$threads"
}

add_managed_patch_candidates() {
  local root marker declared
  for root in "$HOME/.local/share/applications" "$HOME/.local/opt" '/opt'; do
    [[ -d "$root" ]] || { trace "DISCOVERY patch root absent: $root"; continue; }
    while IFS= read -r -d '' marker; do
      declared="$($PERL_BIN -MJSON::PP -e '
        my $file = shift; open my $in, q{<:raw}, $file or exit 0;
        local $/; my $raw = <$in>; my $value = eval { decode_json($raw) }; exit 0 if $@ || ref($value) ne q{HASH};
        print $value->{codex_home} if defined $value->{codex_home} && !ref($value->{codex_home});
      ' "$marker" 2>/dev/null)"
      [[ -n "$declared" ]] || continue
      add_candidate "$declared" "managed patch metadata: $marker" 0
    done < <(find "$root" -maxdepth 5 -type f -name '.codex-gpt56-patch.json' -print0 2>/dev/null)
  done
}

select_codex_home() {
  trace 'DISCOVERY starting CODEX_HOME discovery (argument, environment, default home, clones, managed patch metadata).'
  if [[ -n "${1:-}" ]]; then
    add_candidate "$1" 'explicit command argument' 1
  fi
  if [[ -n "${CODEX_LIGHTWEIGHT_CODEX_HOME:-}" ]]; then
    add_candidate "$CODEX_LIGHTWEIGHT_CODEX_HOME" 'CODEX_LIGHTWEIGHT_CODEX_HOME' 1
  fi
  if [[ -n "${CODEX_HOME:-}" ]]; then
    add_candidate "$CODEX_HOME" 'CODEX_HOME environment variable' 0
  fi
  add_candidate "$HOME/.codex" 'default ~/.codex' 1

  if [[ -d "$HOME/.codex-clones" ]]; then
    local clone
    for clone in "$HOME/.codex-clones"/*; do
      [[ -d "$clone" ]] || continue
      add_candidate "$clone" 'clone directory' 0
    done
  else
    trace "DISCOVERY clone root absent: $HOME/.codex-clones"
  fi
  add_managed_patch_candidates

  (( ${#CANDIDATE_HOME[@]} > 0 )) || die 'No usable CODEX_HOME candidate was found.'

  local index nonempty=0 selected=-1
  for (( index=0; index<${#CANDIDATE_HOME[@]}; index++ )); do
    if (( CANDIDATE_JSONL[$index] > 0 || CANDIDATE_THREADS[$index] > 0 )); then
      (( nonempty++ ))
      selected=$index
    fi
  done

  if (( nonempty == 1 )); then
    SELECTED_HOME="${CANDIDATE_HOME[$selected]}"
    trace "DISCOVERY selected the only candidate containing session state: $SELECTED_HOME"
    return 0
  fi

  if (( nonempty == 0 )); then
    # First installation is valid: prefer the explicit choice, then ~/.codex.
    if [[ -n "${1:-}" ]]; then
      SELECTED_HOME="${CANDIDATE_HOME[0]}"
    else
      for (( index=0; index<${#CANDIDATE_HOME[@]}; index++ )); do
        if [[ "${CANDIDATE_HOME[$index]}" == "$HOME/.codex" ]]; then
          SELECTED_HOME="${CANDIDATE_HOME[$index]}"
          break
        fi
      done
      [[ -n "$SELECTED_HOME" ]] || SELECTED_HOME="${CANDIDATE_HOME[0]}"
    fi
    trace "DISCOVERY selected bootstrap CODEX_HOME with no existing sessions: $SELECTED_HOME"
    return 0
  fi

  printf '\nMultiple CODEX_HOME folders contain sessions. Select one:\n'
  for (( index=0; index<${#CANDIDATE_HOME[@]}; index++ )); do
    printf '  [%d] JSONL %s; SQLite threads %s\n      %s\n      Source: %s\n' \
      "$((index + 1))" "${CANDIDATE_JSONL[$index]}" "${CANDIDATE_THREADS[$index]}" \
      "${CANDIDATE_HOME[$index]}" "${CANDIDATE_SOURCE[$index]}"
  done
  local reply=''
  while true; do
    printf 'Enter a number to continue; any other input cancels: '
    read -r reply || die 'No selection was provided.'
    [[ "$reply" =~ ^[0-9]+$ && "$reply" -ge 1 && "$reply" -le ${#CANDIDATE_HOME[@]} ]] || die 'Cancelled; no file was changed.'
    SELECTED_HOME="${CANDIDATE_HOME[$((reply - 1))]}"
    return 0
  done
}

matching_processes() {
  ps -eo pid=,comm= 2>/dev/null | awk '
    { name=tolower($2) }
    name == "codex" || name == "chatgpt" { print $1 }
  ' || true
}

matching_cc_switch_processes() {
  ps -eo pid=,comm= 2>/dev/null | awk '
    {
      name=tolower($2)
      if (name == "ccswitch" || name == "cc-switch" || name == "cc_switch") print $1
    }
  ' || true
}

wait_for_conversation_apps() {
  local processes elapsed=0
  processes="$(matching_processes)"
  [[ -z "$processes" ]] && return 0
  warn 'Codex/ChatGPT is still running. Close it normally; this script will not force-quit it.'
  while true; do
    sleep 1
    (( elapsed++ ))
    processes="$(matching_processes)"
    [[ -z "$processes" ]] && break
    if (( elapsed % 10 == 0 )); then
      warn "Still waiting for Codex/ChatGPT to exit normally (${elapsed}s)."
    fi
  done
  trace "PROCESS Codex/ChatGPT exited after ${elapsed}s."
}

prepare_ledger() {
  local identity stamp
  identity="$(printf '%s' "$SELECTED_HOME" | sha256_stdin | cut -c1-12)"
  stamp="$(date '+%Y%m%d-%H%M%S')-$identity-$RANDOM"
  LEDGER_DIR="$SELECTED_HOME/backups/codex-gpt56/lightweight-native-linux/$stamp"
  mkdir -p "$LEDGER_DIR/data/config" "$LEDGER_DIR/data/jsonl" "$LEDGER_DIR/data/sqlite" || die 'Could not create the migration ledger.'
  chmod 700 "$LEDGER_DIR" "$LEDGER_DIR/data" || true
  {
    printf '%s\n' 'format=codex-lightweight-linux-v1'
    printf '%s\n' "codex_home=$SELECTED_HOME"
    printf '%s\n' "target_provider=$TARGET_PROVIDER"
    printf '%s\n' "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' 'status=changing'
  } > "$LEDGER_DIR/manifest.txt"
  : > "$LEDGER_DIR/entries.tsv"
  printf '%s\n' 'status=changing' > "$LEDGER_DIR/status.txt"
  trace "LEDGER created: $LEDGER_DIR"
}

make_sibling_temp() {
  local source="$1"
  local directory="${source%/*}"
  local base="${source##*/}"
  mktemp "$directory/.${base}.codex-lightweight.XXXXXX"
}

rewrite_config_to_temp() {
  local config="$1" temporary="$2"
  LIGHTWEIGHT_BASE_URL="$MANAGED_BASE_URL" \
  LIGHTWEIGHT_API_KEY="$MANAGED_API_KEY" \
  LIGHTWEIGHT_DEFAULT_MODEL="$DEFAULT_MODEL" \
  LIGHTWEIGHT_REASONING_EFFORT="$DEFAULT_REASONING_EFFORT" \
  "$PERL_BIN" - "$config" "$temporary" <<'PERL'
use strict;
use warnings;

my ($source, $target) = @ARGV;
my $base_url = $ENV{LIGHTWEIGHT_BASE_URL};
my $api_key = $ENV{LIGHTWEIGHT_API_KEY};
my $model = $ENV{LIGHTWEIGHT_DEFAULT_MODEL};
my $effort = $ENV{LIGHTWEIGHT_REASONING_EFFORT};

sub toml_string {
    my ($value) = @_;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\n/\\n/g;
    $value =~ s/\r/\\r/g;
    return '"' . $value . '"';
}
sub table_name {
    my ($line) = @_;
    return undef unless $line =~ /^\s*\[([^\[\]]+)\]\s*(?:#.*)?$/;
    return $1;
}
sub root_key {
    my ($line) = @_;
    return undef unless $line =~ /^\s*([A-Za-z0-9_-]+)\s*=/;
    return $1;
}

# The lightweight workflow deliberately replaces config.toml in full. The
# source path is accepted only to keep the call signature stable; existing
# bytes are backed up by the shell before the generated file is installed.
my $raw = '';
my $newline = index($raw, "\r\n") >= 0 ? "\r\n" : "\n";
my $terminal_newline = $raw =~ /(?:\r\n|\n|\r)\z/ ? 1 : 0;
my @lines = split /\r\n|\n|\r/, $raw, -1;
pop @lines if $terminal_newline && @lines && $lines[-1] eq '';

my @outside;
my $in_managed = 0;
my $managed_start_a = '# BEGIN CODEX THIRD-PARTY API (managed by configure-codex-third-party)';
my $managed_start_b = '# BEGIN CODEX THIRD-PARTY API (managed by configure-codex-third-party.cmd)';
my $managed_end = '# END CODEX THIRD-PARTY API';
for my $line (@lines) {
    my $trimmed = $line;
    $trimmed =~ s/^\s+|\s+$//g;
    if (!$in_managed && ($trimmed eq $managed_start_a || $trimmed eq $managed_start_b)) {
        $in_managed = 1;
        next;
    }
    if ($in_managed) {
        if ($trimmed eq $managed_end) {
            $in_managed = 0;
        }
        next;
    }
    die "Managed config END marker has no matching BEGIN marker\n" if $trimmed eq $managed_end;
    push @outside, $line;
}
die "Managed config block has no END marker\n" if $in_managed;

my (@root, @tables);
my $current;
my $skip = 0;
for my $line (@outside) {
    my $table = table_name($line);
    if (defined $table) {
        $current = $table;
        $skip = $table eq 'model_providers.custom'
            || $table =~ /^model_providers\.custom\./
            || $table eq 'model_providers.third_party'
            || $table =~ /^model_providers\.third_party\./;
        next if $skip;
    }
    next if $skip;
    if (!defined $current) {
        my $key = root_key($line);
        next if defined($key) && ($key eq 'model_provider' || $key eq 'model' || $key eq 'model_reasoning_effort');
        push @root, $line;
    } else {
        push @tables, $line;
    }
}

shift @root while @root && $root[0] =~ /^\s*$/;
while (@root && $root[-1] =~ /^\s*$/) { pop @root; }
my @managed_root = (
    'model_provider = "custom"',
    'model = ' . toml_string($model),
    'model_reasoning_effort = ' . toml_string($effort),
);
my @custom = (
    '[model_providers.custom]',
    'name = "custom"',
    'base_url = ' . toml_string($base_url),
    'wire_api = "responses"',
    'experimental_bearer_token = ' . toml_string($api_key),
    'requires_openai_auth = false',
    'supports_websockets = false',
);

my $insert_at = 0;
for (my $i = 0; $i < @tables; $i++) {
    next unless defined(table_name($tables[$i])) && table_name($tables[$i]) eq 'model_providers';
    $insert_at = $i + 1;
    while ($insert_at < @tables && !defined(table_name($tables[$insert_at]))) { $insert_at++; }
    last;
}
my @final_tables = (@tables[0 .. $insert_at - 1], @custom, @tables[$insert_at .. $#tables]);
@final_tables = @custom if !@tables;

my @out = (@managed_root);
push @out, '' if @root;
push @out, @root if @root;
push @out, '' if @final_tables;
push @out, @final_tables;
my $result = join($newline, @out) . $newline;

# Validate the generated syntax shape before exposing it to Codex. The script
# only supports plain one-line TOML assignments; it deliberately refuses a
# malformed managed block instead of performing a lossy rewrite.
my $before_table = 1;
my ($provider_count, $model_count, $effort_count, $custom_count) = (0, 0, 0, 0);
for my $line (@out) {
    my $table = table_name($line);
    if (defined $table) {
        $before_table = 0;
        $custom_count++ if $table eq 'model_providers.custom';
        next;
    }
    next unless $before_table;
    $provider_count++ if $line =~ /^\s*model_provider\s*=\s*"custom"\s*(?:#.*)?$/;
    $model_count++ if $line eq 'model = ' . toml_string($model);
    $effort_count++ if $line eq 'model_reasoning_effort = ' . toml_string($effort);
}
die "Generated config failed custom provider validation\n"
    unless $provider_count == 1 && $model_count == 1 && $effort_count == 1 && $custom_count == 1;

open my $output, '>:raw', $target or die "Cannot write config temporary file: $!\n";
print {$output} $result or die "Cannot write config temporary file: $!\n";
close $output or die "Cannot close config temporary file: $!\n";
PERL
}

rewrite_live_config() {
  local config="$SELECTED_HOME/config.toml" temporary before_hash before_state backup='' mode generated_hash
  mkdir -p "$SELECTED_HOME" || die "Could not create CODEX_HOME: $SELECTED_HOME"
  temporary="$(make_sibling_temp "$config")" || die 'Could not create config temporary file.'
  if ! rewrite_config_to_temp "$config" "$temporary"; then
    rm -f "$temporary"
    die 'Could not generate the managed replacement config.toml. No file was changed.'
  fi
  generated_hash="$(sha256_file "$temporary")"

  if [[ -f "$config" ]]; then
    before_hash="$(sha256_file "$config")"
    before_state="$(file_state "$config")"
    mode="$(stat -c '%a' "$config")"
    backup="$LEDGER_DIR/data/config/config.toml.before"
    cp -p "$config" "$backup" || { rm -f "$temporary"; die 'Could not back up config.toml.'; }
    [[ "$(sha256_file "$backup")" == "$before_hash" ]] || { rm -f "$temporary"; die 'Config backup verification failed.'; }
    append_manifest 'config' "$config" "$backup" 'backed_up'
    if ! same_file_state "$config" "$before_state" || [[ "$(sha256_file "$config")" != "$before_hash" ]]; then
      rm -f "$temporary"
      die 'config.toml changed while this script was preparing the rewrite.'
    fi
    chmod "$mode" "$temporary" || true
    mv -f "$temporary" "$config" || die 'Atomic config replacement failed.'
    remember_rollback 'file' "$config" "$backup"
  else
    append_manifest 'config' "$config" '' 'created'
    mv -f "$temporary" "$config" || die 'Could not create config.toml.'
    remember_rollback 'created-file' "$config" ''
  fi
  ROLLBACK_ENABLED=1
  [[ "$(sha256_file "$config")" == "$generated_hash" ]] || die 'Config verification failed after forced replacement.'
  append_manifest 'config' "$config" "$backup" 'changed'
  trace "CONFIG force-replaced and verified; previous_config_backup=${backup:-<none-first-install>}; default_model=$DEFAULT_MODEL; reasoning=$DEFAULT_REASONING_EFFORT; raw TOML and API key are intentionally not printed."
}

extract_root_toml_string() {
  local config="$1" key="$2"
  [[ -f "$config" ]] || return 0
  "$PERL_BIN" -MJSON::PP - "$config" "$key" <<'PERL'
use strict;
use warnings;
my ($file, $key) = @ARGV;
open my $in, '<:raw', $file or exit 0;
while (my $line = <$in>) {
  last if $line =~ /^\s*\[/;
  next unless $line =~ /^\s*\Q$key\E\s*=\s*("(?:\\.|[^"\\])*")\s*(?:#.*)?$/;
  my $value = eval { JSON::PP::decode_json($1) };
  print $value if !$@ && defined $value && !ref($value);
  last;
}
PERL
}

collect_jsonl_paths() {
  JSONL_PATHS=()
  local scan_root session_file
  for scan_root in "$SELECTED_HOME/sessions" "$SELECTED_HOME/archived_sessions"; do
    [[ -d "$scan_root" ]] || continue
    while IFS= read -r -d '' session_file; do
      JSONL_PATHS+=("$session_file")
    done < <(find "$scan_root" -type f -name '*.jsonl' -print0 2>/dev/null)
  done
  trace "MIGRATION JSONL scan completed: ${#JSONL_PATHS[@]} file(s)."
}

resolve_external_sqlite_home() {
  local configured
  configured="$(extract_root_toml_string "$SELECTED_HOME/config.toml" 'sqlite_home')"
  [[ -n "$configured" ]] || configured="${CODEX_SQLITE_HOME:-}"
  [[ -n "$configured" ]] || return 0
  if [[ "$configured" == '~/'* ]]; then
    configured="$HOME/${configured#\~/}"
  elif [[ "$configured" != /* ]]; then
    configured="$SELECTED_HOME/$configured"
  fi
  printf '%s\n' "$configured"
}

collect_sqlite_paths() {
  SQLITE_PATHS=()
  local candidate external prior
  for candidate in "$SELECTED_HOME/state_5.sqlite"; do
    [[ -f "$candidate" ]] && SQLITE_PATHS+=("$candidate")
  done
  external="$(resolve_external_sqlite_home)"
  if [[ -n "$external" && -f "$external/state_5.sqlite" ]]; then
    candidate="$external/state_5.sqlite"
    for prior in "${SQLITE_PATHS[@]:-}"; do
      [[ -n "$prior" ]] || continue
      [[ "$prior" == "$candidate" ]] && candidate=''
    done
    [[ -n "$candidate" ]] && SQLITE_PATHS+=("$candidate")
  fi
  if (( ${#SQLITE_PATHS[@]} > 0 )) && [[ -z "$SQLITE_BIN" ]]; then
    die 'A Codex SQLite state database was found, but sqlite3 CLI is not installed. Install sqlite3 and retry; no file was changed.'
  fi
  local database_file
  for database_file in "${SQLITE_PATHS[@]:-}"; do
    [[ -n "$database_file" ]] || continue
    "$SQLITE_BIN" "$database_file" 'PRAGMA schema_version;' >/dev/null 2>&1 ||
      die "SQLite state database failed preflight validation: $database_file. No file was changed."
  done
  trace "MIGRATION SQLite scan completed: ${#SQLITE_PATHS[@]} database(s)."
}

rewrite_jsonl_to_temp() {
  local source="$1" temporary="$2"
  "$PERL_BIN" - "$source" "$temporary" <<'PERL'
use strict;
use warnings;
use JSON::PP qw(decode_json);

my ($source, $target) = @ARGV;
open my $input, '<:raw', $source or die "Cannot read JSONL: $!\n";
local $/;
my $bytes = <$input> // '';
close $input;
my $text = $bytes;

sub skip_ws { my ($s, $i) = @_; $i++ while $i < length($s) && substr($s, $i, 1) =~ /[ \t\r\n]/; return $i; }
sub scan_string {
  my ($s, $i) = @_;
  die "Expected JSON string\n" unless substr($s, $i, 1) eq '"';
  $i++;
  while ($i < length($s)) {
    my $c = substr($s, $i, 1);
    return $i + 1 if $c eq '"';
    $i += ($c eq '\\') ? 2 : 1;
  }
  die "Unterminated JSON string\n";
}
sub scan_value {
  my ($s, $i) = @_;
  $i = skip_ws($s, $i);
  die "Unexpected JSON end\n" if $i >= length($s);
  my $c = substr($s, $i, 1);
  return scan_string($s, $i) if $c eq '"';
  if ($c eq '{' || $c eq '[') {
    my ($open, $close) = $c eq '{' ? ('{', '}') : ('[', ']');
    my $depth = 0;
    while ($i < length($s)) {
      my $x = substr($s, $i, 1);
      if ($x eq '"') { $i = scan_string($s, $i); next; }
      $depth++ if $x eq $open;
      if ($x eq $close) { $depth--; return $i + 1 if $depth == 0; }
      $i++;
    }
    die "Unterminated JSON container\n";
  }
  my $tail = substr($s, $i);
  $tail =~ /\A(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/ or die "Invalid JSON scalar\n";
  return $i + length($&);
}
sub object_members {
  my ($s, $start) = @_;
  $start = skip_ws($s, $start);
  die "Expected JSON object\n" unless substr($s, $start, 1) eq '{';
  my $i = skip_ws($s, $start + 1);
  return [] if substr($s, $i, 1) eq '}';
  my @members;
  while (1) {
    my $key_start = $i;
    my $key_end = scan_string($s, $i);
    my $key = decode_json(substr($s, $key_start, $key_end - $key_start));
    $i = skip_ws($s, $key_end);
    die "Invalid JSON object separator\n" unless substr($s, $i, 1) eq ':';
    my $value_start = skip_ws($s, $i + 1);
    my $value_end = scan_value($s, $value_start);
    $i = skip_ws($s, $value_end);
    my $comma = undef;
    if (substr($s, $i, 1) eq ',') { $comma = $i; $i = skip_ws($s, $i + 1); }
    elsif (substr($s, $i, 1) ne '}') { die "Invalid JSON object terminator\n"; }
    push @members, { key => $key, key_start => $key_start, value_start => $value_start, value_end => $value_end, comma => $comma };
    return \@members unless defined $comma;
  }
}
sub replace_provider {
  my ($line) = @_;
  my $top = skip_ws($line, 0);
  my $payload_member = undef;
  for my $member (@{object_members($line, $top)}) {
    $payload_member = $member if $member->{key} eq 'payload';
  }
  die "session_meta has no object payload\n" unless defined $payload_member && substr($line, $payload_member->{value_start}, 1) eq '{';
  my $payload_start = $payload_member->{value_start};
  my $payload_end = $payload_member->{value_end};
  my @providers = grep { $_->{key} eq 'model_provider' } @{object_members($line, $payload_start)};
  die "Duplicate model_provider field in session_meta\n" if @providers > 1;
  if (@providers) {
    my $provider = $providers[0];
    return substr($line, 0, $provider->{value_start}) . '"custom"' . substr($line, $provider->{value_end});
  }
  my $members = object_members($line, $payload_start);
  my $insert = @$members ? ',' : '';
  my $close = $payload_end - 1;
  return substr($line, 0, $close) . $insert . '"model_provider":"custom"' . substr($line, $close);
}
sub session_id {
  my ($payload) = @_;
  for my $key (qw(id session_id thread_id)) {
    return $payload->{$key} if defined($payload->{$key}) && !ref($payload->{$key}) && length($payload->{$key});
  }
  return undef;
}

my @bits = split /(\r\n|\n|\r)/, $text, -1;
my (@rows, @ids);
for (my $i = 0; $i <= $#bits; $i += 2) {
  my $body = $bits[$i];
  my $ending = $bits[$i + 1] // '';
  my $parsed = undef;
  if ($body =~ /\S/) {
    $parsed = eval { decode_json($body) };
    die "Damaged JSONL record: $@" if $@ || ref($parsed) ne 'HASH';
    if (($parsed->{type} // '') eq 'session_meta' && ref($parsed->{payload}) eq 'HASH') {
      my $id = session_id($parsed->{payload});
      push @ids, $id if defined $id;
    }
  }
  push @rows, [$body, $ending, $parsed];
}
my %seen;
my @unique_ids = grep { !$seen{$_}++ } @ids;
my $canonical;
if ($source =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i) {
  my $file_id = lc $1;
  ($canonical) = grep { lc($_) eq $file_id } @unique_ids;
}
$canonical = $unique_ids[0] if !defined($canonical) && @unique_ids == 1;
die "Ambiguous session_meta IDs; refusing this JSONL file\n" if !defined($canonical) && @unique_ids > 1;

my ($changed, %providers, @out) = (0);
for my $row (@rows) {
  my ($body, $ending, $parsed) = @$row;
  if (defined($parsed) && ($parsed->{type} // '') eq 'session_meta' && ref($parsed->{payload}) eq 'HASH') {
    my $id = session_id($parsed->{payload});
    if (!defined($canonical) || (defined($id) && $id eq $canonical)) {
      my $provider = $parsed->{payload}->{model_provider};
      if (!defined($provider) || ref($provider) || $provider ne 'custom') {
        $providers{defined($provider) && !ref($provider) && length($provider) ? $provider : '<missing>'} = 1;
        $body = replace_provider($body);
        $changed++;
      }
    }
  }
  push @out, $body . $ending;
}
open my $output, '>:raw', $target or die "Cannot write JSONL temporary file: $!\n";
print {$output} join('', @out) or die "Cannot write JSONL temporary file: $!\n";
close $output or die "Cannot close JSONL temporary file: $!\n";
print "changed_lines=$changed;source_providers=" . join(',', sort keys %providers) . "\n";
PERL
}

migrate_jsonl_file() {
  local source="$1" temporary verify_temp before_hash before_state backup path_hash mode output
  trace "JSONL planning provider-only migration: $source"
  before_hash="$(sha256_file "$source")"
  before_state="$(file_state "$source")"
  mode="$(stat -c '%a' "$source")"
  temporary="$(make_sibling_temp "$source")" || die "Could not create a JSONL temporary file: $source"
  if ! output="$(rewrite_jsonl_to_temp "$source" "$temporary")"; then
    rm -f "$temporary"
    die "JSONL safety validation failed: $source"
  fi
  if cmp -s "$source" "$temporary"; then
    rm -f "$temporary"
    trace "JSONL already custom or contains no session_meta: $source"
    return 0
  fi
  path_hash="$(printf '%s' "$source" | sha256_stdin | cut -c1-16)"
  backup="$LEDGER_DIR/data/jsonl/$path_hash/${source##*/}"
  mkdir -p "${backup%/*}" || { rm -f "$temporary"; die 'Could not create JSONL backup directory.'; }
  cp -p "$source" "$backup" || { rm -f "$temporary"; die "Could not back up JSONL: $source"; }
  [[ "$(sha256_file "$backup")" == "$before_hash" ]] || { rm -f "$temporary"; die "JSONL backup verification failed: $source"; }
  append_manifest 'jsonl' "$source" "$backup" 'backed_up'
  if ! same_file_state "$source" "$before_state" || [[ "$(sha256_file "$source")" != "$before_hash" ]]; then
    rm -f "$temporary"
    die "JSONL changed concurrently: $source"
  fi
  chmod "$mode" "$temporary" || true
  mv -f "$temporary" "$source" || die "Atomic JSONL replacement failed: $source"
  remember_rollback 'file' "$source" "$backup"
  ROLLBACK_ENABLED=1
  verify_temp="$(make_sibling_temp "$source")" || die "Could not create JSONL verification temporary file: $source"
  if ! rewrite_jsonl_to_temp "$source" "$verify_temp" || ! cmp -s "$source" "$verify_temp"; then
    rm -f "$verify_temp"
    die "JSONL post-write verification failed: $source"
  fi
  rm -f "$verify_temp"
  append_manifest 'jsonl' "$source" "$backup" 'changed'
  trace "JSONL changed and verified: $source; $output"
  JSONL_CHANGED=$(( JSONL_CHANGED + 1 ))
  local count
  count="$(printf '%s\n' "$output" | sed -n 's/^changed_lines=\([0-9][0-9]*\).*/\1/p')"
  [[ "$count" =~ ^[0-9]+$ ]] && JSONL_META_CHANGED=$(( JSONL_META_CHANGED + count ))
}

sqlite_has_threads_table() {
  local database="$1"
  [[ "$("$SQLITE_BIN" "$database" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='threads';" 2>/dev/null)" == '1' ]]
}

migrate_sqlite_database() {
  local database="$1" total targets before_noncustom backup path_hash before_hash changed after_noncustom
  sqlite_has_threads_table "$database" || { trace "SQLITE threads table absent; skipped: $database"; return 0; }
  total="$("$SQLITE_BIN" "$database" 'SELECT count(*) FROM threads;' 2>/dev/null)" || die "Could not inspect SQLite database: $database"
  targets="$("$SQLITE_BIN" "$database" "SELECT count(*) FROM threads WHERE model_provider IS NULL OR model_provider <> 'custom';" 2>/dev/null)" || die "Could not inspect SQLite providers: $database"
  [[ "$targets" =~ ^[0-9]+$ ]] || die "SQLite returned an invalid target count: $database"
  [[ "$total" =~ ^[0-9]+$ ]] || die "SQLite returned an invalid total count: $database"
  if (( targets == 0 )); then
    trace "SQLITE provider metadata already custom: $database; total_threads=$total"
    return 0
  fi
  before_hash="$(sha256_file "$database")"
  path_hash="$(printf '%s' "$database" | sha256_stdin | cut -c1-16)"
  backup="$LEDGER_DIR/data/sqlite/$path_hash/${database##*/}"
  mkdir -p "${backup%/*}" || die 'Could not create SQLite backup directory.'
  trace "SQLITE online backup: database=$database; total_threads=$total; provider_rows_to_change=$targets"
  "$SQLITE_BIN" "$database" ".backup $(sql_quote "$backup")" >/dev/null || die "SQLite online backup failed: $database"
  sqlite_has_threads_table "$backup" || die "SQLite backup verification failed: $database"
  [[ "$("$SQLITE_BIN" "$backup" 'SELECT count(*) FROM threads;' 2>/dev/null)" == "$total" ]] || die "SQLite backup row-count verification failed: $database"
  [[ "$(sha256_file "$database")" == "$before_hash" ]] || die "SQLite database changed while the backup was being prepared: $database"
  append_manifest 'sqlite' "$database" "$backup" 'backed_up'
  # Register the verified backup before the transaction begins. If SQLite
  # reports an error after applying a statement, the EXIT trap can still
  # restore the complete database image.
  remember_rollback 'sqlite' "$database" "$backup"
  ROLLBACK_ENABLED=1
  changed="$("$SQLITE_BIN" "$database" <<'SQL'
PRAGMA busy_timeout=10000;
BEGIN IMMEDIATE;
UPDATE threads
SET model_provider = 'custom'
WHERE model_provider IS NULL OR model_provider <> 'custom';
SELECT changes();
COMMIT;
SQL
  )" || die "SQLite transaction failed: $database"
  changed="$(printf '%s\n' "$changed" | tail -n 1 | tr -d '[:space:]')"
  [[ "$changed" == "$targets" ]] || die "SQLite update count changed unexpectedly for $database (expected $targets, got $changed)."
  after_noncustom="$("$SQLITE_BIN" "$database" "SELECT count(*) FROM threads WHERE model_provider IS NULL OR model_provider <> 'custom';" 2>/dev/null)" || die "Could not verify SQLite result: $database"
  [[ "$after_noncustom" == '0' ]] || die "SQLite still has non-custom provider rows: $database"
  [[ "$("$SQLITE_BIN" "$database" 'SELECT count(*) FROM threads;' 2>/dev/null)" == "$total" ]] || die "SQLite thread count changed unexpectedly: $database"
  append_manifest 'sqlite' "$database" "$backup" 'changed'
  SQLITE_ROWS_CHANGED=$(( SQLITE_ROWS_CHANGED + changed ))
  trace "SQLITE changed and verified: $database; provider_rows_changed=$changed"
}

main() {
  require_system_tools
  select_codex_home "${1:-}"
  [[ -n "$SELECTED_HOME" ]] || die 'CODEX_HOME selection failed.'

  printf '\nCodex lightweight session unifier (Linux, no Python/Node)\n\n'
  printf 'Target CODEX_HOME : %s\n' "$SELECTED_HOME"
  printf 'Target provider   : %s\n' "$TARGET_PROVIDER"
  printf 'Base URL          : %s\n' "$MANAGED_BASE_URL"
  printf 'Default model     : %s\n' "$DEFAULT_MODEL"
  printf 'Reasoning effort  : %s\n' "$DEFAULT_REASONING_EFFORT"
  printf 'Scope             : sessions, archived_sessions, state_5.sqlite\n'
  printf 'Config policy     : replace config.toml in full on every run; back up the previous file in the ledger\n'
  printf 'Not modified      : CC Switch database, model catalogs, application bundles, session bodies\n\n'
  step 'This script only changes local config and provider metadata. It does not upload conversation content.'
  step 'You may start it while Codex/ChatGPT/CC Switch is open. After confirmation it waits for Codex/ChatGPT to exit normally and never force-quits them.'
  if [[ -n "$(matching_cc_switch_processes)" ]]; then
    warn 'CC Switch appears to be running. Do not switch provider until this script finishes; a later config change is detected and treated as a failure.'
  fi

  local reply=''
  printf 'Enter Y to continue; any other input cancels: '
  read -r reply || die 'Cancelled; no file was changed.'
  [[ "$reply" == 'Y' || "$reply" == 'y' ]] || { step 'Cancelled by user; no file was changed.'; return 0; }

  wait_for_conversation_apps
  mkdir -p "$SELECTED_HOME" || die "Could not create CODEX_HOME: $SELECTED_HOME"
  prepare_ledger
  JSONL_CHANGED=0
  JSONL_META_CHANGED=0
  SQLITE_ROWS_CHANGED=0

  collect_jsonl_paths
  collect_sqlite_paths
  rewrite_live_config

  local session_file database_file
  if (( ${#JSONL_PATHS[@]} > 0 )); then
    for session_file in "${JSONL_PATHS[@]}"; do
      migrate_jsonl_file "$session_file"
    done
  fi
  if (( ${#SQLITE_PATHS[@]} > 0 )); then
    for database_file in "${SQLITE_PATHS[@]}"; do
      migrate_sqlite_database "$database_file"
    done
  fi

  # A CC Switch provider change during migration must never be overwritten.
  # Regenerate the complete managed config and compare it without printing it.
  local check_temp
  check_temp="$(make_sibling_temp "$SELECTED_HOME/config.toml")" || die 'Could not create final config validation file.'
  if ! rewrite_config_to_temp "$SELECTED_HOME/config.toml" "$check_temp"; then
    rm -f "$check_temp"
    die 'Final config validation failed.'
  fi
  if ! cmp -s "$SELECTED_HOME/config.toml" "$check_temp"; then
    rm -f "$check_temp"
    die 'config.toml changed during migration (for example, by a CC Switch provider switch). All changed artifacts will be rolled back.'
  fi
  rm -f "$check_temp"

  printf '%s\n' 'status=complete' > "$LEDGER_DIR/status.txt"
  printf '%s\n' 'status=complete' >> "$LEDGER_DIR/manifest.txt"
  ROLLBACK_ENABLED=0
  RUN_SUCCEEDED=1
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  printf '\n'
  step "Completed. Migration ledger: $LEDGER_DIR"
  step "JSONL: scanned ${#JSONL_PATHS[@]}, changed $JSONL_CHANGED; session_meta lines changed $JSONL_META_CHANGED. SQLite: scanned ${#SQLITE_PATHS[@]}, rows changed $SQLITE_ROWS_CHANGED."
  step "Live config is custom + responses + requires_openai_auth=false; default model=$DEFAULT_MODEL; reasoning=$DEFAULT_REASONING_EFFORT; no env_key dependency."
  step "Elapsed: ${elapsed}s."
  warn 'This lightweight script does not patch any model-picker UI; it only sets the root default reasoning effort to xhigh.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
