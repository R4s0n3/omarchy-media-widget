#!/usr/bin/env bash
set -euo pipefail

IMAGE="boredazfcuk/icloudpd"
CONTAINER="icloudpd"
VOLUME="icloudpd_config"
DOWNLOAD_DIR="${ICLOUD_DOWNLOAD_DIR:-$HOME/Pictures/mediawidget}"

log() { printf '\033[1;34m[icloud]\033[0m %s\n' "$*"; }

env_file() {
    local f="$HOME/.config/mediawidget/icloudpd.env"
    local lib="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name 'SharedSync-*' | head -1)"
    lib="${lib##*/}"
    if [[ ! -f "$f" ]]; then
        cat > "$f" <<EOF
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
    echo "$f"
}

ensure_running() {
    if ! docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        log "starting container..."
        docker run -d --name "$CONTAINER" --restart unless-stopped \
            --env-file "$(env_file)" \
            --volume "$VOLUME:/config" \
            --volume "$DOWNLOAD_DIR:/home/${USER:-$(id -un)}/iCloud" \
            "$IMAGE"
        log "container started, waiting for it to initialise..."
        sleep 6
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
        docker logs --tail 50 "$CONTAINER"
        ;;
    stop)
        docker stop "$CONTAINER" && docker rm "$CONTAINER"
        log "container stopped and removed."
        ;;
    status)
        docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}} {{.Status}}'
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