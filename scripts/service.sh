#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/data/harmony-ir
RUN=/tmp/harmony-ir-service
HOOK=/etc/init.d/rcS.local
BEGIN='# BEGIN HARMONY-IR MANAGED BOOT'
END='# END HARMONY-IR MANAGED BOOT'
DIR=$(dirname "$0")
umask 077

remove_empty_dir() {
    HARMONY_IR_EMPTY_DIR="$1" /usr/bin/lua -e 'assert(os.remove(os.getenv("HARMONY_IR_EMPTY_DIR")))'
}

fail() { echo "harmony-ir: $*" >&2; exit 1; }
managed() { [ -f "$ROOT/.managed" ] && [ "$(cat "$ROOT/.managed")" = harmony-ir-v1 ]; }
valid_pid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
process_matches() {
    valid_pid "$1" && [ -r "/proc/$1/cmdline" ] &&
        tr '\000' ' ' < "/proc/$1/cmdline" | grep -Fq "$2"
}
supervisor_alive() {
    [ -f "$RUN/lock/pid" ] || return 1
    SUPERVISOR=$(cat "$RUN/lock/pid")
    process_matches "$SUPERVISOR" "$ROOT/releases/" &&
        process_matches "$SUPERVISOR" '/service.sh supervise'
}
child_alive() {
    [ -f "$RUN/child.pid" ] || return 1
    CHILD=$(cat "$RUN/child.pid")
    process_matches "$CHILD" "$ROOT/releases/" &&
        process_matches "$CHILD" '/server.lua --listen '
}
load_config() {
    LISTEN=0.0.0.0
    PORT=8089
    while IFS= read -r line; do
        case "$line" in LISTEN=*) LISTEN=${line#LISTEN=} ;; PORT=*) PORT=${line#PORT=} ;; esac
    done < "$ROOT/config"
    case "$PORT" in ''|0*|*[!0-9]*) fail 'invalid configured port' ;; esac
    [ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail 'invalid configured port'
    printf '%s\n' "$LISTEN" | awk -F. 'NR!=1 || NF!=4{exit 1} {for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || length($i)>3 || $i>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1} END {if(NR!=1) exit 1}' || fail 'invalid configured IPv4 address'
}
health() {
    load_config
    HARMONY_IR_RELEASE="$DIR" HARMONY_IR_LISTEN="$LISTEN" HARMONY_IR_PORT="$PORT" /usr/bin/lua - <<'LUA'
package.path = os.getenv('HARMONY_IR_RELEASE') .. '/?.lua;' .. package.path
local client = require('client')
local socket, json, socket_error, json_error = client.modules()
assert(socket, socket_error); assert(json, json_error)
local fd = assert(socket.tcp())
local ok, err = pcall(function()
  local deadline, header_bytes = socket.gettime() + 2, 0
  local function timeout()
    local remaining = deadline - socket.gettime()
    assert(remaining > 0, 'health request timed out')
    assert(fd:settimeout(remaining, 't'))
  end
  local function receive(n)
    local parts, received = {}, 0
    while received < n do
      timeout()
      local data, why, partial = fd:receive(n - received)
      local chunk = data or partial or ''
      if #chunk > 0 then parts[#parts + 1] = chunk; received = received + #chunk end
      if received == n then return table.concat(parts) end
      assert(why == 'timeout', 'health read failed: ' .. tostring(why))
      local remaining = deadline - socket.gettime()
      assert(remaining > 0, 'health request timed out')
      local ready, _, err = socket.select({fd}, nil, remaining)
      assert(ready and #ready > 0, 'health read wait failed: ' .. tostring(err))
    end
  end
  local function line()
    local chars = {}
    while true do
      local c = receive(1)
      header_bytes = header_bytes + 1
      assert(header_bytes <= 8192, 'health headers too large')
      if c == '\n' then return (table.concat(chars):gsub('\r$', '')) end
      chars[#chars + 1] = c
    end
  end
  timeout()
  local host = os.getenv('HARMONY_IR_LISTEN')
  if host == '0.0.0.0' then host = '127.0.0.1' end
  assert(fd:connect(host, tonumber(os.getenv('HARMONY_IR_PORT'))))
  local request = 'GET /health HTTP/1.1\r\nHost: harmony-ir\r\nConnection: close\r\n\r\n'
  local pos = 1
  while pos <= #request do
    timeout()
    local sent, why = fd:send(request, pos)
    assert(sent and sent >= pos, 'health request write failed: ' .. tostring(why))
    pos = sent + 1
  end
  local status = line()
  local length, ended
  for _ = 1, 32 do
    local header = line()
    if header == '' then ended = true; break end
    local value = header:lower():match('^content%-length:%s*(%d+)%s*$')
    if value then length = tonumber(value) end
  end
  assert(ended and length and length > 0 and length <= 4096, 'invalid health body length')
  local body = receive(length)


  local value = json.decode(body)
  assert(status:match('^HTTP/1%.[01] 200 '),
    'unexpected health status: ' .. status .. '; ' .. tostring(type(value) == 'table' and value.error or body))
  assert(type(value) == 'table' and value.api_version == 1 and value.transmitter == 'harmony-hal', 'incompatible health response')
end)
fd:close()
if not ok then io.stderr:write(tostring(err) .. '\n'); os.exit(1) end
print('Harmony IR health: OK')
LUA
}
start() {
    [ -f "$ROOT/enabled" ] || fail 'disabled; use enable first'
    mkdir -p "$RUN" || fail 'cannot create runtime directory'
    [ ! -L "$RUN" ] && [ ! -L "$RUN/lock" ] || fail 'unsafe runtime directory'
    chmod 700 "$RUN" || fail 'cannot secure runtime directory'
    if supervisor_alive; then echo 'Harmony IR already supervised'; return; fi
    if [ -d "$RUN/lock" ]; then
        [ -f "$RUN/lock/pid" ] || fail 'start lock exists without PID; inspect /tmp/harmony-ir-service/lock'
        supervisor_alive && return
        rm -f "$RUN/lock/pid"
        remove_empty_dir "$RUN/lock" || fail 'cannot remove stale service lock'
    fi
    mkdir "$RUN/lock" || fail 'another start is in progress'
    (
        trap '' HUP
        exec /bin/sh "$DIR/service.sh" supervise
    ) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$RUN/lock/pid"
    echo 'Harmony IR supervisor started'
}
stop() {
    if supervisor_alive; then
        kill -TERM "$SUPERVISOR" || return 1
        n=0
        while supervisor_alive && [ "$n" -lt 8 ]; do sleep 1; n=$((n + 1)); done
        if supervisor_alive; then fail 'supervisor did not stop; inspect processes before retrying'; fi
    fi
    if child_alive; then
        kill -TERM "$CHILD" || return 1
        n=0
        while child_alive && [ "$n" -lt 3 ]; do sleep 1; n=$((n + 1)); done
        child_alive && fail 'child did not stop; inspect processes'
    fi
    rm -f "$RUN/child.pid" "$RUN/lock/pid"
    remove_empty_dir "$RUN/lock" 2>/dev/null || :
    echo 'Harmony IR stopped'
}
remove_hook() {
    [ -f "$HOOK" ] && [ ! -L "$HOOK" ] || fail 'unsupported boot hook file'
    temp=/etc/init.d/.harmony-ir-uninstall.$$
    cp -p "$HOOK" "$temp" || return 1
    awk -v begin="$BEGIN" -v end="$END" '
      $0==begin {if(skip || seen++) exit 2; skip=1; next}
      $0==end {if(!skip) exit 2; skip=0; next}
      !skip {print}
      END {if(skip) exit 2}
    ' "$HOOK" > "$temp.content" || { rm -f "$temp" "$temp.content"; return 1; }
    cat "$temp.content" > "$temp" && mv -f "$temp" "$HOOK"
    rc=$?
    rm -f "$temp" "$temp.content"
    return "$rc"
}
supervise() {
    echo "$$" > "$RUN/lock/pid"
    child=
    cleanup() {
        trap - 0 INT TERM
        if [ -n "$child" ] && process_matches "$child" "$DIR/server.lua"; then
            kill -TERM "$child" 2>/dev/null || :
            sleep 1
            if process_matches "$child" "$DIR/server.lua"; then kill -KILL "$child" 2>/dev/null || :; fi
            wait "$child" 2>/dev/null || :
        fi
        rm -f "$RUN/child.pid"
        if [ "$(cat "$RUN/lock/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$RUN/lock/pid"
            remove_empty_dir "$RUN/lock" 2>/dev/null || :
        fi
    }
    trap cleanup 0
    trap 'exit 0' INT TERM
    delay=2
    while [ -f "$ROOT/enabled" ]; do
        if ! awk '$4=="0A" && $2~/:414C$/ {found=1} END {exit !found}' /proc/net/tcp; then
            sleep 2
            continue
        fi
        load_config
        started=$(date +%s)
        echo "$(date) starting IR bridge" >> "$RUN/bridge.log"
        /usr/bin/lua "$DIR/server.lua" --listen "$LISTEN" --port "$PORT" >> "$RUN/bridge.log" 2>&1 &
        child=$!
        echo "$child" > "$RUN/child.pid"
        sleep 1
        tick=0
        while process_matches "$child" "$DIR/server.lua" && [ -f "$ROOT/enabled" ]; do
            sleep 2
            tick=$((tick + 1))
            if [ "$tick" -ge 15 ]; then
                size=$(ls -ln "$RUN/bridge.log" | awk '{print $5}')
                case "$size" in ''|*[!0-9]*) size=0 ;; esac
                if [ "$size" -gt 65536 ]; then
                    cp "$RUN/bridge.log" "$RUN/bridge.log.1" && : > "$RUN/bridge.log"
                fi
                tick=0
            fi
        done
        [ -f "$ROOT/enabled" ] || exit 0
        wait "$child" 2>/dev/null || :
        child=
        rm -f "$RUN/child.pid"
        now=$(date +%s)
        if [ "$((now - started))" -ge 60 ]; then delay=2; fi
        echo "$(date) bridge exited; retrying in ${delay}s" >> "$RUN/bridge.log"
        pause=0
        while [ "$pause" -lt "$delay" ] && [ -f "$ROOT/enabled" ]; do
            sleep 1
            pause=$((pause + 1))
        done
        delay=$((delay * 2))
        [ "$delay" -le 30 ] || delay=30
    done
}

managed || fail 'no managed installation found'
case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop && start ;;
    status)
        if supervisor_alive; then
            if child_alive; then echo "Harmony IR supervised (PID $SUPERVISOR), bridge PID $CHILD"
            else echo "Harmony IR supervised (PID $SUPERVISOR), waiting/restarting"; fi
        else echo 'Harmony IR not running'; exit 1; fi ;;
    check) health ;;
    enable) touch "$ROOT/enabled" && start ;;
    disable) rm -f "$ROOT/enabled"; stop ;;
    uninstall)
        [ "$(id -u)" = 0 ] || fail 'root required'
        rm -f "$ROOT/enabled"
        stop && remove_hook || fail 'uninstall incomplete; files preserved'
        echo 'Autostart removed. Installation and backup retained under /data/harmony-ir.' ;;
    supervise) supervise ;;
    *) fail 'usage: service {start|stop|restart|status|check|enable|disable|uninstall}' ;;
esac
