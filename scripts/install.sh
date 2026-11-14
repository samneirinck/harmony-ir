#!/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=/data/harmony-ir
HOOK=/etc/init.d/rcS.local
LOCK=/data/.harmony-ir-install.lock
BEGIN='# BEGIN HARMONY-IR MANAGED BOOT'
END='# END HARMONY-IR MANAGED BOOT'
RELEASE_ID='@RELEASE_ID@'
umask 077

remove_empty_dir() {
    HARMONY_IR_EMPTY_DIR="$1" /usr/bin/lua -e 'assert(os.remove(os.getenv("HARMONY_IR_EMPTY_DIR")))'
}

fail() { echo "harmony-ir install: $*" >&2; exit 1; }
help() {
    echo 'Harmony IR 0.1.0 installer (root, stock firmware 4.15.600)'
    echo 'Device-side arguments: [--listen IPv4] [--port PORT]'
    echo 'From your computer use: python3 install.py --host HUB_IP'
    echo 'Default: listen on 0.0.0.0:8089 (unauthenticated trusted-LAN HTTP).'
    echo 'Existing managed settings are preserved unless options override them.'
    echo 'Installs under /data/harmony-ir; adds only a marked rcS.local block.'
    echo 'Normal reboots are supported; factory reset/firmware replacement are not.'
}
port_in_use() {
    hex=$(printf '%04X' "$PORT")
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] || continue
        if awk -v port=":$hex" '$4=="0A" && $2~(port "$") {found=1} END {exit !found}' "$table"; then
            return 0
        fi
    done
    return 1
}
restore_file() {
    name=$1
    if [ -f "$WORK/old-$name" ]; then cp -p "$WORK/old-$name" "$ROOT/$name"
    else rm -f "$ROOT/$name"; fi
}
finish() {
    rc=$?
    trap - 0 INT TERM HUP
    if [ "$COMMITTED" != 1 ] && [ "$CHANGED" = 1 ]; then
        echo 'Installation failed; restoring previous configuration and boot hook.' >&2
        [ ! -x "$ROOT/service" ] || "$ROOT/service" stop >/dev/null 2>&1 || :
        restore_file active || :
        restore_file config || :
        restore_file service || :
        restore_file enabled || :
        if [ -f "$WORK/old-hook" ]; then
            BOOT_TEMP=/etc/init.d/.harmony-ir-boot.$$
            cp -p "$WORK/old-hook" "$BOOT_TEMP" && mv -f "$BOOT_TEMP" "$HOOK" ||
                echo 'WARNING: boot hook restore failed' >&2
        fi
        if [ "$WAS_RUNNING" = 1 ] && [ -x "$ROOT/service" ]; then "$ROOT/service" start || :; fi
    fi
    [ -z "${BOOT_TEMP:-}" ] || rm -f "$BOOT_TEMP"
    [ -z "$WORK" ] || rm -rf "$WORK"
    rm -f "$LOCK/pid"
    remove_empty_dir "$LOCK" 2>/dev/null || :
    exit "$rc"
}

write_payload() { return 1; }

main() {
    case "${1:-}" in --help|-h) help; return ;; esac
    [ "$RELEASE_ID" != '@RELEASE_ID@' ] || fail 'use computer-side install.py over SSH'
    [ "$(id -u)" = 0 ] || fail 'run on the Hub as root'
    [ -x /usr/bin/lua ] && [ -r /opt/lib/luaworks.so ] || fail 'stock Hub Lua/library not found'
    [ -r /etc/version ] && [ "$(cat /etc/version)" = 4.15.600 ] || fail 'only firmware 4.15.600 is supported'
    [ -f "$HOOK" ] && [ ! -L "$HOOK" ] && [ -x "$HOOK" ] || fail 'unsupported rcS.local; refusing boot changes'
    [ ! -L "$ROOT" ] && [ ! -L "$LOCK" ] && [ ! -L "$ROOT/.managed" ] || fail 'unsafe installation path'
    if [ -e "$ROOT" ]; then
        [ -f "$ROOT/.managed" ] && [ "$(cat "$ROOT/.managed")" = harmony-ir-v1 ] || fail '/data/harmony-ir is not managed by this installer'
        for name in active previous config service enabled; do
            [ ! -L "$ROOT/$name" ] || fail 'unexpected symlink in installation metadata'
        done
        [ ! -L "$ROOT/releases" ] && [ ! -L "$ROOT/backups" ] &&
            [ ! -L "$ROOT/backups/rcS.local.before-install" ] || fail 'unexpected installation directory/backup symlink'
    fi
    LISTEN=0.0.0.0
    PORT=8089
    if [ -f "$ROOT/config" ]; then
        while IFS= read -r line; do
            case "$line" in LISTEN=*) LISTEN=${line#LISTEN=} ;; PORT=*) PORT=${line#PORT=} ;; esac
        done < "$ROOT/config"
    fi
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || fail 'missing option value'
        case "$1" in --listen) LISTEN=$2 ;; --port) PORT=$2 ;; *) fail "unknown option: $1" ;; esac
        shift 2
    done
    printf '%s\n' "$LISTEN" | awk -F. 'NR!=1 || NF!=4{exit 1} {for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || length($i)>3 || $i>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1} END {if(NR!=1) exit 1}' || fail 'listen must be numeric IPv4'
    case "$PORT" in ''|0*|*[!0-9]*) fail 'invalid port' ;; esac
    [ "${#PORT}" -le 5 ] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail 'port must be 1024..65535'
    awk -v begin="$BEGIN" -v end="$END" '
      $0==begin {if(open || seen++) exit 2; open=1}
      $0==end {if(!open) exit 2; open=0}
      END {if(open) exit 2}
    ' "$HOOK" || fail 'boot hook has invalid Harmony IR markers'
    mkdir "$LOCK" || fail 'another install is active (inspect /data/.harmony-ir-install.lock if stale)'
    WORK=
    COMMITTED=0
    CHANGED=0
    WAS_RUNNING=0
    trap finish 0
    trap 'exit 1' INT TERM HUP
    echo "$$" > "$LOCK/pid" || fail 'cannot write install lock PID'
    mkdir -p "$ROOT/releases" "$ROOT/backups" || fail 'persistent storage is not writable'
    chmod 700 "$ROOT" "$ROOT/releases" "$ROOT/backups" || fail 'cannot secure installation directory'
    echo harmony-ir-v1 > "$ROOT/.managed" || fail 'cannot write ownership marker'
    WORK="$ROOT/.install.$$"
    mkdir "$WORK" "$WORK/release" || fail 'cannot stage installation'
    for file in ir.lua client.lua http.lua bridge.lua server.lua transmit.lua capture.lua diagnose.lua service.sh; do
        write_payload "$file" > "$WORK/release/$file" || fail "cannot stage $file"
        case "$file" in
            *.lua) HARMONY_IR_CHECK="$WORK/release/$file" /usr/bin/lua -e 'assert(loadfile(os.getenv("HARMONY_IR_CHECK")))' || fail "invalid Lua: $file" ;;
        esac
    done
    /bin/sh -n "$WORK/release/service.sh" || fail 'invalid service script'
    chmod 700 "$WORK/release/service.sh" || fail 'cannot set service permissions'
    /usr/bin/lua "$WORK/release/transmit.lua" --probe || fail 'standalone native modules unavailable'
    cp -p "$HOOK" "$WORK/old-hook" || fail 'cannot back up boot hook'
    for name in active config service enabled; do
        if [ -f "$ROOT/$name" ]; then cp -p "$ROOT/$name" "$WORK/old-$name" || fail 'cannot back up settings'; fi
    done
    if [ ! -f "$ROOT/backups/rcS.local.before-install" ]; then
        cp -p "$HOOK" "$ROOT/backups/rcS.local.before-install" || fail 'cannot save original boot hook'
    fi
    echo "WARNING: installing unauthenticated HTTP on $LISTEN:$PORT. Trusted LAN only."
    if [ -x "$ROOT/service" ] && "$ROOT/service" status >/dev/null 2>&1; then
        WAS_RUNNING=1
        CHANGED=1
        "$ROOT/service" stop || fail 'cannot stop previous service'
    fi
    if port_in_use; then
        fail "port $PORT is already listening; stop the foreground bridge/other listener before installing"
    fi
    release="$RELEASE_ID-$$"
    [ ! -e "$ROOT/releases/$release" ] || fail 'release path already exists; rerun installer'
    mv "$WORK/release" "$ROOT/releases/$release" || fail 'cannot install release'
    CHANGED=1
    printf '%s\n' "$release" > "$WORK/active"
    printf 'LISTEN=%s\nPORT=%s\n' "$LISTEN" "$PORT" > "$WORK/config"
    cat > "$WORK/service" <<'WRAPPER'
#!/bin/sh
ROOT=/data/harmony-ir
release=$(cat "$ROOT/active") || exit 1
case "$release" in ''|*[!0-9a-f-]*|-*|*-|*--*) echo 'Invalid Harmony IR release' >&2; exit 1 ;; esac
exec /bin/sh "$ROOT/releases/$release/service.sh" "$@"
WRAPPER
    chmod 700 "$WORK/service"
    mv -f "$WORK/active" "$ROOT/active" && mv -f "$WORK/config" "$ROOT/config" &&
        mv -f "$WORK/service" "$ROOT/service" || fail 'cannot activate release'
    awk -v begin="$BEGIN" -v end="$END" '
      function block() {
        print begin
        print "if [ -x /data/harmony-ir/service ]; then"
        print "    /data/harmony-ir/service start </dev/null >/dev/null 2>&1 || :"
        print "fi"
        print end
      }
      NR==1 && substr($0,1,2)=="#!" {print; block(); next}
      NR==1 {block()}
      $0==begin {skip=1; next}
      $0==end {skip=0; next}
      !skip {print}
      END {if(NR==0) block()}
    ' "$HOOK" > "$WORK/new-hook" || fail 'cannot prepare boot hook'
    BOOT_TEMP=/etc/init.d/.harmony-ir-boot.$$
    cp -p "$HOOK" "$BOOT_TEMP" && cat "$WORK/new-hook" > "$BOOT_TEMP" &&
        mv -f "$BOOT_TEMP" "$HOOK" || fail 'cannot update boot hook'
    touch "$ROOT/enabled" || fail 'cannot enable service'
    "$ROOT/service" start || fail 'cannot start supervisor'
    n=0
    until "$ROOT/service" check >/dev/null 2>&1; do
        n=$((n + 1))
        if [ "$n" -ge 15 ]; then
            echo 'Last health-check error (before rollback):' >&2
            "$ROOT/service" check >&2 || :
            "$ROOT/service" status >&2 || :
            fail 'bridge did not become healthy; inspect /tmp/harmony-ir-service/bridge.log'
        fi
        sleep 1
    done
    COMMITTED=1
    previous=
    if [ -f "$WORK/old-active" ]; then previous=$(cat "$WORK/old-active"); fi
    printf '%s\n' "$previous" > "$WORK/previous"
    mv -f "$WORK/previous" "$ROOT/previous" || :
    for old in "$ROOT/releases/"*; do
        [ -d "$old" ] && [ ! -L "$old" ] || continue
        name=${old##*/}
        case "$name" in ''|*[!0-9a-f-]*|-*|*-|*--*) continue ;; esac
        if [ "$name" != "$release" ] && [ "$name" != "$previous" ]; then rm -rf "$old"; fi
    done
    echo 'Harmony IR installed and healthy. Boot startup enabled; no reboot performed.'
    echo 'Controller: /data/harmony-ir/service {status|check|start|stop|restart|enable|disable|uninstall}'
    echo 'RAM logs: /tmp/harmony-ir-service/bridge.log'
    echo 'Original boot backup: /data/harmony-ir/backups/rcS.local.before-install'
    echo 'Survives normal reboots; not guaranteed across reset or firmware replacement.'
}

main "$@"
