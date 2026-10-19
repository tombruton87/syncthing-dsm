# Syncthing's hooks for the chassis core (sourced by run-core.sh).
# The core gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, fresh, now, wait_ready, make_backup, record_backup, notify,
# qr_png_b64, MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE, HOST_UID, HOST_GID.
#
# Syncthing runs as the package's own user (PUID/PGID = HOST_UID/HOST_GID). The
# package talks to it through its REST API with a key of its own (STGUIAPIKEY,
# kept in the root-only .env), always on 127.0.0.1:<web port>: the setup
# container is on the NAS's network, and Syncthing's GUI is there in both
# network modes. The folders it syncs are shared folders the window picks; each
# is mounted at its own path in one of eight fixed places in compose.yaml.

ST=""
ST_REPO=syncthing/syncthing
ST_PINNED=syncthing/syncthing:2.1.6
PLACES="PLACE_1 PLACE_2 PLACE_3 PLACE_4 PLACE_5 PLACE_6 PLACE_7 PLACE_8"
DEV_RE='^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'
# Ignore patterns for folders on a Synology: DSM's thumbnails and recycle bins, snapshots, and what Macs,
# Windows and Synology Drive leave behind. (?d): Syncthing may delete them when a folder they're in goes.
DSM_IGNORES='(?d)@eaDir
(?d)#recycle
(?d)#snapshot
(?d).DS_Store
(?d)._*
(?d)Thumbs.db
(?d)desktop.ini
(?d).SynologyWorkingDirectory'

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    SYNC_PORT)   [[ "$2" =~ ^[0-9]{4,5}$ ]] && (( 10#$2 >= 1024 && 10#$2 <= 65535 )) ;;
    PRIVACY)     [[ "$2" =~ ^(anywhere|local)$ ]] ;;
    NET_MODE)    [[ "$2" =~ ^(host|bridge)$ ]] ;;
    TEST_SHARES) [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ && "$2" != *..* ]] && (( ${#2} <= 200 )) ;;
    DEV_ID)      [[ "$2" =~ $DEV_RE ]] ;;
    DEV_NAME_B64|FLABEL_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 200 )) ;;
    DEV_ADDR_B64|FID_B64)    [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 400 )) ;;
    FPATH_B64|CONFLICT_B64)  [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 1400 )) ;;
    IGN_B64)     [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 4000 )) ;;
    PAUSE|LAN_LIMIT) [[ "$2" =~ ^[01]$ ]] ;;
    FTYPE)       [[ "$2" =~ ^(sendreceive|sendonly|receiveonly)$ ]] ;;
    FDEVICES)    devices_ok "$2" ;;
    VTYPE)       [[ "$2" =~ ^(none|trashcan|simple|staggered)$ ]] ;;
    VKEEP)       [[ "$2" =~ ^[0-9]{1,3}$ ]] && (( 10#$2 >= 1 )) ;;
    VDAYS)       [[ "$2" =~ ^[0-9]{1,4}$ ]] && (( 10#$2 <= 3650 )) ;;
    MAX_SEND|MAX_RECV) [[ "$2" =~ ^[0-9]{1,7}$ ]] ;;
    *) return 1 ;;
  esac
}
devices_ok() {   # "none", or device IDs joined by + (at most 32)
  [[ "$1" == none ]] && return 0
  local d n=0; local IFS=+
  for d in $1; do [[ "$d" =~ $DEV_RE ]] || return 1; (( ++n <= 32 )) || return 1; done
  (( n >= 1 ))
}

# ------------------------------------------------------------ small helpers
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
env_set_q() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}; env_set "$1" "\"$v\""; }
env_get_q() { local v; v=$(env_get "$1"); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}"; }
uri() { jq -rn --arg v "$1" '$v | @uri'; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }   # is version $1 newer than $2?
is_synology() { [[ -f /etc.defaults/VERSION ]]; }
text_ok() { local bad='[[:cntrl:]]'; [[ -n "$1" && ${#1} -le "${2:-100}" && ! "$1" =~ $bad ]]; }   # one line of free text
for_window_file() { chown "$HOST_UID:$HOST_GID" "$1" 2>/dev/null || true; chmod 600 "$1" 2>/dev/null || true; }

# ------------------------------------------------------------ talking to Syncthing
ST_KEY=""; ST_PORT=""
st_load() { ST=$(cname server); ST_KEY=$(env_get ST_APIKEY); ST_PORT=$(env_get HTTP_PORT); }
st() {   # method path [json] → the body on stdout (HTTP code in ST_CODE); 0 on 2xx
  local out
  [[ -n "$ST_KEY" ]] || st_load
  out=$(curl -s --max-time "${ST_TIMEOUT:-20}" -X "$1" "http://127.0.0.1:$ST_PORT/rest/$2" -H "X-API-Key: $ST_KEY" \
        ${3:+-H 'Content-Type: application/json' --data-binary "$3"} -w '\n%{http_code}' 2>/dev/null) || out=$'\n0'
  ST_CODE=${out##*$'\n'}; out=${out%$'\n'*}; ST_BODY=$out
  printf '%s' "$out"; [[ "$ST_CODE" =~ ^2 ]]
}
st_why() { [[ "$ST_CODE" == 0 ]] && echo "Syncthing isn't answering." || echo "Syncthing said: $(printf '%s' "${ST_BODY:-HTTP $ST_CODE}" | tr -d '\000-\037' | head -c 200)"; }
st_up() { [[ "$(curl -s --max-time 5 "http://127.0.0.1:${ST_PORT:-$(env_get HTTP_PORT)}/rest/noauth/health" 2>/dev/null)" == *OK* ]]; }
st_wait() { local i; for (( i = 0; i < ${1:-120}; i += 2 )); do st_up && return 0; sleep 2; done; return 1; }
app_health() { st_up; }
st_tag() { local i=${1:-$(env_get ST_IMAGE)}; [[ "$i" =~ ^syncthing/syncthing:([0-9]+\.[0-9]+\.[0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; true; }
app_version() { st_tag; }
my_id() { local id; id=$(cat "$VAR/.my-id" 2>/dev/null); [[ "$id" =~ $DEV_RE ]] || { id=$(st GET system/status | jq -r '.myID // empty' 2>/dev/null); [[ "$id" =~ $DEV_RE ]] && echo "$id" > "$VAR/.my-id"; }; [[ "$id" =~ $DEV_RE ]] && echo "$id"; }

# ------------------------------------------------------------ network: the NAS's own, or Docker's
# "host": Syncthing on the NAS's own network, so local discovery finds (and is found by) devices on
# your network. "bridge": Docker's network with the GUI and sync ports published; local discovery
# can't cross it. The core always runs compose.yaml; in host mode this extra file goes on top of it.
compose() {
  local f=(-f "$APP/compose.yaml")
  if [[ "$(env_get NET_MODE)" == host ]]; then write_host_compose; f+=(-f "$APP/compose.host.yaml"); fi
  docker compose "${f[@]}" --project-directory "$APP" "$@"
}
write_host_compose() {
  cat > "$APP/compose.host.yaml.tmp" <<'YAML'
# Written by the package in host mode, on top of compose.yaml: Syncthing on the NAS's own network.
services:
  server:
    network_mode: host
    ports: !reset []
YAML
  mv "$APP/compose.host.yaml.tmp" "$APP/compose.host.yaml"
}
port_taken() {   # port proto(tcp|udp) → who else listens there (empty when free, or when it's Syncthing itself)
  svc_up server && return 0
  local opt=-lntpH; [[ "$2" == udp ]] && opt=-lnupH
  ss $opt 2>/dev/null | awk -v p="$1" '{ n = split($4, a, ":"); if (a[n] != p) next; who = ($NF ~ /users:/) ? $NF : ""; sub(/^users:\(\("/, "", who); sub(/".*/, "", who); print $4 (who != "" ? " (" who ")" : ""); exit }'
}
listen_addrs() {   # → the listen addresses Syncthing should have, as JSON
  local p; p=$(env_get SYNC_PORT); p=${p:-22000}
  if [[ "$(env_get PRIVACY)" == local ]]; then jq -nc --arg p "$p" '["tcp://0.0.0.0:" + $p, "quic://0.0.0.0:" + $p]'
  else jq -nc --arg p "$p" '["tcp://0.0.0.0:" + $p, "quic://0.0.0.0:" + $p, "dynamic+https://relays.syncthing.net/endpoint"]'; fi
}
privacy_opts() {   # local|anywhere → the options that make it so
  if [[ "$1" == local ]]; then
    jq -nc --argjson l "$(listen_addrs)" '{listenAddresses: $l, globalAnnounceEnabled: false, relaysEnabled: false, natEnabled: false, stunServers: [], urAccepted: -1, crashReportingEnabled: false, localAnnounceEnabled: true}'
  else
    jq -nc --argjson l "$(listen_addrs)" '{listenAddresses: $l, globalAnnounceEnabled: true, relaysEnabled: true, natEnabled: true, stunServers: ["default"], localAnnounceEnabled: true}'
  fi
}
converge() {   # what the package owns in Syncthing's settings: where it listens (the sync port), the privacy mode
  local o want
  o=$(st GET config/options) || return 1
  want=$(listen_addrs)
  if ! jq -e --argjson w "$want" '.listenAddresses == $w' <<< "$o" >/dev/null 2>&1; then
    st PATCH config/options "$(jq -nc --argjson l "$want" '{listenAddresses: $l}')" >/dev/null && say "Syncthing listens on $(jq -r 'join(", ")' <<< "$want")"
  fi
}

# ------------------------------------------------------------ folders: shared folders in fixed places
# A folder the package may sync: an absolute path, nothing odd in it; on a Synology, in a shared folder on a
# volume (never one of DSM's own @ folders, a recycle bin or snapshot, nor this package's own share).
test_shares() { is_synology && return 1; local t; t=$(env_get TEST_SHARES); [[ -n "$t" ]] && echo "$t"; }
path_ok() {
  local p=$1 bad='[[:cntrl:]$"\`]' t
  [[ "$p" == /?* && "$p" != */ && "$p" != *..* && "$p" != *//* && "$p" != */./* && ${#p} -le 400 && ! "$p" =~ $bad ]] || return 1
  [[ "/$p/" == */@* || "$p" == *"/#recycle"* || "$p" == *"/#snapshot"* ]] && return 1
  if is_synology; then [[ "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/[^/]+ && ! "$p" =~ ^/volume(USB)?[0-9]+(-[0-9]+)?/$PKG_NAME(/|$) ]] || return 1
  elif t=$(test_shares); then [[ "$p" == "$t"/?* ]] || return 1; fi
  return 0
}
share_root() {   # path → the shared folder it's in (/volume1/photos/Phone → /volume1/photos)
  local t
  if is_synology; then [[ "$1" =~ ^(/volume(USB)?[0-9]+(-[0-9]+)?/[^/]+) ]] && echo "${BASH_REMATCH[1]}"; return; fi
  if t=$(test_shares); then local rest=${1#"$t"/}; echo "$t/${rest%%/*}"; return; fi
  echo "$1"
}
# Is it there? Asked of Docker, which sees the NAS's own folders. --mount, not -v: -v would quietly create it.
folder_there() { docker run --rm --mount "type=bind,source=$1,target=/m,readonly" --entrypoint sh "$PKG_NAME-setup:local" -c 'test -d /m' >/dev/null 2>&1; }
place_of() { local s; for s in $PLACES; do [[ "$(env_get_q "$s")" == "$1" ]] && { echo "$s"; return 0; }; done; return 1; }
free_place() { local s; for s in $PLACES; do [[ -z "$(env_get_q "$s")" ]] && { echo "$s"; return 0; }; done; return 1; }
mount_srcs() {   # every place: its shared folder if it's there, else the empty placeholder → 0 when something changed
  local s p want changed=1
  mkdir -p "$APP/no-folder"
  for s in $PLACES; do p=$(env_get_q "$s"); want=""
    [[ -n "$p" ]] && path_ok "$p" && folder_there "$p" && want=$p
    [[ "$(env_get_q "${s}_SRC")" == "$want" ]] && continue
    if [[ -n "$want" ]]; then env_set_q "${s}_SRC" "$want"; env_set_q "${s}_DST" "$want"; say "the shared folder $want is mounted for Syncthing"
    else env_set "${s}_SRC" ""; env_set "${s}_DST" ""; [[ -n "$p" ]] && say "the shared folder $p isn't there — Syncthing waits for it (it isn't created)"; fi
    changed=0
  done
  return $changed
}
places_json() {
  local s p out="[]"
  for s in $PLACES; do p=$(env_get_q "$s"); [[ -n "$p" ]] || continue
    out=$(jq -c --arg s "$s" --arg p "$p" --argjson t "$([[ -n "$(env_get_q "${s}_SRC")" ]] && echo true || echo false)" '. + [{place: $s, path: $p, there: $t}]' <<< "$out"); done
  echo "$out"
}
restart_for_folders() { compose up -d >> "$LOG" 2>&1 && wait_ready 180; }
places_ensure() {   # [extra root] — places follow Syncthing's folders (added here, in its own GUI, or by a restore) → 0 if a restart is needed
  local paths p r s want=() changed=1
  paths=$(st GET config/folders | jq -r '.[].path' 2>/dev/null) || return 1
  [[ -n "${1:-}" ]] && paths+=$'\n'"$1"
  while IFS= read -r p; do [[ -n "$p" ]] && path_ok "$p" || continue; r=$(share_root "$p"); [[ -n "$r" ]] && want+=("$r"); done <<< "$paths"
  for s in $PLACES; do p=$(env_get_q "$s"); [[ -n "$p" ]] || continue   # let go of places nothing uses
    printf '%s\n' "${want[@]}" | grep -qxF -- "$p" && continue
    env_set "$s" ""; say "$p is no longer synced — unmounted"; changed=0
  done
  for r in "${want[@]}"; do place_of "$r" >/dev/null && continue
    if s=$(free_place); then env_set_q "$s" "$r"; say "$r is synced — mounting it for Syncthing"; changed=0
    else say "✗ $r is used by a Syncthing folder, but all eight places are in use"; fi
  done
  mount_srcs && changed=0
  return $changed
}
# What the package's user may do in a folder (Syncthing runs as it): rw, ro or none, tested by writing a file.
ACCESS_SH='for p in "$@"; do q=$p; while [ ! -d "$q" ] && [ -n "$q" ] && [ "$q" != / ]; do q=${q%/*}; done; [ -n "$q" ] || q=/
  t="$q/.syncthing-dsm-write-test.$$"
  if ( : > "$t" ) 2>/dev/null; then rm -f "$t"; a=rw; elif ls "$q" >/dev/null 2>&1; then a=ro; else a=none; fi
  printf "%s\t%s\n" "$a" "$p"; done'
access_json() { jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[1], value: .[0]}) | from_entries' 2>/dev/null || echo '{}'; }
folders_access() {   # every synced folder, tested inside Syncthing's own container as its user → $VAR/access.json
  local paths=()
  mapfile -t paths < <(st GET config/folders | jq -r '.[].path' 2>/dev/null)
  (( ${#paths[@]} )) || { echo '{}' > "$VAR/access.json"; return 0; }
  docker exec -u "$HOST_UID:$HOST_GID" "$ST" sh -c "$ACCESS_SH" sh "${paths[@]}" 2>/dev/null | access_json > "$VAR/access.json.tmp" && mv "$VAR/access.json.tmp" "$VAR/access.json"
}
path_access() {   # path → rw|ro|none for the package's user, before it's mounted for Syncthing
  local r; r=$(share_root "$1")
  docker run --rm --user "$HOST_UID:$HOST_GID" --mount "type=bind,source=$r,target=$r" --entrypoint sh "$PKG_NAME-setup:local" -c "$ACCESS_SH" sh "$1" 2>/dev/null | cut -f1
}
shares_scan() {   # the shared folders on this Synology, and what the package's user may do in each → $VAR/shares.json
  local list=() p mounts=()
  if is_synology; then
    mapfile -t list < <(docker run --rm --privileged --pid=host --network=host --entrypoint nsenter "$PKG_NAME-setup:local" -t 1 -m -- \
      sh -c 'for d in /volume*/*; do [ -d "$d" ] && [ ! -L "$d" ] && echo "$d"; done' 2>/dev/null)
  elif p=$(test_shares); then   # a test box: the folders in TEST_SHARES, as Docker sees them
    mapfile -t list < <(docker run --rm --mount "type=bind,source=$p,target=$p,readonly" --entrypoint find "$PKG_NAME-setup:local" "$p" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort); fi
  local ok=()
  for p in "${list[@]}"; do path_ok "$p" && [[ "$(share_root "$p")" == "$p" ]] && ok+=("$p"); done
  if (( ${#ok[@]} )); then
    for p in "${ok[@]}"; do mounts+=(--mount "type=bind,source=$p,target=$p,readonly=false"); done
    docker run --rm --user "$HOST_UID:$HOST_GID" "${mounts[@]}" --entrypoint sh "$PKG_NAME-setup:local" -c "$ACCESS_SH" sh "${ok[@]}" 2>/dev/null \
      | jq -R -s -c --argjson at "$(now)" '{at: $at, shares: (split("\n") | map(select(length > 0) | split("\t") | {path: .[1], access: .[0]}))}' > "$VAR/shares.json.tmp" 2>/dev/null \
      && mv "$VAR/shares.json.tmp" "$VAR/shares.json"
  else jq -nc --argjson at "$(now)" '{at: $at, shares: []}' > "$VAR/shares.json"; fi
}
ignores_lines() { b64d "$1" | tr -d '\r' | awk 'length($0) > 0' | head -n 200; }
ignores_ok() { local bad='[[:cntrl:]]' l; while IFS= read -r l; do [[ ${#l} -le 300 && ! "$l" =~ $bad ]] || return 1; done <<< "$1"; }
folder_json() { st GET "config/folders/$(uri "$1")"; }
new_folder_id() { echo "$(rand 5 | tr 'A-Z' 'a-z')-$(rand 5 | tr 'A-Z' 'a-z')"; }
versioning_json() {   # VTYPE VKEEP VDAYS → Syncthing's versioning object (its params are strings)
  case "$1" in
    trashcan)  jq -nc --arg d "${3:-30}" '{type: "trashcan", params: {cleanoutDays: $d}, cleanupIntervalS: 3600}' ;;
    simple)    jq -nc --arg k "${2:-5}" --arg d "${3:-0}" '{type: "simple", params: {keep: $k, cleanoutDays: $d}, cleanupIntervalS: 3600}' ;;
    staggered) jq -nc --arg a "$(( 10#${3:-365} * 86400 ))" '{type: "staggered", params: {maxAge: $a}, cleanupIntervalS: 3600}' ;;
    *)         jq -nc '{type: "", params: {}, cleanupIntervalS: 3600}' ;;
  esac
}
set_ignores() {   # folder-id lines — retried while Syncthing makes the folder
  local i body; body=$(jq -Rsc 'split("\n") | map(select(length > 0)) | {ignore: .}' <<< "$2")
  for i in 1 2 3 4 5 6 7 8 9 10; do st POST "db/ignores?folder=$(uri "$1")" "$body" >/dev/null && return 0; sleep 1; done
  return 1
}
add_folder() {   # id label path type devices-json versioning-json ignore-lines → MSG
  local id=$1 label=$2 path=$3 type=$4 devs=$5 vers=$6 ign=$7 root place access body
  path_ok "$path" || { MSG="$path isn't a folder Syncthing can use here: a shared folder (or a folder in one), like /volume1/photos."; return 1; }
  root=$(share_root "$path")
  folder_there "$root" || { MSG="There's no shared folder $root on this Synology. Make it in Control Panel → Shared Folder first; the package never creates one."; return 1; }
  st GET config/folders | jq -e --arg p "$path" 'map(.path) | map(select(. == $p or ($p | startswith(. + "/")) or startswith($p + "/"))) | length > 0' >/dev/null 2>&1 \
    && { MSG="$path is, or is inside or around, a folder Syncthing already syncs. Pick another one."; return 1; }
  if ! place_of "$root" >/dev/null; then
    place=$(free_place) || { MSG="All eight places for shared folders are in use. Folders inside a shared folder that's already synced don't need a place of their own."; return 1; }
    env_set_q "$place" "$root"; mount_srcs || true
    say "mounting $root for Syncthing (Syncthing restarts)"
    restart_for_folders || { MSG="Syncthing didn't come back with $root mounted — see the log."; return 1; }
  fi
  access=$(path_access "$path")
  # Paused while its ignore patterns go in, so nothing they'd keep out is read first.
  body=$(jq -nc --arg id "$id" --arg l "$label" --arg p "$path" --arg t "$type" --argjson d "$devs" --argjson v "$vers" \
    '{id: $id, label: $l, path: $p, type: $t, devices: ($d | map({deviceID: .})), versioning: $v, paused: true, fsWatcherEnabled: true, rescanIntervalS: 3600}')
  st POST config/folders "$body" >/dev/null || { MSG="Syncthing didn't add the folder. $(st_why)"; return 1; }
  [[ -n "$ign" ]] && { set_ignores "$id" "$ign" || say "✗ the ignore patterns for $label didn't go in: $(st_why)"; }
  st PATCH "config/folders/$(uri "$id")" '{"paused": false}' >/dev/null || true
  folders_access; FORCE_COLLECT=1
  MSG="$label syncs $path."
  case "$access" in
    rw) ;;
    ro) [[ "$type" == sendonly ]] || MSG="$MSG But Syncthing can only read it: $(fix_text "$root") Until then it can't save changes from other devices." ;;
    *)  MSG="$MSG But Syncthing can't read it: $(fix_text "$root")" ;;
  esac
}
fix_text() { echo "in DSM, Control Panel → Shared Folder → $(basename "$1") → Edit → Permissions → pick \"System internal user\" in the drop-down → syncthing → tick Read/Write → Save."; }

# ------------------------------------------------------------ conflicts
# Every *.sync-conflict-* file in the synced folders (Syncthing's copies of a file two devices changed at once),
# with its original beside it. Read inside Syncthing's container, where the folders are mounted at their own paths.
CONFLICT_SH='for p in "$@"; do [ -d "$p" ] || continue
  find "$p" -xdev -type f -name "*.sync-conflict-*" ! -path "*/.stversions/*" ! -path "*/.stfolder/*" 2>/dev/null | head -n 2000 | while IFS= read -r f; do
    o=$(printf "%s" "$f" | sed -E "s/\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]{7}//")
    [ "$o" = "$f" ] && continue
    c=$(stat -c "%s %Y" "$f" 2>/dev/null) || continue
    if [ -f "$o" ]; then oc=$(stat -c "%s %Y" "$o" 2>/dev/null); else oc="- -"; fi
    printf "%s\t%s\t%s %s\n" "$f" "$o" "$c" "$oc"; done; done'
CONFLICT_RE='\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]{7}'
conflicts_scan() {   # → $VAR/conflicts.json; notifies when new ones appear
  local cfg paths=() raw names
  cfg=$(st GET config) || return 1
  mapfile -t paths < <(jq -r '.folders[] | select(.paused | not) | .path' <<< "$cfg")
  if (( ${#paths[@]} )); then raw=$(docker exec "$ST" sh -c "$CONFLICT_SH" sh "${paths[@]}" 2>/dev/null | head -n 5000); else raw=""; fi
  names=$(jq -c '[.devices[] | {key: .deviceID[0:7], value: .name}] | from_entries' <<< "$cfg")
  jq -R -s -c --argjson cfg "$cfg" --argjson names "$names" --arg me "$(my_id | cut -c1-7)" --argjson at "$(now)" '
    [split("\n")[] | select(length > 0) | split("\t") | . as [$f, $o, $st] | ($st | split(" ")) as [$cs, $ct, $os, $ot]
     | ([$cfg.folders[] | select(.path as $p | $f | startswith($p + "/"))] | sort_by(-(.path | length)) | .[0]) as $fo
     | select($fo != null)
     | ($f | capture("\\.sync-conflict-(?<d>[0-9]{8})-(?<t>[0-9]{6})-(?<by>[A-Z0-9]{7})")) as $m
     | {path: $f, original: $o, folder: $fo.id, label: ($fo.label // $fo.id), rel: ($f | ltrimstr($fo.path + "/")), orig_rel: ($o | ltrimstr($fo.path + "/")),
        size: ($cs | tonumber), at: ($ct | tonumber), by: (if $m.by == $me then "this Synology" else ($names[$m.by] // ("device " + $m.by)) end),
        orig_size: ($os | tonumber? // null), orig_at: ($ot | tonumber? // null)}]
    | {at: $at, count: length, conflicts: .}' <<< "$raw" > "$VAR/conflicts.json.tmp" 2>/dev/null || { rm -f "$VAR/conflicts.json.tmp"; return 1; }
  for_window "$VAR/conflicts.json"
  # New since the last look: a DSM notification (once per set of new files).
  local new; new=$(jq -r '.conflicts[].path' "$VAR/conflicts.json" | grep -vxF -f <(cat "$VAR/.conflicts-seen" 2>/dev/null; echo "/nothing/") || true)
  if [[ -n "$new" && -f "$VAR/.conflicts-seen" ]]; then
    notify conflicts 1 "$(grep -c . <<< "$new")" "$(jq -r --arg p "$(head -n 1 <<< "$new")" '.conflicts[] | select(.path == $p) | .label' "$VAR/conflicts.json")"
  fi
  jq -r '.conflicts[].path' "$VAR/conflicts.json" > "$VAR/.conflicts-seen"
}
conflict_check() {   # decoded path → sets C_FILE C_ORIG C_FID C_REL (C_REL: the original, relative to its folder)
  local f=$1 bad='[[:cntrl:]]' fo
  [[ "$f" == /?* && "$f" != *..* && "$f" != *//* && ${#f} -le 1000 && ! "$f" =~ $bad && "$(basename "$f")" =~ $CONFLICT_RE ]] || { MSG="That isn't a conflict file."; return 1; }
  fo=$(st GET config/folders | jq -c --arg f "$f" '[.[] | select(.path as $p | $f | startswith($p + "/"))] | sort_by(-(.path | length)) | .[0] // empty' 2>/dev/null)
  [[ -n "$fo" ]] || { MSG="That file isn't in a synced folder."; return 1; }
  C_FILE=$f; C_ORIG=$(sed -E "s/$CONFLICT_RE//" <<< "$f"); C_FID=$(jq -r .id <<< "$fo"); C_REL=${C_ORIG#"$(jq -r .path <<< "$fo")"/}
  docker exec "$ST" test -f "$C_FILE" -a ! -L "$C_FILE" || { MSG="That conflict copy isn't there any more."; return 1; }
}
as_st_user() { docker exec -u "$HOST_UID:$HOST_GID" "$ST" "$@" >> "$LOG" 2>&1; }

# ------------------------------------------------------------ activity: Syncthing's events, kept
# Syncthing keeps its last 1000 events in memory and starts again at 1 when it restarts; the package keeps the
# file changes (and failed items) in $VAR/activity.json, newest first, up to 400.
JQ_TS='def ts: if . == null or . == "" then 0 else (sub("\\.[0-9]+"; "") | if test("Z$") then fromdateiso8601
  else (capture("^(?<d>.{19})(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2})$") as $c | ($c.d + "Z" | fromdateiso8601) - (($c.s + "1" | tonumber) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60))) end) end;'
events_poll() {
  local start since out cfg last
  start=$(st GET system/status | jq -r '.startTime // empty' 2>/dev/null) || return 0; [[ -n "$start" ]] || return 0
  [[ "$(cat "$VAR/.ev-start" 2>/dev/null)" == "$start" ]] || { echo "$start" > "$VAR/.ev-start"; echo 0 > "$VAR/.ev-since"; }
  since=$(tr -cd '0-9' < "$VAR/.ev-since" 2>/dev/null); since=${since:-0}
  out=$(ST_TIMEOUT=10 st GET "events?since=$since&timeout=0&limit=1000&events=LocalChangeDetected,RemoteChangeDetected,ItemFinished") || return 0
  last=$(jq -r 'map(.id) | max // empty' <<< "$out" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || return 0
  cfg=$(st GET config) || cfg='{"devices":[]}'
  jq -c --argjson cfg "$cfg" --arg me "$(my_id | cut -c1-7)" "$JQ_TS"'
    ([$cfg.devices[] | {key: .deviceID[0:7], value: .name}] | from_entries) as $names
    | [.[] | select(.type != "ItemFinished" or .data.error != null) | .data as $d
       | {id, at: (.time | ts), kind: (if .type == "LocalChangeDetected" then "local" elif .type == "RemoteChangeDetected" then "remote" else "error" end),
          action: ($d.action // "update"), type: ($d.type // "file"), folder: ($d.folderID // $d.folder), label: ($d.label // $d.folder),
          path: ($d.path // $d.item), error: $d.error,
          by: (if .type == "LocalChangeDetected" or $d.modifiedBy == $me then "this Synology" elif $d.modifiedBy then ($names[$d.modifiedBy] // ("device " + $d.modifiedBy)) else null end)}]
    | reverse' <<< "$out" > "$VAR/activity.new" 2>/dev/null || { rm -f "$VAR/activity.new"; return 0; }
  jq -c -s '(.[0] + (.[1].items // [])) | .[0:400] | {at: now | floor, items: .}' "$VAR/activity.new" <(cat "$VAR/activity.json" 2>/dev/null || echo '{}') > "$VAR/activity.json.tmp" 2>/dev/null \
    && for_window "$VAR/activity.json"
  grep -q 'sync-conflict' "$VAR/activity.new" 2>/dev/null && touch "$VAR/.conflicts-due"
  rm -f "$VAR/activity.new"; echo "$last" > "$VAR/.ev-since"
  true
}

# ------------------------------------------------------------ what the window shows
FORCE_COLLECT=0
collect() {   # everything about devices and folders → $VAR/st.json
  local sys cfg conns dstats fstats pdev pfold errs fid did fs ign fe comp folders="{}" comps="{}" rates prev myid
  sys=$(st GET system/status) || { echo '{"up": false}' > "$VAR/st.json"; return 1; }
  cfg=$(st GET config) || return 1
  conns=$(st GET system/connections) || conns='{}'
  dstats=$(st GET stats/device) || dstats='{}'
  fstats=$(st GET stats/folder) || fstats='{}'
  pdev=$(st GET cluster/pending/devices) || pdev='{}'
  pfold=$(st GET cluster/pending/folders) || pfold='{}'
  errs=$(st GET system/error) || errs='{}'
  for fid in $(jq -r '.folders[].id | @base64' <<< "$cfg"); do fid=$(base64 -d <<< "$fid")
    fs=$(st GET "db/status?folder=$(uri "$fid")") || fs='{}'
    ign=$(st GET "db/ignores?folder=$(uri "$fid")" | jq -c '.ignore // []' 2>/dev/null) || ign='[]'; [[ "$ign" == \[* ]] || ign='[]'
    fe='[]'; if jq -e '(.pullErrors // 0) > 0 or (.errors // 0) > 0' <<< "$fs" >/dev/null 2>&1; then
      fe=$(st GET "folder/errors?folder=$(uri "$fid")&perpage=50" | jq -c '.errors // []' 2>/dev/null) || fe='[]'; [[ "$fe" == \[* ]] || fe='[]'; fi
    folders=$(jq -c --arg id "$fid" --argjson s "$fs" --argjson i "$ign" --argjson e "$fe" '. + {($id): {status: $s, ignores: $i, errors: $e}}' <<< "$folders")
  done
  for did in $(jq -r '.devices[].deviceID' <<< "$cfg"); do [[ "$did" =~ $DEV_RE ]] || continue
    comp=$(st GET "db/completion?device=$did") || comp='{}'
    comps=$(jq -c --arg id "$did" --argjson c "$comp" '. + {($id): $c}' <<< "$comps")
  done
  prev=$(cat "$VAR/.rates" 2>/dev/null || echo '{}'); jq -e . <<< "$prev" >/dev/null 2>&1 || prev='{}'
  jq -c --argjson at "$(now)" '{at: $at, totals: ((.connections // {}) | map_values({in: .inBytesTotal, out: .outBytesTotal}))}' <<< "$conns" > "$VAR/.rates" 2>/dev/null
  myid=$(jq -r .myID <<< "$sys"); [[ "$myid" =~ $DEV_RE ]] && echo "$myid" > "$VAR/.my-id"
  jq -n -c "$JQ_TS"'
    $cfg as $c | ($c.devices | map({key: .deviceID, value: .name}) | from_entries) as $names
    | (now | floor) as $now | (($now - ($prev.at // 0)) | if . < 1 then 1 else . end) as $dt
    | {up: true, my_id: $sys.myID, my_name: ($names[$sys.myID] // ""), started: ($sys.startTime | ts),
       listeners: [($sys.connectionServiceStatus // {}) | to_entries[] | {address: .key, error: .value.error, lan: (.value.lanAddresses // [])}],
       discovery: [($sys.discoveryStatus // {}) | to_entries[] | {name: .key, error: .value.error}],
       options: ($c.options | {listenAddresses, globalAnnounceEnabled, localAnnounceEnabled, relaysEnabled, natEnabled, maxSendKbps, maxRecvKbps, limitBandwidthInLan, urAccepted}),
       gui_user: ($c.gui.user // ""),
       devices: [$c.devices[] | select(.deviceID != $sys.myID) | .deviceID as $id | ($conns.connections[$id] // {}) as $k | ($prev.totals[$id] // null) as $p
         | {id: $id, name: .name, paused: .paused, addresses: .addresses, introducer: .introducer,
            connected: ($k.connected // false), address: ($k.address // ""), conn_type: ($k.type // ""), lan: ($k.isLocal // false), client: ($k.clientVersion // ""),
            in_total: ($k.inBytesTotal // 0), out_total: ($k.outBytesTotal // 0),
            in_rate: (if $p and ($k.connected // false) then ((($k.inBytesTotal // 0) - $p.in) / $dt | if . < 0 then 0 else floor end) else 0 end),
            out_rate: (if $p and ($k.connected // false) then ((($k.outBytesTotal // 0) - $p.out) / $dt | if . < 0 then 0 else floor end) else 0 end),
            last_seen: (($dstats[$id].lastSeen // null) | ts | if . < 100000 then null else . end),
            completion: ($comps[$id].completion // null), need_bytes: ($comps[$id].needBytes // 0), need_items: ($comps[$id].needItems // 0),
            folders: [$c.folders[] | select(any(.devices[]; .deviceID == $id)) | .label // .id]}],
       pending_devices: [$pdev | to_entries[] | select(.key as $k | $c.devices | map(.deviceID) | index($k) | not)
         | {id: .key, name: (.value.name // ""), address: (.value.address // ""), at: (.value.time | ts)}],
       folders: [$c.folders[] | .id as $id | ($f[$id] // {}) as $x | ($x.status // {}) as $s
         | {id: $id, label: (.label // ""), path, type, paused, devices: [.devices[].deviceID | select(. != $sys.myID)],
            versioning: {type: (.versioning.type // ""), params: (.versioning.params // {})}, watcher: .fsWatcherEnabled, rescan_s: .rescanIntervalS,
            state: ($s.state // "unknown"), error: ($s.error // ""), global_files: ($s.globalFiles // 0), global_bytes: ($s.globalBytes // 0),
            local_files: ($s.localFiles // 0), local_bytes: ($s.localBytes // 0), need_files: (($s.needFiles // 0) + ($s.needDirectories // 0) + ($s.needSymlinks // 0) + ($s.needDeletes // 0)),
            need_bytes: ($s.needBytes // 0), in_sync_bytes: ($s.inSyncBytes // 0), pull_errors: ($s.pullErrors // 0), errors_count: ($s.errors // 0),
            ro_changed: (($s.receiveOnlyChangedFiles // 0) + ($s.receiveOnlyChangedDirectories // 0) + ($s.receiveOnlyChangedDeletes // 0)),
            last_scan: (($fstats[$id].lastScan // null) | ts | if . < 100000 then null else . end),
            last_file: ($fstats[$id].lastFile // null | if . then {name: .filename, at: (.at | ts), deleted} else null end),
            ignores: $x.ignores, failing: ($x.errors | map({path, error}) | .[0:50])}],
       pending_folders: [$pfold | to_entries[] | .key as $fid | select($c.folders | map(.id) | index($fid) | not)
         | {id: $fid, label: ([.value.offeredBy[].label] | map(select(. != null and . != "")) | .[0] // $fid),
            by: [.value.offeredBy | to_entries[] | {id: .key, name: ($names[.key] // .key[0:7]), at: (.value.time | ts)}]}],
       ignored_devices: [($c.remoteIgnoredDevices // [])[] | {id: .deviceID, name: (.name // "")}],
       errors: [($errs.errors // [])[-10:][] | {at: (.when | ts), message: .message}]}' \
    --argjson sys "$sys" --argjson cfg "$cfg" --argjson conns "$conns" --argjson dstats "$dstats" --argjson fstats "$fstats" \
    --argjson pdev "$pdev" --argjson pfold "$pfold" --argjson errs "$errs" --argjson f "$folders" --argjson comps "$comps" --argjson prev "$prev" \
    > "$VAR/st.json.tmp" 2>>"$LOG" && mv "$VAR/st.json.tmp" "$VAR/st.json" || { rm -f "$VAR/st.json.tmp"; return 1; }
  track_out_of_sync
}
track_out_of_sync() {   # since when each folder has been out of sync → $VAR/outsync.json; a notification after 30 minutes
  local o; o=$(cat "$VAR/outsync.json" 2>/dev/null || echo '{}'); jq -e . <<< "$o" >/dev/null 2>&1 || o='{}'
  jq -c --argjson o "$o" --argjson now "$(now)" '
    . as $st | [$st.folders[] | select(.paused | not)
      | (.devices as $ds | [$st.devices[] | select(.id as $i | $ds | index($i)) | select(.connected)] | length > 0) as $peer
      | select(.state == "error" or .pull_errors > 0 or (.need_files > 0 and $peer and (.state == "idle" or .state == "syncing" or .state == "sync-preparing" or .state == "sync-waiting")))
      | {key: .id, value: ($o[.id] // $now)}] | from_entries' "$VAR/st.json" > "$VAR/outsync.json.tmp" 2>/dev/null && mv "$VAR/outsync.json.tmp" "$VAR/outsync.json"
  jq -r --argjson now "$(now)" --slurpfile o "$VAR/outsync.json" '.folders[] | select(($o[0][.id] // $now) <= $now - 1800) | .label // .id' "$VAR/st.json" 2>/dev/null \
    | while IFS= read -r l; do notify outofsync 12 "$l"; done
  true
}
notify_pairing() {   # a device asking to pair, the first time it asks
  jq -r '.pending_devices[] | [.id, (if .name == "" then "A device" else .name end)] | @tsv' "$VAR/st.json" 2>/dev/null | while IFS=$'\t' read -r id name; do
    [[ -f "$VAR/notified/pair-$id" ]] && continue; mkdir -p "$VAR/notified"; touch "$VAR/notified/pair-$id"
    notify pairing 8760 "$name" "${id:0:7}"
  done; true
}
app_status() {
  if (( FORCE_COLLECT )) || ! fresh "$VAR/st.json" 6; then collect >/dev/null 2>&1 || true; FORCE_COLLECT=0; fi
  local st qr="" myid
  st=$(cat "$VAR/st.json" 2>/dev/null); jq -e . <<< "$st" >/dev/null 2>&1 || st='{"up": false}'
  myid=$(jq -r '.my_id // empty' <<< "$st")
  if [[ "$myid" =~ $DEV_RE ]]; then
    [[ -s "$VAR/qr-$myid.b64" ]] || { rm -f "$VAR"/qr-*.b64; qr_png_b64 "$myid" > "$VAR/qr-$myid.b64"; }
    qr=$(cat "$VAR/qr-$myid.b64" 2>/dev/null)
  fi
  jq -c --arg qr "$qr" --arg url "$(env_get APP_URL)" --arg image "$(env_get ST_IMAGE)" --arg net "$(env_get NET_MODE)" --arg privacy "$(env_get PRIVACY)" \
     --arg sync_port "$(env_get SYNC_PORT)" --arg lan_ip "$(env_get LAN_IP)" --argjson places "$(places_json)" \
     --argjson access "$(cat "$VAR/access.json" 2>/dev/null || echo '{}')" --argjson shares "$(cat "$VAR/shares.json" 2>/dev/null || echo '{"shares":[]}')" \
     --argjson conflicts "$(jq -c '{count, at}' "$VAR/conflicts.json" 2>/dev/null || echo '{"count":0}')" \
     --argjson outsync "$(cat "$VAR/outsync.json" 2>/dev/null || echo '{}')" --argjson pw "$([[ -f "$VAR/admin-pw.json" ]] && echo true || echo false)" \
     --argjson test "$(test_shares >/dev/null && echo true || echo false)" '
    def place($p): ([$places[] | select(.path as $r | $p == $r or ($p | startswith($r + "/")))] | .[0]);
    . + {qr: $qr, url: $url, image: $image, net: $net, sync_port: ($sync_port | tonumber? // 22000), lan_ip: $lan_ip, pw_kept: $pw, test_shares: $test,
         privacy: (if (.options // null) == null then $privacy elif (.options.globalAnnounceEnabled or .options.relaysEnabled) then "anywhere" else "local" end),
         places: $places, shares: ($shares.shares // []), shares_at: ($shares.at // null), conflicts: $conflicts,
         folders: [(.folders // [])[] | . + {access: ($access[.path] // "unknown"), out_since: ($outsync[.id] // null),
           place: (place(.path) as $pl | if $pl == null then "outside" elif $pl.there then "there" else "waiting" end)}]}' <<< "$st" 2>/dev/null || echo '{"up": false}'
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set ST_IMAGE "$ST_PINNED"
  env_set ST_APIKEY "$(rand 40)"
  env_set NET_MODE "${NET_MODE:-host}"   # new installs: the NAS's own network, so local discovery works
  env_set SYNC_PORT "${SYNC_PORT:-22000}"
  env_set PRIVACY "${PRIVACY:-anywhere}"
  [[ -n "${TEST_SHARES:-}" ]] && ! is_synology && env_set TEST_SHARES "$TEST_SHARES"
  touch "$VAR/.needs-setup"
}
app_load_env() {
  st_load
  [[ -n "$(env_get NET_MODE)" ]] || env_set NET_MODE host
  [[ -n "$(env_get SYNC_PORT)" ]] || env_set SYNC_PORT 22000
  [[ -n "$(env_get PRIVACY)" ]] || env_set PRIVACY anywhere
  [[ -n "$(env_get ST_APIKEY)" ]] || { env_set ST_APIKEY "$(rand 40)"; st_load; }
  # A newer package brings a newer tested Syncthing: move the pin forward (never back), with a backup first.
  local cur pin=${ST_PINNED##*:}
  cur=$(st_tag)
  if [[ -n "$cur" ]] && newer "$pin" "$cur"; then
    say "this package brings Syncthing $pin (installed: $cur) — a backup first"
    if make_backup pre-update; then record_backup true "$MADE"; env_set ST_IMAGE "$ST_PINNED"; say "Syncthing moves to $pin; the state from before is in $MADE"
    else say "✗ couldn't back up first, so Syncthing stays at $cur for now"; fi
  fi
  return 0
}
app_before_up() {
  local who p
  mkdir -p "$APP/no-folder"; mount_srcs || true
  # Stop with one sentence rather than letting Docker (or Syncthing) fail on a port someone else has.
  p=$(env_get SYNC_PORT)
  [[ "$p" != "$(env_get HTTP_PORT)" ]] || failed "The sync port and the web port are both $p. Install again with two different ports."
  who=$(port_taken "$p" tcp); [[ -z "$who" ]] || failed "The sync port $p is already in use on this Synology ($who) — another Syncthing? Free it, or install again with another port, then Package Center → $PKG_TITLE → Run."
  who=$(port_taken "$(env_get HTTP_PORT)" tcp); [[ -z "$who" ]] || failed "The web port $(env_get HTTP_PORT) is already in use on this Synology ($who). Free it, then Package Center → $PKG_TITLE → Run."
  if [[ "$(env_get NET_MODE)" == host ]]; then who=$(port_taken 21027 udp); [[ -z "$who" ]] || say "local discovery's port 21027/udp is in use ($who): devices on your network may not find this Synology by themselves — add it by address there"; fi
}
app_after_up() {
  st_load
  st_wait 120 || { say "Syncthing isn't answering yet — it's set up when it does"; return 0; }
  first_setup
  converge || true
  return 0
}
first_setup() {   # the first time: device name, GUI password (shown once), DSM ignore patterns as the default, privacy
  [[ -f "$VAR/.needs-setup" ]] || return 0
  local pw name mode myid
  myid=$(my_id) || { say "Syncthing's device ID isn't known yet — set up shortly"; return 0; }
  name=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-' | head -c 60); name=${name:-Synology}
  st PATCH "config/devices/$myid" "$(jq -nc --arg n "$name" '{name: $n}')" >/dev/null || say "✗ the device name wasn't set: $(st_why)"
  st PUT config/defaults/ignores "$(jq -Rsc 'split("\n") | map(select(length > 0)) | {lines: .}' <<< "$DSM_IGNORES")" >/dev/null || say "✗ the default ignore patterns weren't set: $(st_why)"
  mode=$(env_get PRIVACY)
  st PATCH config/options "$(privacy_opts "$mode")" >/dev/null || say "✗ the privacy setting didn't apply: $(st_why)"
  pw=$(strong_password)
  st PATCH config/gui "$(jq -nc --arg p "$pw" '{user: "admin", password: $p}')" >/dev/null || { say "✗ Syncthing's GUI password couldn't be set: $(st_why) — trying again shortly"; return 0; }
  leave_secret "Syncthing's web interface (user admin)" "$pw" privacy; keep_pw "$pw"
  rm -f "$VAR/.needs-setup"
  say "first start: this Synology is \"$name\" (device $myid) in Syncthing; its GUI password was set (shown once in the window); $([[ "$mode" == local ]] && echo "local network only" || echo "it may sync over the internet")"
}
keep_pw() {   # password — kept for "Show password": in the package's own folder, readable only by the package (DSM administrators)
  jq -n -c --arg p "$1" --argjson at "$(now)" '{password: $p, at: $at}' > "$VAR/admin-pw.json.tmp" && for_window "$VAR/admin-pw.json"
}
after_restore() {   # the restored settings, with what belongs to this install put back on top
  [[ -f "$VAR/.restored" ]] || return 0
  st_up || return 0
  local pw; pw=$(jq -r '.password // empty' "$VAR/admin-pw.json" 2>/dev/null)
  [[ -n "$pw" ]] && st PATCH config/gui "$(jq -nc --arg p "$pw" '{user: "admin", password: $p}')" >/dev/null && say "after the restore: the GUI password is the one the window shows again"
  converge || true
  places_ensure && { say "after the restore: Syncthing restarts with the restored folders' shared folders mounted"; restart_for_folders || true; }
  rm -f "$VAR/.restored" "$VAR/.my-id"; folders_access; FORCE_COLLECT=1
}

# The core's update_app pulls whatever the compose file names and then prunes every dangling image on
# the host. Here: back up, pull the newer release found by st_check_image (never a value from a request),
# restart, and remove only the old Syncthing image, by name.
st_check_image() {
  local tags latest cur avail=false
  cur=$(st_tag)
  tags=$(curl -fsS --max-time 20 "https://hub.docker.com/v2/repositories/$ST_REPO/tags?page_size=100&ordering=last_updated" 2>/dev/null | jq -r '.results[].name' 2>/dev/null)
  latest=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' <<< "$tags" | sort -V | tail -n 1)
  if [[ -z "$latest" ]]; then IMAGE_UPDATE='{"error":"Docker Hub could not be reached"}'; return 0; fi
  [[ -n "$cur" ]] && newer "$latest" "$cur" && avail=true
  IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get ST_IMAGE)" --arg cur "$cur" --arg latest "$latest" --argjson avail "$avail" \
    '{checked: $at, image: $img, available: $avail, current: $cur, latest: $latest, remote: $latest, local: $cur, page: ("https://github.com/syncthing/syncthing/releases/tag/v" + $latest)}')
  say "Syncthing: newest release $latest, this is $cur$([[ "$avail" == true ]] && echo " — an update is available")"
}
app_check_updates() { st_check_image; }
update_app() {
  local cur latest old img
  cur=$(st_tag); latest=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  if ! [[ -n "$cur" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! newer "$latest" "$cur" || ! jq -e '.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1; then
    MSG="There's no newer Syncthing to install — look for updates first."; return 1; fi
  old=$(env_get ST_IMAGE); img="$ST_REPO:$latest"
  say "updating Syncthing $cur → $latest — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so Syncthing wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling $img"
  docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
  docker image inspect "$img" >/dev/null 2>&1 || { MSG="Syncthing $latest couldn't be downloaded; it stays at $cur."; return 1; }
  env_set ST_IMAGE "$img"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="Syncthing $latest didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 600 || { MSG="Syncthing $latest hasn't answered yet — see the log. The state from before is in $MADE."; return 1; }
  [[ "$old" != "$img" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old" || true; }
  st_check_image
  MSG="Syncthing is updated to $(app_version). The state from before is in $MADE."
}

app_tick() {
  svc_up server || return 0
  st_up || return 0
  first_setup; after_restore
  events_poll
  if (( FORCE_COLLECT )) || ! fresh "$VAR/st.json" 50; then collect >/dev/null 2>&1 || true; FORCE_COLLECT=0; fi
  notify_pairing
  # Shared folders that came or went, folders added in Syncthing's own GUI or by a restore: places follow.
  if ! fresh "$VAR/.places-check" 600; then touch "$VAR/.places-check"
    if places_ensure; then say "a synced shared folder came or went — Syncthing restarts with what's there"; restart_for_folders || true; fi
    folders_access
  fi
  local every=900; fresh "$VAR/watching" 30 && every=120
  if [[ -f "$VAR/.conflicts-due" ]] || ! fresh "$VAR/conflicts.json" "$every"; then rm -f "$VAR/.conflicts-due"; conflicts_scan || true; fi
  if fresh "$VAR/watching" 30 && ! fresh "$VAR/shares.json" 600; then shares_scan || true; fi
  return 0
}

# ------------------------------------------------------------ settings, storage, backups, report
app_settings() {   # NET_MODE from the Site address tab; the core restarts Syncthing after
  if [[ -n "${NET_MODE:-}" && "$NET_MODE" != "$(env_get NET_MODE)" ]]; then
    say "network: $(env_get NET_MODE) → $NET_MODE"; env_set NET_MODE "$NET_MODE"; return 0; fi
  return 1
}
app_after_settings() { st_load; converge || true; }
app_extra_ports() {   # syncing and local discovery, beside the web interface, in DSM's firewall list
  printf '[%s_sync]\ntitle="%s: syncing"\ndesc="%s"\nport_forward="yes"\ndst.ports="%s/tcp,udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get SYNC_PORT)"
  printf '[%s_discovery]\ntitle="%s: local discovery"\ndesc="%s"\nport_forward="no"\ndst.ports="21027/udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE"
}
app_logs() { :; }
app_storage() {
  in_volume config ro -- 'cd /vol/config 2>/dev/null || exit 0; printf "index\t%s\n" "$(du -sm index-v2 2>/dev/null | cut -f1)"; printf "versions\t0\n"; true' </dev/null 2>/dev/null \
    | jq -R -s -c --slurpfile st <(cat "$VAR/st.json" 2>/dev/null || echo '{}') 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries
      | . + {folders: [($st[0].folders // [])[] | {label: (.label // .id), path, bytes: .local_bytes, files: .local_files}]}' 2>/dev/null || echo "{}"
}
# Syncthing's settings and identity: config.xml, the device certificate and key (cert.pem, key.pem: this
# Synology's device ID) and the GUI's own certificate. Read from the live volume: Syncthing writes config.xml
# whole and renames it into place, and the keys never change, so the copy is consistent with Syncthing running.
# Its index (index-v2, a database) is left out: it's rebuilt from the files after a restore.
app_backup() {
  in_volume config ro -- 'cd /vol/config && tar -czf - $(ls config.xml cert.pem key.pem https-cert.pem https-key.pem 2>/dev/null)' > "$1/config.tar.gz" 2>>"$LOG" </dev/null \
    && grep -qx 'key.pem' < <(tar -tzf "$1/config.tar.gz" 2>/dev/null) && grep -qx 'config.xml' < <(tar -tzf "$1/config.tar.gz" 2>/dev/null) \
    || { say "✗ Syncthing's settings and keys didn't copy"; return 1; }
  my_id > "$1/device-id" 2>/dev/null || true
}
app_restore() {   # dir — the core has stopped the containers; the index is emptied so Syncthing reads the folders again
  [[ -s "$1/config.tar.gz" ]] || { MSG="That backup has no Syncthing settings in it."; return 1; }
  in_volume config rw -- "mkdir -p /vol/config && find /vol/config -mindepth 1 -delete && tar -C /vol/config -xzf - && chown -R $HOST_UID:$HOST_GID /vol && chmod 700 /vol/config" \
    < "$1/config.tar.gz" 2>>"$LOG" || { MSG="Syncthing's settings didn't unpack."; return 1; }
  rm -f "$VAR/.my-id" "$VAR/.ev-since" "$VAR/st.json" "$VAR/.needs-setup"; touch "$VAR/.restored" "$VAR/.conflicts-due"
  [[ -s "$1/device-id" ]] && say "restored the identity of device $(cut -c1-7 "$1/device-id")…"
  return 0
}
app_report() {
  local st; st=$(cat "$VAR/st.json" 2>/dev/null || echo '{}')
  echo "== Syncthing $(st GET system/version | jq -r '.longVersion // "?"' 2>/dev/null); API key works: $(st GET system/ping >/dev/null && echo yes || echo "no ($ST_CODE)")"
  echo "== network: $(env_get NET_MODE); sync port $(env_get SYNC_PORT); privacy $(env_get PRIVACY); options: $(jq -c '.options' <<< "$st" 2>/dev/null)"
  echo "== listeners"; jq -r '.listeners[]? | "   \(.address)  \(.error // "ok")"' <<< "$st" 2>/dev/null
  echo "== discovery"; jq -r '.discovery[]? | "   \(.name)  \(.error // "ok")"' <<< "$st" 2>/dev/null
  echo "== devices"; jq -r '.devices[]? | "   \(.id[0:7])  connected \(.connected) \(.conn_type) paused \(.paused)  completion \(.completion // "?")"' <<< "$st" 2>/dev/null
  echo "== pending devices: $(jq -r '.pending_devices | length' <<< "$st" 2>/dev/null); pending folders: $(jq -r '.pending_folders | length' <<< "$st" 2>/dev/null)"
  echo "== folders"; jq -r '.folders[]? | "   \(.id)  \(.type)  \(.state)  need \(.need_files)  pull errors \(.pull_errors)  \(.error)"' <<< "$st" 2>/dev/null
  echo "== places"; places_json | jq -r '.[] | "   \(.place)  \(.path)  \(if .there then "mounted" else "MISSING" end)"'
  echo "== access as the package's user ($HOST_UID:$HOST_GID)"; jq -r 'to_entries[] | "   \(.value)  \(.key)"' "$VAR/access.json" 2>/dev/null
  echo "== conflicts: $(jq -r '.count // 0' "$VAR/conflicts.json" 2>/dev/null)"
  echo "== Syncthing's errors"; jq -r '.errors[]? | "   \(.message)"' <<< "$st" 2>/dev/null
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local id name addr label path fid body cfg devs vers ign pw f
  case "$1" in
    devaccept|devadd)
      id=$DEV_ID; name=$(b64d "${DEV_NAME_B64:-}"); text_ok "$name" 60 || { MSG="A device's name: up to 60 characters."; return 1; }
      [[ "$id" == "$(my_id)" ]] && { MSG="That's this Synology's own device ID."; return 1; }
      st GET "config/devices/$id" >/dev/null && { MSG="$name is already one of the devices."; return 1; }
      addr=dynamic
      if [[ "$1" == devadd && -n "${DEV_ADDR_B64:-}" ]]; then addr=$(b64d "$DEV_ADDR_B64")
        [[ "$addr" =~ ^(dynamic|(tcp|quic)[46]?://[A-Za-z0-9.-]+(:[0-9]{1,5})?|(tcp|quic)[46]?://\[[0-9A-Fa-f:]+\](:[0-9]{1,5})?)$ ]] || { MSG="An address looks like tcp://192.168.1.30:22000, or dynamic."; return 1; }; fi
      if [[ "$1" == devaccept ]]; then st GET cluster/pending/devices | jq -e --arg id "$id" 'has($id)' >/dev/null 2>&1 || { MSG="That device isn't asking any more."; return 1; }; fi
      body=$(jq -nc --arg id "$id" --arg n "$name" --arg a "$addr" '{deviceID: $id, name: $n, addresses: ($a | split(",")), autoAcceptFolders: false}')
      st POST config/devices "$body" >/dev/null || { MSG="Syncthing didn't add it. $(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG="$name is paired. Share folders with it on the Folders tab$([[ "$1" == devadd ]] && echo "; it connects once this Synology is added on that device too")." ;;
    devignore)
      cfg=$(st GET config) || { MSG=$(st_why); return 1; }
      name=$(st GET cluster/pending/devices | jq -r --arg id "$DEV_ID" '.[$id].name // ""' 2>/dev/null)
      body=$(jq -c --arg id "$DEV_ID" --arg n "$name" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.remoteIgnoredDevices = ((.remoteIgnoredDevices // []) + [{deviceID: $id, name: $n, address: "", time: $t}] | unique_by(.deviceID))' <<< "$cfg")
      st PUT config "$body" >/dev/null || { MSG="Syncthing didn't take it. $(st_why)"; return 1; }
      st DELETE "cluster/pending/devices?device=$DEV_ID" >/dev/null || true
      FORCE_COLLECT=1; MSG="${name:-That device} is ignored: it isn't shown again when it asks." ;;
    devpause)
      st PATCH "config/devices/$DEV_ID" "$(jq -nc --argjson p "$([[ "$PAUSE" == 1 ]] && echo true || echo false)" '{paused: $p}')" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG=$([[ "$PAUSE" == 1 ]] && echo "Paused: nothing syncs with that device until it's resumed." || echo "Resumed.") ;;
    devremove)
      st GET "config/devices/$DEV_ID" >/dev/null || { MSG="There's no such device."; return 1; }
      [[ "$DEV_ID" == "$(my_id)" ]] && { MSG="That's this Synology."; return 1; }
      st DELETE "config/devices/$DEV_ID" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG="The device was removed. Files it synced stay where they are." ;;
    devrename)
      name=$(b64d "${DEV_NAME_B64:-}"); text_ok "$name" 60 || { MSG="A device's name: up to 60 characters."; return 1; }
      st PATCH "config/devices/$DEV_ID" "$(jq -nc --arg n "$name" '{name: $n}')" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG="Renamed to $name." ;;
    folderadd|folderaccept)
      label=$(b64d "${FLABEL_B64:-}"); path=$(b64d "${FPATH_B64:-}")
      text_ok "$label" 100 || { MSG="A folder's name: up to 100 characters."; return 1; }
      get_devs || return 1; devs=$DEVS
      if [[ "$1" == folderaccept ]]; then fid=$(b64d "${FID_B64:-}"); text_ok "$fid" 255 || { MSG="That isn't a folder ID."; return 1; }
        st GET cluster/pending/folders | jq -e --arg f "$fid" --arg d "$DEV_ID" '.[$f].offeredBy | has($d)' >/dev/null 2>&1 || { MSG="That folder isn't offered any more."; return 1; }
        st GET "config/folders/$(uri "$fid")" >/dev/null && { MSG="That folder is already synced here."; return 1; }
        devs=$(jq -c --arg d "$DEV_ID" '. + [$d] | unique' <<< "$devs")
      else fid=$(new_folder_id); fi
      ign=""; [[ -n "${IGN_B64:-}" ]] && { ign=$(ignores_lines "$IGN_B64"); ignores_ok "$ign" || { MSG="Ignore patterns: one per line, up to 300 characters each."; return 1; }; }
      vers=$(versioning_json "${VTYPE:-none}" "${VKEEP:-5}" "${VDAYS:-30}")
      add_folder "$fid" "$label" "$path" "${FTYPE:-sendreceive}" "$devs" "$vers" "$ign" || return 1 ;;
    folderdecline)
      fid=$(b64d "${FID_B64:-}"); text_ok "$fid" 255 || { MSG="That isn't a folder ID."; return 1; }
      f=$(st GET "config/devices/$DEV_ID") || { MSG="That device isn't paired."; return 1; }
      label=$(st GET cluster/pending/folders | jq -r --arg f "$fid" --arg d "$DEV_ID" '.[$f].offeredBy[$d].label // ""' 2>/dev/null)
      body=$(jq -c --arg f "$fid" --arg l "$label" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{ignoredFolders: ((.ignoredFolders // []) + [{id: $f, label: $l, time: $t}] | unique_by(.id))}' <<< "$f")
      st PATCH "config/devices/$DEV_ID" "$body" >/dev/null || { MSG="$(st_why)"; return 1; }
      st DELETE "cluster/pending/folders?folder=$(uri "$fid")&device=$DEV_ID" >/dev/null || true
      FORCE_COLLECT=1; MSG="${label:-That folder} is declined: it isn't offered here again." ;;
    folderedit)
      get_fid || return 1; fid=$FID; label=$(b64d "${FLABEL_B64:-}"); text_ok "$label" 100 || { MSG="A folder's name: up to 100 characters."; return 1; }
      get_devs || return 1; devs=$DEVS
      st PATCH "config/folders/$(uri "$fid")" "$(jq -nc --arg l "$label" --arg t "$FTYPE" --argjson d "$devs" '{label: $l, type: $t, devices: ($d | map({deviceID: .}))}')" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG="$label is saved." ;;
    folderversions)
      get_fid || return 1; fid=$FID
      st PATCH "config/folders/$(uri "$fid")" "$(jq -nc --argjson v "$(versioning_json "$VTYPE" "${VKEEP:-5}" "${VDAYS:-30}")" '{versioning: $v}')" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG=$(case "$VTYPE" in none) echo "File versioning is off for that folder." ;; trashcan) echo "Files changed or deleted by other devices go to .stversions in the folder$( (( 10#${VDAYS:-0} > 0 )) && echo " for ${VDAYS} days")." ;; simple) echo "The last ${VKEEP} versions of each file are kept in .stversions in the folder." ;; *) echo "Older versions are kept in .stversions, thinning out over time, for up to ${VDAYS} days." ;; esac) ;;
    folderignores)
      get_fid || return 1; fid=$FID; ign=$(ignores_lines "${IGN_B64:-}"); ignores_ok "$ign" || { MSG="Ignore patterns: one per line, up to 300 characters each."; return 1; }
      set_ignores "$fid" "$ign" || { MSG="Syncthing didn't take the patterns. $(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG="Ignore patterns saved ($(grep -c . <<< "$ign" || true) lines); Syncthing reads the folder again with them." ;;
    folderscan)
      get_fid || return 1; fid=$FID; st POST "db/scan?folder=$(uri "$fid")" >/dev/null || { MSG="$(st_why)"; return 1; }
      touch "$VAR/.conflicts-due"; FORCE_COLLECT=1; MSG="Syncthing is reading the folder again." ;;
    folderpause)
      get_fid || return 1; fid=$FID
      st PATCH "config/folders/$(uri "$fid")" "$(jq -nc --argjson p "$([[ "$PAUSE" == 1 ]] && echo true || echo false)" '{paused: $p}')" >/dev/null || { MSG="$(st_why)"; return 1; }
      FORCE_COLLECT=1; MSG=$([[ "$PAUSE" == 1 ]] && echo "Paused." || echo "Resumed.") ;;
    folderoverride|folderrevert)
      get_fid || return 1; fid=$FID; f=$(folder_json "$fid")
      if [[ "$1" == folderoverride ]]; then [[ "$(jq -r .type <<< "$f")" == sendonly ]] || { MSG="Override is for send-only folders."; return 1; }
        st POST "db/override?folder=$(uri "$fid")" >/dev/null || { MSG="$(st_why)"; return 1; }; MSG="This Synology's version of the folder is sent to the other devices, over their changes."
      else [[ "$(jq -r .type <<< "$f")" == receiveonly ]] || { MSG="Revert is for receive-only folders."; return 1; }
        st POST "db/revert?folder=$(uri "$fid")" >/dev/null || { MSG="$(st_why)"; return 1; }; MSG="Local changes are undone: the folder goes back to what the other devices have."; fi
      FORCE_COLLECT=1 ;;
    folderremove)
      get_fid || return 1; fid=$FID; label=$(folder_json "$fid" | jq -r '.label // .id')
      st DELETE "config/folders/$(uri "$fid")" >/dev/null || { MSG="$(st_why)"; return 1; }
      MSG="$label isn't synced any more. Its files are untouched."
      if places_ensure; then restart_for_folders || MSG="$MSG Syncthing didn't come back after unmounting its shared folder — see the log."; fi
      folders_access; FORCE_COLLECT=1 ;;
    conflictkeep|conflictdrop)
      conflict_check "$(b64d "${CONFLICT_B64:-}")" || return 1
      if [[ "$1" == conflictkeep ]]; then as_st_user mv -f "$C_FILE" "$C_ORIG" || { MSG="The conflict copy couldn't replace the original (permissions?) — see the log."; return 1; }
        MSG="Kept that version: it's now $(basename "$C_ORIG"), and syncs to the other devices."
      else as_st_user rm -f "$C_FILE" || { MSG="The conflict copy couldn't be deleted (permissions?) — see the log."; return 1; }
        MSG="Kept the original; the conflict copy is deleted."; fi
      st POST "db/scan?folder=$(uri "$C_FID")&sub=$(uri "$(dirname "$C_REL" | sed 's|^\.$||')")" >/dev/null || true
      conflicts_scan || true ;;
    conflictscan) conflicts_scan || { MSG="Couldn't look for conflicts: $(st_why)"; return 1; }; MSG="Looked for conflicts: $(jq -r .count "$VAR/conflicts.json")." ;;
    sharescan) shares_scan; folders_access; FORCE_COLLECT=1; MSG="Shared folders checked." ;;
    privacy)
      env_set PRIVACY "$PRIVACY"
      body=$(jq -nc --argjson o "$(privacy_opts "$PRIVACY")" --argjson s "$(( 10#${MAX_SEND:-0} ))" --argjson r "$(( 10#${MAX_RECV:-0} ))" --argjson l "$([[ "${LAN_LIMIT:-0}" == 1 ]] && echo true || echo false)" \
        '$o + {maxSendKbps: $s, maxRecvKbps: $r, limitBandwidthInLan: $l}')
      st PATCH config/options "$body" >/dev/null || { MSG="Syncthing didn't take it. $(st_why)"; return 1; }
      FORCE_COLLECT=1
      MSG=$([[ "$PRIVACY" == local ]] && echo "Local network only: no global discovery, relays or NAT traversal. Devices away from home can't reach this Synology." || echo "Anywhere: devices find and reach this Synology over the internet too (global discovery, relays, NAT traversal).") ;;
    syncport)
      [[ "$SYNC_PORT" == "$(env_get SYNC_PORT)" ]] && { MSG="That's the port already."; return 0; }
      [[ "$SYNC_PORT" == "$(env_get HTTP_PORT)" ]] && { MSG="That's the web port."; return 1; }
      f=$(ss -lntuH 2>/dev/null | awk -v p="$SYNC_PORT" '{ n = split($5, a, ":"); if (a[n] == p) { print $5; exit } }')
      [[ -z "$f" ]] || { MSG="Port $SYNC_PORT is in use on this Synology ($f)."; return 1; }
      env_set SYNC_PORT "$SYNC_PORT"; converge || true
      compose up -d 2>&1 | tee -a "$LOG" >/dev/null && wait_ready 180 || { MSG="Syncthing didn't come back on the new port — see the log."; return 1; }
      converge || true; sync_dsm; FORCE_COLLECT=1
      MSG="Syncthing syncs on port $SYNC_PORT (TCP and UDP) now. Forward that port in your router instead of the old one, if you forwarded it." ;;
    newpw)
      pw=$(strong_password)
      st PATCH config/gui "$(jq -nc --arg p "$pw" '{user: "admin", password: $p}')" >/dev/null || { MSG="The password wasn't changed. $(st_why)"; return 1; }
      leave_secret "Syncthing's web interface (user admin)" "$pw" privacy; keep_pw "$pw"; MSG="Your new password is shown below, once — and under Show password." ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
  return 0   # every failure above returns 1 itself
}
get_fid() { FID=$(b64d "${FID_B64:-}"); text_ok "$FID" 255 && st GET "config/folders/$(uri "$FID")" >/dev/null || { MSG="There's no such folder."; return 1; }; }
get_devs() {   # FDEVICES → DEVS, a JSON list of paired device IDs (unknown ones refused)
  local d known; known=$(st GET config/devices | jq -r '.[].deviceID' 2>/dev/null); DEVS="[]"
  [[ "${FDEVICES:-none}" == none ]] && return 0
  local IFS=+
  for d in $FDEVICES; do grep -qx "$d" <<< "$known" || { MSG="One of the ticked devices isn't paired."; return 1; }; DEVS=$(jq -c --arg d "$d" '. + [$d]' <<< "$DEVS"); done
}
