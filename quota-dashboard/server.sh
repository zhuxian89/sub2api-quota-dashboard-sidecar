#!/bin/sh
set -eu

PORT="${PORT:-8081}"
SNAPSHOT_INTERVAL_SECONDS="${SNAPSHOT_INTERVAL_SECONDS:-3600}"
SUB2API_BASE_URL="${SUB2API_BASE_URL:?SUB2API_BASE_URL is required}"
QUOTA_DASHBOARD_MENU_ID="${QUOTA_DASHBOARD_MENU_ID:-account-quota-dashboard}"
QUOTA_DASHBOARD_MENU_LABEL="${QUOTA_DASHBOARD_MENU_LABEL:-账号额度统计}"
QUOTA_DASHBOARD_MENU_VISIBILITY="${QUOTA_DASHBOARD_MENU_VISIBILITY:-admin}"
if [ "${QUOTA_DASHBOARD_MENU_ICON_SVG+x}" != "x" ]; then
    QUOTA_DASHBOARD_MENU_ICON_SVG='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.75 19.25h14.5"/><path d="M7.25 15.5V11"/><path d="M12 15.5V8.25"/><path d="M16.75 15.5v-3.25"/><path d="M6.75 8.25 10.25 6l2.75 1.5 4.25-3"/></svg>'
fi
USAGE_REFRESH_INTERVAL_SECONDS="${USAGE_REFRESH_INTERVAL_SECONDS:-3600}"
USAGE_REFRESH_BATCH_SIZE="${USAGE_REFRESH_BATCH_SIZE:-1000}"
USAGE_REFRESH_TIMEOUT_SECONDS="${USAGE_REFRESH_TIMEOUT_SECONDS:-15}"
USAGE_REFRESH_TOKEN_FILE="${USAGE_REFRESH_TOKEN_FILE:-/tmp/quota-dashboard-admin-token}"
USAGE_REFRESH_LOCK_DIR="${USAGE_REFRESH_LOCK_DIR:-/tmp/quota-dashboard-usage-refresh.lock}"
SUB2API_ADMIN_API_KEY="${SUB2API_ADMIN_API_KEY:-}"
SUB2API_ADMIN_EMAIL="${SUB2API_ADMIN_EMAIL:-}"
SUB2API_ADMIN_PASSWORD="${SUB2API_ADMIN_PASSWORD:-}"
SUB2API_ADMIN_API_KEY="${SUB2API_ADMIN_API_KEY:-}"

AUTHORIZED_ADMIN_CREDENTIAL=""

export PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

psql_base() {
    psql \
        -h "${POSTGRES_HOST:-postgres}" \
        -p "${POSTGRES_PORT:-5432}" \
        -U "${POSTGRES_USER:-sub2api}" \
        -d "${POSTGRES_DB:-sub2api}" \
        "$@"
}

send_response() {
    status="$1"
    content_type="$2"
    body="$3"
    content_length="$(printf '%s' "$body" | wc -c | tr -d ' ')"
    printf 'HTTP/1.1 %s\r\n' "$status"
    printf 'Content-Type: %s\r\n' "$content_type"
    printf 'Content-Length: %s\r\n' "$content_length"
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s' "$body"
}

query_param() {
    name="$1"
    query="$2"
    printf '%s' "$query" | tr '&' '\n' | awk -F= -v key="$name" '$1 == key { print $2; exit }'
}

trim_spaces() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_first_present_query_param() {
    query="$1"
    shift
    for key in "$@"; do
        value="$(query_param "$key" "$query")"
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

make_admin_api_key_credential() {
    printf 'api_key:%s' "$1"
}

make_admin_token_credential() {
    printf 'token:%s' "$1"
}

admin_credential_kind() {
    credential="$1"
    case "$credential" in
        api_key:*)
            printf 'api_key'
            ;;
        token:*)
            printf 'token'
            ;;
        *)
            printf 'token'
            ;;
    esac
}

admin_credential_value() {
    credential="$1"
    case "$credential" in
        api_key:*|token:*)
            printf '%s' "${credential#*:}"
            ;;
        *)
            printf '%s' "$credential"
            ;;
    esac
}

admin_auth_header() {
    credential="$1"
    kind="$(admin_credential_kind "$credential")"
    value="$(admin_credential_value "$credential")"
    [ -n "$value" ] || return 1

    case "$kind" in
        api_key)
            printf 'x-api-key: %s' "$value"
            ;;
        token)
            printf 'Authorization: Bearer %s' "$value"
            ;;
        *)
            return 1
            ;;
    esac
}

is_admin_credential() {
    credential="$1"
    header="$(admin_auth_header "$credential")" || return 1
    wget -q -T 5 --tries=1 -O /dev/null \
        --header="$header" \
        "${SUB2API_BASE_URL%/}/api/v1/admin/users?page_size=1"
}

is_admin_api_key() {
    api_key="$1"
    [ -n "$api_key" ] || return 1
    is_admin_credential "$(make_admin_api_key_credential "$api_key")"
}

is_admin_token() {
    token="$1"
    [ -n "$token" ] || return 1
    is_admin_credential "$(make_admin_token_credential "$token")"
}

is_admin_api_key() {
    api_key="$1"
    [ -n "$api_key" ] || return 1
    wget -q -T 5 --tries=1 -O /dev/null \
        --header="x-api-key: $api_key" \
        "${SUB2API_BASE_URL%/}/api/v1/admin/accounts?page=1&page_size=1&timezone=Asia%2FShanghai"
}

login_admin_token() {
    [ -n "$SUB2API_ADMIN_EMAIL" ] || return 1
    [ -n "$SUB2API_ADMIN_PASSWORD" ] || return 1

    body="$(printf '{"email":"%s","password":"%s"}' "$SUB2API_ADMIN_EMAIL" "$SUB2API_ADMIN_PASSWORD")"
    response="$(wget -q -T 10 --tries=1 -O - \
        --header='Content-Type: application/json' \
        --post-data="$body" \
        "${SUB2API_BASE_URL%/}/api/v1/auth/login")" || return 1

    token="$(printf '%s' "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$token" ] || return 1
    credential="$(make_admin_token_credential "$token")"
    save_admin_credential "$credential"
    printf '%s' "$credential"
}

extract_bearer_token() {
    authorization_header="$(trim_spaces "${1:-}")"
    token="$(printf '%s' "$authorization_header" | sed -n 's/^[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]\{1,\}//p')"
    [ -n "$token" ] || return 1
    printf '%s' "$token"
}

is_authorized() {
    query="$1"
    authorization_header="${2:-}"
    x_api_key_header="${3:-}"
    x_admin_api_header="${4:-}"
    AUTHORIZED_ADMIN_CREDENTIAL=""

    admin_api_key="$(trim_spaces "$x_api_key_header")"
    if [ -z "$admin_api_key" ]; then
        admin_api_key="$(trim_spaces "$x_admin_api_header")"
    fi
    if [ -n "$admin_api_key" ] && is_admin_api_key "$admin_api_key"; then
        AUTHORIZED_ADMIN_CREDENTIAL="$(make_admin_api_key_credential "$admin_api_key")"
        return 0
    fi

    token="$(extract_bearer_token "$authorization_header" 2>/dev/null || true)"
    if [ -n "$token" ] && is_admin_token "$token"; then
        AUTHORIZED_ADMIN_CREDENTIAL="$(make_admin_token_credential "$token")"
        return 0
    fi

    admin_api_key="$(read_first_present_query_param "$query" admin_api_key x_admin_api x-admin-api admin_api x-api-key 2>/dev/null || true)"
    if [ -n "$admin_api_key" ] && is_admin_api_key "$admin_api_key"; then
        AUTHORIZED_ADMIN_CREDENTIAL="$(make_admin_api_key_credential "$admin_api_key")"
        return 0
    fi

    token="$(query_param token "$query")"
    if [ -n "$token" ] && is_admin_token "$token"; then
        AUTHORIZED_ADMIN_CREDENTIAL="$(make_admin_token_credential "$token")"
        return 0
    fi

    secret="$(query_param secret "$query")"
    if [ -n "${DASHBOARD_TOKEN:-}" ] && [ "$secret" = "$DASHBOARD_TOKEN" ]; then
        return 0
    fi
    return 1
}

sync_custom_menu() {
    [ -n "${QUOTA_DASHBOARD_PUBLIC_URL:-}" ] || return 0

    psql_base \
        -v ON_ERROR_STOP=1 \
        -v menu_id="$QUOTA_DASHBOARD_MENU_ID" \
        -v menu_label="$QUOTA_DASHBOARD_MENU_LABEL" \
        -v menu_url="$QUOTA_DASHBOARD_PUBLIC_URL" \
        -v menu_visibility="$QUOTA_DASHBOARD_MENU_VISIBILITY" \
        -v menu_icon_svg="${QUOTA_DASHBOARD_MENU_ICON_SVG:-}" \
        -f /app/sync_menu.sql >/dev/null
}

save_admin_credential() {
    credential="$1"
    [ -n "$credential" ] || return 0

    umask 077
    tmp_file="${USAGE_REFRESH_TOKEN_FILE}.tmp"
    printf '%s' "$credential" > "$tmp_file"
    mv "$tmp_file" "$USAGE_REFRESH_TOKEN_FILE"
}

load_admin_credential() {
    [ -f "$USAGE_REFRESH_TOKEN_FILE" ] || return 1
    tr -d '\r\n' < "$USAGE_REFRESH_TOKEN_FILE"
}

fetch_usage_account_ids() {
    psql_base \
        -qAtX \
        -v ON_ERROR_STOP=1 \
        -v batch_size="$USAGE_REFRESH_BATCH_SIZE" \
        -f /app/refresh_usage_accounts.sql
}

record_refresh_state() {
    account_id="$1"
    refresh_status="$2"
    refresh_error="${3:-}"
    usage_updated_at="${4:-}"
    five_hour_success="${5:-f}"
    seven_day_success="${6:-f}"
    primary_success="${7:-f}"
    secondary_success="${8:-f}"

    psql_base \
        -qAtX \
        -v ON_ERROR_STOP=1 \
        -v account_id="$account_id" \
        -v refresh_status="$refresh_status" \
        -v refresh_error="$refresh_error" \
        -v usage_updated_at="$usage_updated_at" \
        -v five_hour_success="$five_hour_success" \
        -v seven_day_success="$seven_day_success" \
        -v primary_success="$primary_success" \
        -v secondary_success="$secondary_success" \
        -f /app/record_usage_refresh.sql >/dev/null
}

refresh_account_usage() {
    account_id="$1"
<<<<<<< HEAD
    credential="$2"
    header="$(admin_auth_header "$credential")" || return 1
    if body="$(wget -q -T "$USAGE_REFRESH_TIMEOUT_SECONDS" --tries=1 -O - \
        --header="$header" \
        "${SUB2API_BASE_URL%/}/api/v1/admin/accounts/${account_id}/usage")"; then
=======
    auth_value="$2"
    auth_mode="${3:-token}"
    if [ "$auth_mode" = "api_key" ]; then
        auth_header="x-api-key: $auth_value"
    else
        auth_header="Authorization: Bearer $auth_value"
    fi
    if body="$(wget -q -T "$USAGE_REFRESH_TIMEOUT_SECONDS" --tries=1 -O - \
        --header="$auth_header" \
        "${SUB2API_BASE_URL%/}/api/v1/admin/accounts/${account_id}/usage?source=active&timezone=Asia%2FShanghai")"; then
>>>>>>> 822107c (feat: improve embedded quota dashboard deployment and refresh auth)
        body_b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
        if psql_base \
            -qAtX \
            -v ON_ERROR_STOP=1 \
            -v account_id="$account_id" \
            -v body_b64="$body_b64" \
            -f /app/persist_usage_response.sql >/dev/null; then
            return 0
        fi
        record_refresh_state "$account_id" "failed" "persist_usage_response_failed"
        return 1
    else
        record_refresh_state "$account_id" "failed" "usage_request_failed"
        return 1
    fi
}

resolve_admin_credential() {
    preferred="${1:-}"

    if [ -n "$preferred" ] && is_admin_credential "$preferred"; then
        printf '%s' "$preferred"
        return 0
    fi

    if [ -n "$SUB2API_ADMIN_API_KEY" ]; then
        credential="$(make_admin_api_key_credential "$SUB2API_ADMIN_API_KEY")"
        if is_admin_credential "$credential"; then
            printf '%s' "$credential"
            return 0
        fi
    fi

    credential="$(load_admin_credential 2>/dev/null || true)"
    if [ -n "$credential" ] && is_admin_credential "$credential"; then
        printf '%s' "$credential"
        return 0
    fi
    rm -f "$USAGE_REFRESH_TOKEN_FILE"

    credential="$(login_admin_token 2>/dev/null || true)"
    if [ -n "$credential" ] && is_admin_credential "$credential"; then
        printf '%s' "$credential"
        return 0
    fi

    return 1
}

run_usage_refresh() {
    source="${1:-scheduled}"
<<<<<<< HEAD
    credential="$(resolve_admin_credential "${2:-}" 2>/dev/null || true)"
    if [ -z "$credential" ]; then
        printf '[quota-dashboard] usage refresh skip source=%s reason=no_admin_token\n' "$source" >&2
        return 0
    fi

    save_admin_credential "$credential"
=======
    token="${2:-}"
    auth_mode="token"

    if [ -n "$SUB2API_ADMIN_API_KEY" ] && is_admin_api_key "$SUB2API_ADMIN_API_KEY"; then
        token="$SUB2API_ADMIN_API_KEY"
        auth_mode="api_key"
    else
        if [ -z "$token" ]; then
            token="$(load_admin_token 2>/dev/null || true)"
        fi
        if [ -z "$token" ]; then
            token="$(login_admin_token 2>/dev/null || true)"
        fi

        if [ -z "$token" ]; then
            printf '[quota-dashboard] usage refresh skip source=%s reason=no_admin_token\n' "$source" >&2
            return 0
        fi

        if ! is_admin_token "$token"; then
            rm -f "$USAGE_REFRESH_TOKEN_FILE"
            token="$(login_admin_token 2>/dev/null || true)"
            if [ -z "$token" ] || ! is_admin_token "$token"; then
                printf '[quota-dashboard] usage refresh skip source=%s reason=admin_token_invalid\n' "$source" >&2
                rm -f "$USAGE_REFRESH_TOKEN_FILE"
                return 0
            fi
        fi
    fi
>>>>>>> 822107c (feat: improve embedded quota dashboard deployment and refresh auth)

    ids="$(fetch_usage_account_ids)"
    total="$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [ "$total" = "0" ]; then
        printf '[quota-dashboard] usage refresh skip source=%s reason=no_accounts\n' "$source" >&2
        return 0
    fi

    ok=0
    fail=0
    printf '[quota-dashboard] usage refresh start source=%s total=%s\n' "$source" "$total" >&2

    for account_id in $ids; do
<<<<<<< HEAD
        if refresh_account_usage "$account_id" "$credential"; then
=======
        if refresh_account_usage "$account_id" "$token" "$auth_mode"; then
>>>>>>> 822107c (feat: improve embedded quota dashboard deployment and refresh auth)
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            printf '[quota-dashboard] usage refresh account_failed source=%s account_id=%s\n' "$source" "$account_id" >&2
        fi
    done

    printf '[quota-dashboard] usage refresh done source=%s ok=%s fail=%s\n' "$source" "$ok" "$fail" >&2
}

start_usage_refresh_async() {
    source="${1:-scheduled}"
    credential="${2:-}"

    if mkdir "$USAGE_REFRESH_LOCK_DIR" 2>/dev/null; then
        (
            trap 'rmdir "$USAGE_REFRESH_LOCK_DIR"' EXIT HUP INT TERM
            run_usage_refresh "$source" "$credential"
        ) &
    else
        printf '[quota-dashboard] usage refresh skip source=%s reason=busy\n' "$source" >&2
    fi
}

serve_quota_payload() {
    if body="$(psql_base -qAtX -v ON_ERROR_STOP=1 -f /app/query.sql 2>&1)"; then
        printf '[quota-dashboard] quotas ok bytes=%s\n' "$(printf '%s' "$body" | wc -c | tr -d ' ')" >&2
        send_response "200 OK" "application/json; charset=utf-8" "$body"
    else
        escaped="$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '[quota-dashboard] quotas error\n' >&2
        send_response "500 Internal Server Error" "application/json; charset=utf-8" "{\"error\":\"query_failed\",\"detail\":\"$escaped\"}"
    fi
}

handle_request() {
    IFS= read -r request_line || exit 0
    cr="$(printf '\r')"
    authorization_header=""
    x_api_key_header=""
    x_admin_api_header=""

    while IFS= read -r header_line; do
        [ "$header_line" = "$cr" ] && break
        [ -z "$header_line" ] && break
        clean_header="${header_line%$cr}"
        header_name="$(printf '%s' "$clean_header" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
        header_value="$(trim_spaces "${clean_header#*:}")"
        case "$header_name" in
            authorization)
                authorization_header="$header_value"
                ;;
            x-api-key)
                x_api_key_header="$header_value"
                ;;
            x-admin-api)
                x_admin_api_header="$header_value"
                ;;
        esac
    done

    method="$(printf '%s' "$request_line" | awk '{print $1}')"
    target="$(printf '%s' "$request_line" | awk '{print $2}')"
    path="${target%%\?*}"
    query=""
    [ "$target" != "$path" ] && query="${target#*\?}"

    if [ "$path" = "/health" ]; then
        send_response "200 OK" "text/plain; charset=utf-8" "ok"
        exit 0
    fi

    if [ "$method" != "GET" ]; then
        send_response "405 Method Not Allowed" "application/json; charset=utf-8" '{"error":"method_not_allowed"}'
        exit 0
    fi

    case "$path" in
        "/"|"/index.html")
            send_response "200 OK" "text/html; charset=utf-8" "$(cat /app/index.html)"
            ;;
        "/beacon")
            stage="$(query_param stage "$query")"
            detail="$(query_param detail "$query")"
            printf '[quota-dashboard] beacon stage=%s detail=%s\n' "$stage" "$detail" >&2
            send_response "204 No Content" "text/plain; charset=utf-8" ""
            ;;
        "/api/quotas")
            printf '[quota-dashboard] quotas start\n' >&2
            if ! is_authorized "$query" "$authorization_header" "$x_api_key_header" "$x_admin_api_header"; then
                send_response "403 Forbidden" "application/json; charset=utf-8" '{"error":"forbidden"}'
                exit 0
            fi
            if [ -n "$AUTHORIZED_ADMIN_CREDENTIAL" ]; then
                save_admin_credential "$AUTHORIZED_ADMIN_CREDENTIAL"
            fi
            serve_quota_payload
            ;;
        "/api/quotas/refresh")
            printf '[quota-dashboard] quotas refresh start\n' >&2
            if ! is_authorized "$query" "$authorization_header" "$x_api_key_header" "$x_admin_api_header"; then
                send_response "403 Forbidden" "application/json; charset=utf-8" '{"error":"forbidden"}'
                exit 0
            fi
            if [ -n "$AUTHORIZED_ADMIN_CREDENTIAL" ]; then
                save_admin_credential "$AUTHORIZED_ADMIN_CREDENTIAL"
                run_usage_refresh "manual" "$AUTHORIZED_ADMIN_CREDENTIAL"
            else
                run_usage_refresh "manual"
            fi
            serve_quota_payload
            ;;
        *)
            send_response "404 Not Found" "application/json; charset=utf-8" '{"error":"not_found"}'
            ;;
    esac
}

start_server() {
    psql_base -v ON_ERROR_STOP=1 -f /app/init.sql >/dev/null
    sync_custom_menu

    while :; do
        psql_base -qAtX -v ON_ERROR_STOP=1 -f /app/query.sql >/dev/null 2>&1 || true
        sleep "$SNAPSHOT_INTERVAL_SECONDS"
    done &

    while :; do
        start_usage_refresh_async "scheduled"
        sleep "$USAGE_REFRESH_INTERVAL_SECONDS"
    done &

    exec nc -lk -p "$PORT" -e /app/server.sh handle
}

case "${1:-server}" in
    handle)
        handle_request
        ;;
    server)
        start_server
        ;;
    *)
        echo "unknown command: $1" >&2
        exit 2
        ;;
esac
