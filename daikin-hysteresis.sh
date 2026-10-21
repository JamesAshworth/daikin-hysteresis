#!/usr/bin/env bash
# Keeps a Daikin (Onecta cloud) unit cooling above TARGET, fan-only below it,
# and back to cooling once the room exceeds TARGET + MARGIN.
#
# Usage:
#   daikin-hysteresis.sh auth     one-time OAuth sign-in, stores refresh token
#   daikin-hysteresis.sh status   print current mode/temperature (1 API call)
#   daikin-hysteresis.sh run      control loop (for systemd)
#
# Installation (Debian/Ubuntu/Raspberry Pi OS):
#
#   1. Register an app at https://developer.cloud.daikineurope.com using the
#      same email as your Onecta account. Daikin allows one app per account.
#      Redirect URI must not contain "localhost" (the portal returns 403) -
#      a LAN address such as https://192.168.0.10:8443/daikin works. Nothing
#      needs to listen there.
#
#   2. Install dependencies and files:
#        sudo apt install -y jq curl
#        mkdir -p ~/bin ~/.config/daikin ~/.config/systemd/user
#        cp daikin-hysteresis.sh ~/bin/ && chmod +x ~/bin/daikin-hysteresis.sh
#        cp config.example ~/.config/daikin/config && chmod 600 ~/.config/daikin/config
#        cp daikin-hysteresis.service ~/.config/systemd/user/
#
#   3. Edit ~/.config/daikin/config - CLIENT_ID, CLIENT_SECRET, REDIRECT_URI
#      (exactly as registered), TARGET, and the active hours.
#
#   4. Sign in once:
#        ~/bin/daikin-hysteresis.sh auth
#      Open the printed URL, sign in, then paste the URL the browser fails to
#      load (it contains code=...). The code expires within minutes.
#
#   5. Check the unit is visible:
#        ~/bin/daikin-hysteresis.sh status
#
#   6. Run as a user service that survives logout and reboot:
#        systemctl --user daemon-reload
#        systemctl --user enable --now daikin-hysteresis
#        sudo loginctl enable-linger "$USER"
#        journalctl --user -u daikin-hysteresis -f
#      The journalctl window only follows the log - closing it, or logging
#      out, does not stop the service.
#
# Managing the service:
#   systemctl --user status daikin-hysteresis                running? last few log lines
#   journalctl --user -u daikin-hysteresis -n 50             last 50 lines, then exit
#   journalctl --user -u daikin-hysteresis --since "22:00"   tonight's activity
#   systemctl --user restart daikin-hysteresis               after editing the config
#   systemctl --user stop daikin-hysteresis                  stop it
#   loginctl show-user "$USER" -p Linger                     should print Linger=yes
#
#   Tokens live in ~/.local/state/daikin (mode 700). If the refresh token is
#   ever rejected, rerun step 4. Onecta allows 200 API calls per day.

set -euo pipefail

CONFIG_FILE="${DAIKIN_CONFIG:-$HOME/.config/daikin/config}"
STATE_DIR="${DAIKIN_STATE_DIR:-$HOME/.local/state/daikin}"

IDP="https://idp.onecta.daikineurope.com/v1/oidc"
API="https://api.onecta.daikineurope.com/v1"
SCOPE="openid onecta:basic.integration"

# Defaults, overridable in the config file
TARGET=23.0
MARGIN=1.0
SETPOINT_OFFSET=1.0
POLL_SECONDS=300
LOW_BUDGET_POLL_SECONDS=1800
LOW_BUDGET_CALLS=20
ACTIVE_START=22
ACTIVE_END=10
MIN_DWELL_SECONDS=600
DEVICE_ID=""

# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
: "${CLIENT_ID:?CLIENT_ID missing from $CONFIG_FILE}"
: "${CLIENT_SECRET:?CLIENT_SECRET missing from $CONFIG_FILE}"
: "${REDIRECT_URI:?REDIRECT_URI missing from $CONFIG_FILE}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
REFRESH_FILE="$STATE_DIR/refresh_token"
ACCESS_FILE="$STATE_DIR/access_token"
EXPIRY_FILE="$STATE_DIR/access_expiry"
LAST_SWITCH_FILE="$STATE_DIR/last_switch"
HEADERS_FILE="$STATE_DIR/last_headers"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

save_tokens() {
    local response="$1" access refresh expires_in
    access=$(jq -r '.access_token // empty' <<<"$response")
    refresh=$(jq -r '.refresh_token // empty' <<<"$response")
    expires_in=$(jq -r '.expires_in // 3600' <<<"$response")
    if [[ -z "$access" ]]; then
        log "Token request failed: $(jq -c 'del(.access_token, .refresh_token, .id_token)' <<<"$response" 2>/dev/null || echo "$response")"
        return 1
    fi
    umask 077
    printf '%s' "$access" >"$ACCESS_FILE"
    # Daikin rotates refresh tokens, so the new one must replace the old
    [[ -n "$refresh" ]] && printf '%s' "$refresh" >"$REFRESH_FILE"
    echo $(( $(date +%s) + expires_in - 60 )) >"$EXPIRY_FILE"
}

cmd_auth() {
    local state url redirected code response
    state=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    url="$IDP/authorize?response_type=code&client_id=$(urlencode "$CLIENT_ID")&redirect_uri=$(urlencode "$REDIRECT_URI")&scope=$(urlencode "$SCOPE")&state=$state"
    echo "1. Open this URL in a browser and sign in with your Daikin account:"
    echo
    echo "   $url"
    echo
    echo "2. You will be redirected to $REDIRECT_URI (the page may fail to load - that is fine)."
    read -r -p "3. Paste the full URL from the address bar here: " redirected
    code=$(sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' <<<"$redirected")
    [[ -n "$code" ]] || { echo "No code= found in that URL" >&2; exit 1; }
    [[ "$redirected" == *"state=$state"* ]] || { echo "State mismatch - start again" >&2; exit 1; }
    response=$(curl -sS -X POST "$IDP/token" \
        --data-urlencode grant_type=authorization_code \
        --data-urlencode "code=$code" \
        --data-urlencode "client_id=$CLIENT_ID" \
        --data-urlencode "client_secret=$CLIENT_SECRET" \
        --data-urlencode "redirect_uri=$REDIRECT_URI")
    save_tokens "$response"
    echo "Signed in. Tokens stored in $STATE_DIR"
}

ensure_token() {
    local now expiry response
    now=$(date +%s)
    expiry=$(cat "$EXPIRY_FILE" 2>/dev/null || echo 0)
    if [[ -s "$ACCESS_FILE" && "$now" -lt "$expiry" ]]; then
        return 0
    fi
    [[ -s "$REFRESH_FILE" ]] || { log "No refresh token - run '$0 auth' first"; return 1; }
    response=$(curl -sS -X POST "$IDP/token" \
        --data-urlencode grant_type=refresh_token \
        --data-urlencode "refresh_token=$(cat "$REFRESH_FILE")" \
        --data-urlencode "client_id=$CLIENT_ID" \
        --data-urlencode "client_secret=$CLIENT_SECRET")
    save_tokens "$response"
}

# api METHOD PATH [JSON_BODY] - sets API_BODY and HTTP_STATUS
api() {
    local method="$1" path="$2" body="${3:-}" out
    local args=(-sS -X "$method" -D "$HEADERS_FILE" -w '\n%{http_code}'
        -H "Authorization: Bearer $(cat "$ACCESS_FILE")"
        -H "Accept: application/json")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")
    out=$(curl "${args[@]}" "$API$path") || { HTTP_STATUS=000; API_BODY=""; return 1; }
    HTTP_STATUS="${out##*$'\n'}"
    API_BODY="${out%$'\n'*}"
}

header_value() {
    grep -i "^$1:" "$HEADERS_FILE" 2>/dev/null | tail -1 | cut -d: -f2- | tr -d ' \r'
}

# Sets DEVICE, EMBEDDED_ID, ONOFF, MODE, ROOM_TEMP, COOL_SETPOINT
read_device() {
    api GET /gateway-devices || true
    [[ "$HTTP_STATUS" == 200 ]] || { log "GET devices failed: HTTP $HTTP_STATUS"; return 1; }
    local parsed
    parsed=$(jq -r --arg id "$DEVICE_ID" '
        [ .[] | select($id == "" or .id == $id)
          | . as $d
          | .managementPoints[]
          | select(.managementPointType == "climateControl")
          | [ $d.id, .embeddedId, .onOffMode.value, .operationMode.value,
              (.sensoryData.value.roomTemperature.value // "null"),
              (.temperatureControl.value.operationModes.cooling.setpoints.roomTemperature.value // "null") ] ]
        | first // empty | @tsv' <<<"$API_BODY")
    [[ -n "$parsed" ]] || { log "No climateControl device found"; return 1; }
    IFS=$'\t' read -r DEVICE EMBEDDED_ID ONOFF MODE ROOM_TEMP COOL_SETPOINT <<<"$parsed"
}

set_characteristic() {
    local name="$1" body="$2"
    api PATCH "/gateway-devices/$DEVICE/management-points/$EMBEDDED_ID/characteristics/$name" "$body" || true
    if [[ "$HTTP_STATUS" != 204 && "$HTTP_STATUS" != 200 ]]; then
        log "PATCH $name failed: HTTP $HTTP_STATUS $API_BODY"
        return 1
    fi
}

switch_to() {
    local mode="$1"
    if [[ "$mode" == cooling ]]; then
        local setpoint
        setpoint=$(awk -v t="$TARGET" -v o="$SETPOINT_OFFSET" 'BEGIN { printf "%.1f", t - o }')
        # Set while still in fan mode so no command lands mid-way through the cooling start-up
        if ! float_eq "$COOL_SETPOINT" "$setpoint"; then
            log "Cooling setpoint $COOL_SETPOINT -> $setpoint"
            set_characteristic temperatureControl \
                "$(jq -cn --argjson v "$setpoint" '{value: $v, path: "/operationModes/cooling/setpoints/roomTemperature"}')"
        fi
    fi
    set_characteristic operationMode "$(jq -cn --arg m "$mode" '{value: $m}')"
    date +%s >"$LAST_SWITCH_FILE"
}

float_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
float_eq() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; exit !(a != "null" && d < 0.05 && d > -0.05) }'; }
float_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

in_active_window() {
    local hour
    hour=$((10#$(date +%H)))
    if (( ACTIVE_START > ACTIVE_END )); then
        (( hour >= ACTIVE_START || hour < ACTIVE_END ))
    else
        (( hour >= ACTIVE_START && hour < ACTIVE_END ))
    fi
}

seconds_until_active() {
    local now start
    now=$(date +%s)
    start=$(date -d "today ${ACTIVE_START}:00" +%s)
    (( start > now )) || start=$(( start + 86400 ))
    echo $(( start - now ))
}

poll_interval() {
    local remaining
    remaining=$(header_value x-ratelimit-remaining-day)
    if [[ -n "$remaining" ]] && (( remaining < LOW_BUDGET_CALLS )); then
        echo "$LOW_BUDGET_POLL_SECONDS"
    else
        echo "$POLL_SECONDS"
    fi
}

dwell_remaining() {
    local last now left
    now=$(date +%s)
    last=$(cat "$LAST_SWITCH_FILE" 2>/dev/null || echo 0)
    left=$(( last + MIN_DWELL_SECONDS - now ))
    echo $(( left > 0 ? left : 0 ))
}

control_once() {
    ensure_token
    read_device
    local remaining
    remaining=$(header_value x-ratelimit-remaining-day)
    log "mode=$MODE power=$ONOFF room=$ROOM_TEMP target=$TARGET calls_left_today=${remaining:-?}"

    [[ "$ONOFF" == on ]] || return 0
    [[ "$ROOM_TEMP" != null ]] || { log "No room temperature reported"; return 0; }

    local upper
    upper=$(awk -v t="$TARGET" -v m="$MARGIN" 'BEGIN { print t + m }')
    if [[ "$MODE" == cooling ]] && float_le "$ROOM_TEMP" "$TARGET"; then
        log "Room $ROOM_TEMP <= $TARGET - switching to fan"
        switch_to fanOnly
    elif [[ "$MODE" == fanOnly ]] && float_ge "$ROOM_TEMP" "$upper"; then
        log "Room $ROOM_TEMP >= $upper - switching to cooling"
        switch_to cooling
    fi
}

cmd_run() {
    log "Starting: target=$TARGET margin=$MARGIN poll=${POLL_SECONDS}s active=${ACTIVE_START}:00-${ACTIVE_END}:00"
    local was_active=unknown
    while true; do
        local sleep_for
        if ! in_active_window; then
            [[ "$was_active" == false ]] || log "Outside active hours - idle until ${ACTIVE_START}:00"
            was_active=false
            sleep_for=$(seconds_until_active)
            # Re-check hourly so clock changes cannot strand the loop
            sleep $(( sleep_for < 3600 ? sleep_for : 3600 ))
            continue
        fi
        [[ "$was_active" == true ]] || log "Active hours - controlling"
        was_active=true
        sleep_for=$(dwell_remaining)
        if (( sleep_for > 0 )); then
            sleep "$sleep_for"
            continue
        fi
        if ! control_once; then
            log "Cycle failed - will retry"
        fi
        sleep_for=$(poll_interval)
        if [[ "${HTTP_STATUS:-}" == 429 ]]; then
            local retry
            retry=$(header_value retry-after)
            sleep_for=$(( ${retry:-3600} > sleep_for ? ${retry:-3600} : sleep_for ))
            log "Rate limited - sleeping ${sleep_for}s"
        fi
        sleep "$sleep_for"
    done
}

cmd_status() {
    ensure_token
    read_device
    echo "device=$DEVICE point=$EMBEDDED_ID power=$ONOFF mode=$MODE room=$ROOM_TEMP"
    echo "calls left today: $(header_value x-ratelimit-remaining-day)"
}

case "${1:-}" in
    auth) cmd_auth ;;
    run) cmd_run ;;
    status) cmd_status ;;
    *) echo "Usage: $0 {auth|status|run}" >&2; exit 2 ;;
esac
