#!/usr/bin/env bash
set -euo pipefail

# The media widget's optional iCloud photo-library sync. Runs the
# boredazfcuk/icloudpd image as a pinned, labelled container that only this
# script is allowed to touch.

# Pinned to an audited immutable digest of the multi-arch index, so every
# platform gets the same image and a tag update can never change behavior
# silently. To audit/update: `docker manifest inspect boredazfcuk/icloudpd:latest`
# and compare the tag's index digest against this value.
IMAGE="boredazfcuk/icloudpd@sha256:3ed0e4514132580d1b44034ff98b0f8685f5856ee5738ac3954c85d07eb92c52"
CONTAINER="omarchy-mediawidget-icloudpd"
VOLUME="omarchy-mediawidget-icloudpd-config"
OWNERSHIP_LABEL="io.github.ras.mediawidget=icloudpd"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mediawidget"
ENV_FILE="$CONFIG_DIR/icloudpd.env"
DOWNLOAD_DIR="${ICLOUD_DOWNLOAD_DIR:-$HOME/Pictures/mediawidget}"

log() { printf '\033[1;34m[icloud]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[icloud]\033[0m %s\n' "$*" >&2; exit 1; }

env_file() {
    # Private per-user config: the directory is 0700 and the env file 0600
    # because it holds an Apple ID and authentication secrets.
    mkdir -p -m 0700 "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    local lib="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name 'SharedSync-*' 2>/dev/null | head -1)"
    lib="${lib##*/}"
    if [[ ! -f "$ENV_FILE" ]]; then
        umask 077
        cat > "$ENV_FILE" <<EOF
apple_id=YOUR_APPLE_ID
user=${USER:-$(id -un)}
user_id=$(id -u)
group=${USER:-$(id -un)}
group_id=$(id -g)
TZ=${TZ:-Europe/Paris}
convert_heic_to_jpeg=true
photo_library=${lib:-SharedSync-LIBRARY_ID}
folder_structure=none
download_path=/home/${USER:-$(id -un)}/iCloud
download_interval=86400
EOF
    fi
    chmod 600 "$ENV_FILE"
    echo "$ENV_FILE"
}

# Every container/volume this script manages carries the ownership label, so
# a same-named resource created by something else is never stopped, removed,
# or reused.
container_owned() {
    local id="$1"
    local label
    label="$(docker inspect "$id" --format '{{ index .Config.Labels "io.github.ras.mediawidget" }}' 2>/dev/null || true)"
    [[ "$label" == "icloudpd" ]]
}

volume_owned() {
    local label
    label="$(docker volume inspect "$VOLUME" --format '{{ index .Labels "io.github.ras.mediawidget" }}' 2>/dev/null || true)"
    [[ "$label" == "icloudpd" ]]
}

ensure_volume() {
    if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
        volume_owned || die "volume '$VOLUME' exists but is not owned by this plugin; refusing to touch it."
        return
    fi
    docker volume create --label "$OWNERSHIP_LABEL" "$VOLUME" >/dev/null
}

ensure_running() {
    local id
    id="$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.ID}}' | head -1)"
    if [[ -z "$id" ]]; then
        ensure_volume
        log "starting container..."
        docker run -d \
            --name "$CONTAINER" \
            --label "$OWNERSHIP_LABEL" \
            --restart unless-stopped \
            --env-file "$(env_file)" \
            --volume "$VOLUME:/config" \
            --volume "$DOWNLOAD_DIR:/home/${USER:-$(id -un)}/iCloud" \
            --cap-drop ALL \
            --security-opt no-new-privileges \
            --memory 1g \
            --cpus 2 \
            --pids-limit 512 \
            "$IMAGE"
        log "container started, waiting for it to initialise..."
        sleep "${ICLOUD_START_SLEEP:-6}"
        return
    fi

    container_owned "$id" || die "container '$CONTAINER' exists but is not owned by this plugin; refusing to touch it."

    if ! docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        log "restarting existing stopped container..."
        docker start "$CONTAINER" >/dev/null
        sleep 2
    fi
}

case "${1:-}" in
    init)
        mkdir -p "$DOWNLOAD_DIR"
        ensure_running
        log "first login: enter your Apple ID password and the 6-digit code when prompted."
        docker exec -it "$CONTAINER" sync-icloud.sh --Initialise
        log "done. credentials are stored in the '${VOLUME}' volume."
        log "the container syncs automatically every 24h; manual sync: $0 sync"
        ;;
    sync)
        ensure_running
        log "syncing iCloud library into $DOWNLOAD_DIR ..."
        docker exec -it "$CONTAINER" sync-icloud.sh
        log "sync finished."
        ;;
    reauth)
        ensure_running
        log "renewing the MFA cookie (interactive)..."
        docker exec -it "$CONTAINER" reauth.sh
        log "reauth done."
        ;;
    daemon)
        ensure_running
        log "container running: $(docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}} {{.Status}}')"
        ;;
    logs)
        ensure_running
        docker logs --tail 50 "$CONTAINER"
        ;;
    stop)
        id="$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.ID}}' | head -1)"
        if [[ -z "$id" ]]; then
            log "no container to stop."
        else
            container_owned "$id" || die "container '$CONTAINER' is not owned by this plugin; refusing to stop/remove it."
            docker stop "$CONTAINER" >/dev/null && docker rm "$CONTAINER" >/dev/null
            log "container stopped and removed."
        fi
        ;;
    status)
        id="$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.ID}}' | head -1)"
        if [[ -z "$id" ]]; then
            log "no container (start one with '$0 init' or '$0 sync')."
        elif container_owned "$id"; then
            docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}} {{.Status}}'
        else
            die "container '$CONTAINER' exists but is not owned by this plugin."
        fi
        ;;
    *)
        echo "usage: $0 {init|sync|reauth|daemon|status|logs|stop}"
        echo "  init    first-time Apple ID login (interactive, once)"
        echo "  sync    download iCloud photos now (interactive)"
        echo "  reauth  renew the 2FA cookie when sync stops working"
        echo "  daemon  ensure the background container is running (auto-restarts on boot)"
        echo "  status  show container status"
        echo "  logs    show recent container logs"
        echo "  stop    stop and remove the container"
        exit 1
        ;;
esac