
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/home/mahir/blue-green-deployment"
LOG_FILE="$PROJECT_DIR/deploy.log"

mkdir -p "$PROJECT_DIR"
touch "$LOG_FILE"

log() {
    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" |
        tee -a "$LOG_FILE" >&2
}

get_active_green_port() {
    local running port

    if ! docker inspect green >/dev/null 2>&1; then
        log "ERROR: Green container does not exist."
        return 1
    fi

    running=$(docker inspect \
        --format '{{.State.Running}}' green)

    if [[ "$running" != "true" ]]; then
        log "ERROR: Green container is not running."
        return 1
    fi

    port=$(docker inspect \
        --format '{{with index .NetworkSettings.Ports "80/tcp"}}{{if .}}{{(index . 0).HostPort}}{{end}}{{end}}' \
        green)

    if [[ -z "$port" ]]; then
        log "ERROR: Could not determine Green's host port."
        return 1
    fi

    log "Active Green container is running on port $port"
    printf '%s\n' "$port"
}

find_available_port() {
    local port attempts=0

    while (( attempts < 101 )); do
        port=$(shuf -i 2000-2100 -n 1)

        if ! ss -H -ltn "( sport = :$port )" | grep -q . &&
           ! docker ps --filter "publish=$port" \
               --format '{{.ID}}' | grep -q .; then
            log "Available port selected: $port"
            printf '%s\n' "$port"
            return 0
        fi

        log "Port $port is occupied; trying another port."
        ((attempts += 1))
    done

    log "ERROR: No available port found."
    return 1
}

log "Blue-Green deployment script started."

check_health() {
    local port="$1"
    local expected_version="$2"
    local response
    local attempt

    log "Starting health check on port $port"

    for attempt in {1..10}; do
        if response=$(curl -fsS --max-time 3 "http://127.0.0.1:$port/" 2>/dev/null) &&
           grep -Fq "Version: $expected_version" <<< "$response"; then
            log "Health check PASSED for $expected_version on port $port"
            return 0
        fi

        log "Attempt $attempt/10 failed; retrying in 2 seconds"
        sleep 2
    done

    log "ERROR: Health check FAILED for $expected_version on port $port"
    return 1
}
switch_traffic() {
    local new_port="$1"
    local expected_version="$2"

    log "Requesting verified Nginx switch to $expected_version on port $new_port"

    if sudo -n /usr/local/sbin/blue-green-nginx-switch "$new_port" "$expected_version"; then
        log "SUCCESS: Nginx traffic switch verified."
        return 0
    fi

    log "ERROR: Nginx switch failed; the helper attempted to restore the previous upstream."
    return 1
}

get_deployment_state() {
    local state_file="$PROJECT_DIR/deployment.state"

    if [[ ! -f "$state_file" ]]; then
        log "ERROR: Deployment state file not found."
        return 1
    fi

    # Load the active slot and port.
    source "$state_file"

    if [[ "$ACTIVE_SLOT" != "blue" && "$ACTIVE_SLOT" != "green" ]]; then
        log "ERROR: Invalid active slot in state file."
        return 1
    fi

    if [[ ! "$ACTIVE_PORT" =~ ^[0-9]+$ ]] ||
       (( ACTIVE_PORT < 2000 || ACTIVE_PORT > 2100 )); then
        log "ERROR: Invalid active port in state file."
        return 1
    fi

    log "Current active slot: $ACTIVE_SLOT"
    log "Current active port: $ACTIVE_PORT"

    printf '%s %s\n' "$ACTIVE_SLOT" "$ACTIVE_PORT"
}
get_inactive_slot() {
    local state

    state=$(get_deployment_state) || return 1

    case "$state" in
        blue\ *)
            printf 'green\n'
            ;;
        green\ *)
            printf 'blue\n'
            ;;
        *)
            log "ERROR: Could not determine inactive slot."
            return 1
            ;;
    esac
}
deploy_version() {
    local image="$1"
    local expected_version="$2"
    local state
    local active_slot
    local active_port
    local inactive_slot
    local new_port
    local candidate
    local state_file="$PROJECT_DIR/deployment.state"
    local temp_state="$PROJECT_DIR/deployment.state.tmp"

    log "Starting automated deployment of $image"

    # Read the currently active slot and port.
    state=$(get_deployment_state) || return 1
    read -r active_slot active_port <<< "$state"

    # Select the inactive slot.
    inactive_slot=$(get_inactive_slot) || return 1
    candidate="${inactive_slot}-candidate"

    log "Active slot: $active_slot on port $active_port"
    log "Incoming slot: $inactive_slot"

    # Allocate a port dynamically.
    new_port=$(find_available_port) || return 1

    # Remove only a stale candidate from an earlier attempt.
    if docker inspect "$candidate" >/dev/null 2>&1; then
        log "Removing stale candidate container $candidate"
        docker rm -f "$candidate" || return 1
    fi

    # Start the incoming container without touching active traffic.
    if ! docker run -d \
        --name "$candidate" \
        --restart unless-stopped \
        -p "$new_port:80" \
        "$image" >/dev/null; then
        log "ERROR: Incoming container failed to start."
        return 1
    fi

    log "Started $candidate on port $new_port"

    # Check the incoming application before switching traffic.
    if ! check_health "$new_port" "$expected_version"; then
        log "ERROR: Health check failed; removing incoming container."
        docker rm -f "$candidate"
        return 1
    fi

    # Replace the old inactive slot only after the candidate is healthy.
    if docker inspect "$inactive_slot" >/dev/null 2>&1; then
        if ! docker rm -f "$inactive_slot"; then
            log "ERROR: Could not replace the inactive slot."
            docker rm -f "$candidate"
            return 1
        fi
    fi

    if ! docker rename "$candidate" "$inactive_slot"; then
        log "ERROR: Could not promote the candidate container."
        docker rm -f "$candidate"
        return 1
    fi

    # Switch Nginx and verify traffic. The function restores the old
    # upstream if validation, reload, or verification fails.
    if ! switch_traffic "$new_port" "$expected_version"; then
        log "ERROR: Traffic switch failed; preserving the old active slot."
        docker rm -f "$inactive_slot"
        return 1
    fi

    # Save the new active slot only after traffic verification succeeds.
    if ! printf 'ACTIVE_SLOT=%s\nACTIVE_PORT=%s\n' \
        "$inactive_slot" "$new_port" > "$temp_state" ||
       ! mv "$temp_state" "$state_file"; then

        log "ERROR: Could not update deployment state. Rolling back traffic."

        local old_version
        old_version=$(printf '%s' "$active_slot" | tr '[:lower:]' '[:upper:]')

        if switch_traffic "$active_port" "$old_version"; then
            docker rm -f "$inactive_slot"
            rm -f "$temp_state"
            log "Previous active slot restored."
        else
            log "CRITICAL: State update and traffic rollback failed."
            log "Keep both containers running and investigate manually."
        fi

        return 1
    fi

    log "Deployment state updated: $inactive_slot on port $new_port"

    # Remove the previous active container only after the new deployment
    # has passed the health check and Nginx verification.
    if docker rm -f "$active_slot"; then
        log "Removed previous container: $active_slot"
    else
        log "WARNING: Previous container cleanup failed."
    fi

    log "Deployment completed successfully."
}

# DEPLOY_ENTRY_POINT
# Default to the existing GREEN image for the initial test.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    deploy_version "${DEPLOY_IMAGE:-blue-green-app:v1}" "${DEPLOY_VERSION:-GREEN}"
fi
