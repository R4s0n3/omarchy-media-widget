#!/usr/bin/env bash
# Tests for scripts/sync_icloud.sh using a stateful fake `docker` on PATH.
# Never touches a real container/volume/directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/sync_icloud.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolated HOME/config and download dir.
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg-config"
export ICLOUD_DOWNLOAD_DIR="$TMP/downloads"
mkdir -p "$HOME" "$ICLOUD_DOWNLOAD_DIR"
export ICLOUD_START_SLEEP=0

# ---- fake docker -------------------------------------------------------------
STATE="$TMP/dockerstate"
mkdir -p "$STATE"
export FAKE_STATE="$STATE"
export FAKE_LOG="$TMP/docker.log"
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
set -u
cmd="$1"; shift
echo "docker $cmd $*" >> "$FAKE_LOG"
case "$cmd" in
  ps)
    any=false; fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) any=true; shift ;;
        --format) fmt="$2"; shift 2 ;;
        --format=*) fmt="${1#--format=}"; shift ;;
        --filter) shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ ! -f "$FAKE_STATE/container" ]]; then exit 0; fi
    read -r id name label running < "$FAKE_STATE/container"
    if $any || [[ "$running" == "yes" ]]; then
      case "$fmt" in
        '{{.ID}}') printf '%s\n' "$id" ;;
        '{{.Names}}') printf '%s\n' "$name" ;;
        '{{.Names}} {{.Status}}') printf '%s up\n' "$name" ;;
      esac
    fi
    ;;
  inspect)
    fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) fmt="$2"; shift 2 ;;
        --format=*) fmt="${1#--format=}"; shift ;;
        *) shift ;;
      esac
    done
    if [[ ! -f "$FAKE_STATE/container" ]]; then exit 1; fi
    read -r id name label running < "$FAKE_STATE/container"
    case "$fmt" in
      *Config.Labels*) printf '%s\n' "$label" ;;
      *) printf '%s\n' "$id" ;;
    esac
    ;;
  volume)
    sub="$1"; shift
    fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) fmt="$2"; shift 2 ;;
        --format=*) fmt="${1#--format=}"; shift ;;
        *) shift ;;
      esac
    done
    case "$sub" in
      inspect)
        if [[ ! -f "$FAKE_STATE/volume" ]]; then exit 1; fi
        if [[ "$fmt" == *Labels* ]]; then printf '%s\n' "$(cat "$FAKE_STATE/volume")"; fi
        ;;
      create)
        printf '%s\n' "$(cat "$FAKE_STATE/volume" 2>/dev/null || printf icloudpd)" > "$FAKE_STATE/volume"
        ;;
    esac
    ;;
  run)
    name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s %s icloudpd yes\n' "deadbeef" "$name" > "$FAKE_STATE/container"
    ;;
  start)
    if [[ -f "$FAKE_STATE/container" ]]; then
      read -r id name label running < "$FAKE_STATE/container"
      printf '%s %s %s yes\n' "$id" "$name" "$label" > "$FAKE_STATE/container"
    fi
    ;;
  stop)
    if [[ -f "$FAKE_STATE/container" ]]; then
      read -r id name label running < "$FAKE_STATE/container"
      printf '%s %s %s no\n' "$id" "$name" "$label" > "$FAKE_STATE/container"
    fi
    ;;
  rm)
    rm -f "$FAKE_STATE/container"
    ;;
  exec)
    exit 0
    ;;
esac
FAKE
chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

# ---- helpers -----------------------------------------------------------------
fails=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; fails=1; }

docker_log_has() { grep -Fq -- "$1" "$FAKE_LOG"; }
config_dir="$XDG_CONFIG_HOME/mediawidget"
env_file="$config_dir/icloudpd.env"

# ---- init on a fresh system ---------------------------------------------------
: > "$FAKE_LOG"
"$SCRIPT" init
if docker_log_has "docker run -d --name omarchy-mediawidget-icloudpd"; then ok "container created on init"; else fail "init did not create container"; fi
if docker_log_has "@sha256:"; then ok "image is digest-pinned"; else fail "image not digest-pinned"; fi
if docker_log_has "--cap-drop ALL" && docker_log_has "no-new-privileges"; then ok "hardening flags present"; else fail "hardening flags missing"; fi
if [[ -d "$config_dir" ]] && [[ "$(stat -c %a "$config_dir")" == "700" ]]; then ok "config dir 0700"; else fail "config dir permissions"; fi
if [[ -f "$env_file" ]] && [[ "$(stat -c %a "$env_file")" == "600" ]]; then ok "env file 0600"; else fail "env file permissions"; fi

# ---- re-init with a stopped, correctly-labeled container ----------------------
: > "$FAKE_LOG"
printf '%s %s %s %s\n' "deadbeef" "omarchy-mediawidget-icloudpd" "icloudpd" "no" > "$STATE/container"
"$SCRIPT" init
if docker_log_has "docker start omarchy-mediawidget-icloudpd"; then ok "stopped labeled container is restarted (not recreated)"; else fail "stopped container not restarted"; fi
if ! docker_log_has "docker run "; then ok "no duplicate container"; else fail "container recreated"; fi

# ---- sync starts a stopped container -------------------------------------------
: > "$FAKE_LOG"
printf '%s %s %s %s\n' "deadbeef" "omarchy-mediawidget-icloudpd" "icloudpd" "no" > "$STATE/container"
"$SCRIPT" sync
if docker_log_has "docker start omarchy-mediawidget-icloudpd"; then ok "sync starts stopped container"; else fail "sync did not start container"; fi

# ---- volume without label refuses a fresh init ----------------------------------
printf '%s\n' "unrelated-label" > "$STATE/volume"
rm -f "$STATE/container"
: > "$FAKE_LOG"
if "$SCRIPT" init >/dev/null 2>&1; then fail "unlabeled volume should refuse init"; else ok "unlabeled volume refused"; fi
if docker_log_has "docker run "; then fail "docker run issued despite bad volume"; else ok "no docker run on bad volume"; fi
printf '%s\n' "icloudpd" > "$STATE/volume"

# ---- container without label refuses to stop -----------------------------------
printf '%s %s %s %s\n' "deadbeef" "omarchy-mediawidget-icloudpd" "other-label" "yes" > "$STATE/container"
: > "$FAKE_LOG"
if "$SCRIPT" stop >/dev/null 2>&1; then fail "unlabeled container should refuse stop"; else ok "unlabeled container refused stop"; fi
if docker_log_has "docker stop "; then fail "docker stop issued despite bad label"; else ok "no docker stop on bad label"; fi
printf '%s %s %s %s\n' "deadbeef" "omarchy-mediawidget-icloudpd" "icloudpd" "yes" > "$STATE/container"

# ---- stop actually stops --------------------------------------------------------
: > "$FAKE_LOG"
"$SCRIPT" stop
if docker_log_has "docker stop omarchy-mediawidget-icloudpd"; then ok "stop issued for labeled container"; else fail "stop not issued"; fi

echo
if [[ "$fails" -eq 0 ]]; then echo "test_icloud: ALL PASS"; else echo "test_icloud: FAILURES"; exit 1; fi