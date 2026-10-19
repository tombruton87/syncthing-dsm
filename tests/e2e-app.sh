# Syncthing's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act), in two parts
# (E2E_PART=1, then E2E_PART=2) so each run stays short. "Alice's laptop" is a second, throwaway Syncthing
# container on Docker's network that pairs with the package's Syncthing (on the host's network, as on a NAS)
# through Docker's gateway address. Shared folders are directories under $E2E/shares (TEST_SHARES).
SHARES=$E2E/shares; ALICE=syncthing-e2e-alice; BOB=syncthing-e2e-bob; ST_IMG=syncthing/syncthing:2.1.6
app_e2e_answers() {   # a fresh start: the test's shared folders and Alice's files from scratch
  docker rm -f "$ALICE" "$BOB" >/dev/null 2>&1; docker run --rm -v "$E2E:/e" alpine rm -rf /e/shares /e/alice /e/.alice /e/.docs /e/.pw
  mkdir -p "$SHARES/docs" "$SHARES/inbox" "$SHARES/photos" "$E2E/alice/docs" "$E2E/alice/photos" "$E2E/alice/music"
  # A shared folder the package's user may read but not write: root's, mode 755.
  docker run --rm -v "$SHARES:/s" alpine sh -c 'mkdir -p /s/locked && echo hello > /s/locked/readme.txt && chown -R 0:0 /s/locked && chmod 755 /s/locked' >/dev/null
  printf "SYNC_PORT='22000'\nPRIVACY='local'\nNET_MODE='host'\nTEST_SHARES='%s'\n" "$SHARES"
}
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
until_true() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; eval "$1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "privacy") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
key() { docker run --rm -v "$APP:/s" alpine sh -c 'grep "^ST_APIKEY=" /s/.env | cut -d= -f2-'; }
napi() { curl -s -X "$1" "http://127.0.0.1:$PORT/rest/$2" -H "X-API-Key: $NKEY" ${3:+-d "$3"}; }   # the package's Syncthing
aip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
aapi() { curl -s -X "$1" "http://$(aip "${PEER:-$ALICE}"):8384/rest/$2" -H "X-API-Key: e2e-peer-key" ${3:+-d "$3"}; }   # Alice's (or Bob's)
peer_start() {   # name data-dir device-name → a throwaway Syncthing that knows the NAS and dials it through Docker's gateway
  local gw pn=$1; gw=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" -e STGUIAPIKEY=e2e-peer-key -e STNODEFAULTFOLDER=1 -e PUID="$(id -u)" -e PGID="$(id -g)" ${2:+-v "$2:/data"} "$ST_IMG" >/dev/null
  until_true 'PEER=$pn aapi GET system/status | jq -e .myID' 60 || return 1
  local me; me=$(PEER=$1 aapi GET system/status | jq -r .myID)
  PEER=$1 aapi PATCH "config/devices/$me" "$(jq -nc --arg n "$3" '{name: $n}')" >/dev/null
  PEER=$1 aapi PATCH config/options '{"globalAnnounceEnabled": false, "relaysEnabled": false, "natEnabled": false, "localAnnounceEnabled": false, "urAccepted": -1}' >/dev/null
  PEER=$1 aapi POST config/devices "$(jq -nc --arg id "$NID" --arg a "tcp://$gw:22000" '{deviceID: $id, name: "DS920", addresses: [$a]}')" >/dev/null
  echo "$me"
}
afile() { docker exec "$ALICE" cat "/data/$1" 2>/dev/null; }
awrite() { docker exec -u "$(id -u):$(id -g)" "$ALICE" sh -c "mkdir -p \"\$(dirname '/data/$1')\" && printf '%s' '$2' > '/data/$1'"; }
fid_of() { jq -r --arg l "$1" '.app.folders[] | select(.label == $l) | .id' "$VAR/status.json"; }
log_has() { grep -q "$1" "$VAR/package.log"; }

# The core's own steps run with E2E_PART=0 (chassis/tests/e2e.sh . act); the app's parts one at a time with
# tests/e2e-part.sh N, so each run stays well under ten minutes.
app_e2e_act() { [[ "${E2E_PART:-0}" == 0 ]] && return 0; NKEY=$(key); NID=$(jq -r '.app.my_id' "$VAR/status.json")
  log "syncthing, part $E2E_PART"; echo "  (version $(jq -r .version "$VAR/status.json"), device ${NID:0:7}…, network $(jq -r .app.net "$VAR/status.json"))"
  [[ "$E2E_PART" == 1 ]] || { docker ps -q --filter "name=^$ALICE$" | grep -q . || { echo "  FAIL Alice isn't running (part 1 first)"; return 1; }; wait_for '.app.devices | map(select(.connected)) | length >= 1' 120 || echo "  (Alice isn't connected yet)"; }
  "e2e_part$E2E_PART"; }
e2e_part1() {
  local fail=0 pw nid aid did old n cpath
  NKEY=$(key); NID=$(jq -r '.app.my_id' "$VAR/status.json")
  aid=$(cat "$E2E/.alice" 2>/dev/null); did=$(cat "$E2E/.docs" 2>/dev/null); pw=$(cat "$E2E/.pw" 2>/dev/null)
  # ---------------------------------------------------------------- first start
  pw=$(secret); printf '%s' "$pw" > "$E2E/.pw"
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time GUI password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/rest/noauth/auth/password" -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$pw" '{username: "admin", password: $p}')")" == 204 ]] \
    && echo "  ok   it signs in to Syncthing's GUI as admin" || { echo "  FAIL GUI sign-in"; fail=1; }
  [[ "$(jq -r .password "$VAR/admin-pw.json" 2>/dev/null)" == "$pw" ]] && echo "  ok   …and is kept for Show password" || { echo "  FAIL admin-pw.json"; fail=1; }
  [[ "$NID" =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]] && jq -e '.app.qr | length > 200' "$VAR/status.json" >/dev/null && echo "  ok   device ID ${NID:0:7}… with a QR code" || { echo "  FAIL id/qr"; fail=1; }
  [[ "$(napi GET config/gui | jq -r .user)" == admin && "$(napi GET config/gui | jq -r .password)" == \$2* ]] && echo "  ok   GUI user admin, password stored hashed" || { echo "  FAIL gui config"; fail=1; }
  napi GET config/defaults/ignores | jq -e '.lines | index("(?d)@eaDir") and index("(?d)#recycle") and index("(?d).SynologyWorkingDirectory")' >/dev/null && echo "  ok   DSM ignore patterns are Syncthing's defaults for new folders" || { echo "  FAIL default ignores: $(napi GET config/defaults/ignores)"; fail=1; }
  napi GET config/options | jq -e '.globalAnnounceEnabled == false and .relaysEnabled == false and .natEnabled == false and .urAccepted == -1 and (.listenAddresses == ["tcp://0.0.0.0:22000", "quic://0.0.0.0:22000"])' >/dev/null \
    && echo "  ok   local network only from the wizard: no global discovery, relays, NAT traversal or usage reports" || { echo "  FAIL privacy: $(napi GET config/options | jq -c '{globalAnnounceEnabled, relaysEnabled, natEnabled, urAccepted, listenAddresses}')"; fail=1; }
  docker inspect -f '{{.HostConfig.NetworkMode}}' syncthing-server | grep -qx host && echo "  ok   on the host's network (compose.host.yaml)" || { echo "  FAIL network mode"; fail=1; }
  [[ "$(docker exec syncthing-server sh -c 'ps -o user,args | grep "[/]bin/syncthing" | head -1' | awk '{print $1}')" =~ ^($(id -u)|$(id -un))$ ]] && echo "  ok   Syncthing runs as the package's user ($(id -u))" || { echo "  FAIL runs as: $(docker exec syncthing-server ps -o user,args | grep -i '[s]yncthing' | head -2)"; fail=1; }
  wait_for '.app.shares | map(.path) | (index("'"$SHARES"'/docs") != null and index("'"$SHARES"'/locked") != null)' 60 \
    && jq -e '.app.shares | map(select(.path | endswith("/locked")))[0].access == "ro" and (map(select(.path | endswith("/docs")))[0].access == "rw")' "$VAR/status.json" >/dev/null \
    && echo "  ok   shared folders listed, with access: docs rw, locked ro" || { echo "  FAIL shares: $(jq -c .app.shares "$VAR/status.json")"; fail=1; }
  # ---------------------------------------------------------------- Alice asks to pair; accepted from the window
  aid=$(peer_start "$ALICE" "$E2E/alice" "Alice's laptop") || { echo "  FAIL Alice didn't start"; return 1; }; echo "$aid" > "$E2E/.alice"
  wait_for '.app.pending_devices | map(select(.id == "'"$aid"'" and .name == "Alice'"'"'s laptop")) | length == 1' 120 && echo "  ok   Alice's laptop asks to connect (pending, with its name)" || { echo "  FAIL pending: $(jq -c .app.pending_devices "$VAR/status.json")"; fail=1; }
  until_true 'log_has "notification (pairing)\|told DSM: pairing"' 30 && echo "  ok   …and a DSM notification was attempted (pairing)" || { echo "  FAIL no pairing notification"; fail=1; }
  request "ACTION='devaccept'" "DEV_ID='$aid'" "DEV_NAME_B64='$(b64u "Alice's laptop")'" || fail=1
  wait_for '.app.devices | map(select(.id == "'"$aid"'" and .connected)) | length == 1' 120 && echo "  ok   paired and connected ($(jq -r --arg id "$aid" '.app.devices[] | select(.id == $id) | .address' "$VAR/status.json"))" || { echo "  FAIL connect: $(jq -c '.app.devices' "$VAR/status.json")"; fail=1; }
  # ---------------------------------------------------------------- a folder shared both ways
  request "ACTION='folderadd'" "FLABEL_B64='$(b64u Documents)'" "FPATH_B64='$(b64u "$SHARES/docs")'" "FTYPE='sendreceive'" "FDEVICES='$aid'" "VTYPE='simple'" "VKEEP='5'" "VDAYS='0'" "IGN_B64='$(b64u $'(?d)@eaDir\n(?d)#recycle\n(?d).DS_Store')'" || fail=1
  did=$(fid_of Documents); echo "$did" > "$E2E/.docs"
  wait_for '.app.folders[] | select(.label == "Documents") | .place == "there" and .access == "rw" and .state == "idle"' 90 && echo "  ok   Documents: mounted at its own path, writable, idle" || { echo "  FAIL folder: $(jq -c '.app.folders' "$VAR/status.json")"; fail=1; }
  grep -qx '(?d)@eaDir' "$SHARES/docs/.stignore" 2>/dev/null && echo "  ok   …its ignore patterns are in .stignore" || { echo "  FAIL .stignore: $(cat "$SHARES/docs/.stignore" 2>&1)"; fail=1; }
  napi GET "config/folders/$did" | jq -e '.versioning.type == "simple" and .versioning.params.keep == "5" and .fsWatcherEnabled' >/dev/null && echo "  ok   …simple versioning (5), watching for changes" || { echo "  FAIL folder config"; fail=1; }
  until_true "aapi GET cluster/pending/folders | jq -e 'has(\"$did\")'" 60 && aapi POST config/folders "$(jq -nc --arg id "$did" --arg n "$NID" '{id: $id, label: "Documents", path: "/data/docs", devices: [{deviceID: $n}], fsWatcherDelayS: 1}')" >/dev/null \
    && echo "  ok   Alice was offered it and took it" || { echo "  FAIL Alice offer"; fail=1; }
  printf 'from the NAS\n' > "$SHARES/docs/from-nas.txt"; mkdir -p "$SHARES/docs/@eaDir"; echo thumb > "$SHARES/docs/@eaDir/thumb.jpg"; echo junk > "$SHARES/docs/.DS_Store"
  awrite docs/from-alice.txt 'from Alice'
  until_true '[[ "$(afile docs/from-nas.txt)" == "from the NAS" ]]' 120 && echo "  ok   a file made on the NAS appears on Alice's laptop" || { echo "  FAIL NAS → Alice"; fail=1; }
  until_true '[[ "$(cat "$SHARES/docs/from-alice.txt" 2>/dev/null)" == "from Alice" ]]' 120 && echo "  ok   a file made on Alice's laptop appears on the NAS" || { echo "  FAIL Alice → NAS"; fail=1; }
  docker exec "$ALICE" test -e /data/docs/@eaDir || docker exec "$ALICE" test -e /data/docs/.DS_Store && { echo "  FAIL @eaDir or .DS_Store reached Alice"; fail=1; } || echo "  ok   @eaDir and .DS_Store stay on the NAS (ignore patterns)"
  stat -c %u "$SHARES/docs/from-alice.txt" | grep -qx "$(id -u)" && echo "  ok   files Syncthing writes belong to the package's user" || { echo "  FAIL owner $(stat -c %u "$SHARES/docs/from-alice.txt")"; fail=1; }
  # Versioning: Alice changes the NAS's file; the old one is kept in .stversions.
  sleep 2; awrite docs/from-nas.txt 'changed by Alice'
  until_true '[[ "$(cat "$SHARES/docs/from-nas.txt")" == "changed by Alice" ]]' 120 && until_true 'ls "$SHARES/docs/.stversions/" | grep -q "^from-nas~"' 30 \
    && grep -q 'from the NAS' "$SHARES"/docs/.stversions/from-nas~* && echo "  ok   versioning kept the old version: $(ls "$SHARES/docs/.stversions/")" || { echo "  FAIL versioning: $(ls -la "$SHARES/docs/.stversions" 2>&1 | tail -3)"; fail=1; }
  # Activity: what changed, where, by whom.
  until_true 'jq -e "(.items | map(select(.path == \"from-nas.txt\" and .kind == \"local\" and .by == \"this Synology\")) | length > 0) and (.items | map(select(.path == \"from-alice.txt\" and .kind == \"remote\" and .by == \"Alice'"'"'s laptop\" and .label == \"Documents\")) | length > 0)" "$VAR/activity.json"' 60 \
    && echo "  ok   activity: from-nas.txt changed here, from-alice.txt from Alice's laptop ($(jq '.items | length' "$VAR/activity.json") entries)" || { echo "  FAIL activity: $(jq -c '.items[0:4]' "$VAR/activity.json" 2>&1)"; fail=1; }
  echo; return $fail
}
e2e_part2() {
  local fail=0 pw nid aid did old n cpath
  NKEY=$(key); NID=$(jq -r '.app.my_id' "$VAR/status.json")
  aid=$(cat "$E2E/.alice" 2>/dev/null); did=$(cat "$E2E/.docs" 2>/dev/null); pw=$(cat "$E2E/.pw" 2>/dev/null)
  # ---------------------------------------------------------------- a folder offered by Alice, accepted into a shared folder (receive only)
  echo 'a photo' > "$E2E/alice/photos/beach.jpg"
  aapi POST config/folders "$(jq -nc --arg n "$NID" '{id: "alice-photos", label: "Alice Photos", path: "/data/photos", devices: [{deviceID: $n}], fsWatcherDelayS: 1}')" >/dev/null
  wait_for '.app.pending_folders | map(select(.id == "alice-photos" and .label == "Alice Photos")) | length == 1' 90 && echo "  ok   Alice offers \"Alice Photos\"" || { echo "  FAIL pending folder: $(jq -c .app.pending_folders "$VAR/status.json")"; fail=1; }
  request "ACTION='folderaccept'" "FID_B64='$(b64u alice-photos)'" "DEV_ID='$aid'" "FLABEL_B64='$(b64u "Alice Photos")'" "FPATH_B64='$(b64u "$SHARES/inbox/Alice Photos")'" "FTYPE='receiveonly'" "FDEVICES='none'" "VTYPE='trashcan'" "VKEEP='5'" "VDAYS='30'" "IGN_B64='$(b64u '(?d)@eaDir')'" || fail=1
  until_true '[[ "$(cat "$SHARES/inbox/Alice Photos/beach.jpg" 2>/dev/null)" == "a photo" ]]' 120 && echo "  ok   accepted into inbox/Alice Photos (receive only): beach.jpg arrived" || { echo "  FAIL accept: $(ls -la "$SHARES/inbox" 2>&1 | tail -2)"; fail=1; }
  jq -e '[.app.places[].path] | index("'"$SHARES"'/inbox") != null' "$VAR/status.json" >/dev/null && echo "  ok   …the inbox shared folder got a place of its own" || { echo "  FAIL places: $(jq -c .app.places "$VAR/status.json")"; fail=1; }
  # Receive only: a local change shows, and Revert undoes it.
  echo 'mine' > "$SHARES/inbox/Alice Photos/local.txt"
  request "ACTION='folderscan'" "FID_B64='$(b64u alice-photos)'" >/dev/null
  wait_for '.app.folders[] | select(.id == "alice-photos") | .ro_changed > 0' 60 && echo "  ok   a local change in the receive-only folder is shown" || { echo "  FAIL ro_changed: $(jq -c '.app.folders[] | select(.id == "alice-photos") | {state, ro_changed}' "$VAR/status.json")"; fail=1; }
  request "ACTION='folderrevert'" "FID_B64='$(b64u alice-photos)'" || fail=1
  until_true '[[ ! -e "$SHARES/inbox/Alice Photos/local.txt" ]]' 60 && echo "  ok   Revert removed it" || { echo "  FAIL revert"; fail=1; }
  # Declining another offered folder.
  aapi POST config/folders "$(jq -nc --arg n "$NID" '{id: "alice-music", label: "Alice Music", path: "/data/music", devices: [{deviceID: $n}]}')" >/dev/null
  wait_for '.app.pending_folders | map(select(.id == "alice-music")) | length == 1' 90 || true
  request "ACTION='folderdecline'" "FID_B64='$(b64u alice-music)'" "DEV_ID='$aid'" || fail=1
  wait_for '.app.pending_folders | map(select(.id == "alice-music")) | length == 0' 30 && napi GET "config/devices/$aid" | jq -e '.ignoredFolders | map(.id) | index("alice-music")' >/dev/null \
    && echo "  ok   a declined folder isn't offered again" || { echo "  FAIL decline"; fail=1; }
  # ---------------------------------------------------------------- a folder Syncthing can't write: reported with the fix
  request "ACTION='folderadd'" "FLABEL_B64='$(b64u Locked)'" "FPATH_B64='$(b64u "$SHARES/locked")'" "FTYPE='sendreceive'" "FDEVICES='none'" "VTYPE='none'" "VKEEP='5'" "VDAYS='0'" || fail=1
  jq -r '.last.message' "$VAR/status.json" | grep -q 'System internal user' && echo "  ok   adding it says how to fix it: $(jq -r '.last.message' "$VAR/status.json" | cut -c1-110)…" || { echo "  FAIL message: $(jq -r .last.message "$VAR/status.json")"; fail=1; }
  wait_for '.app.folders[] | select(.label == "Locked") | .access == "ro"' 60 && echo "  ok   …and the folder shows Syncthing can only read it" || { echo "  FAIL access: $(jq -c '.app.folders[] | select(.label == "Locked") | {access, state, error}' "$VAR/status.json")"; fail=1; }
  # Out of sync for over 30 minutes → a notification (the clock is wound back).
  n=$(fid_of Locked)
  wait_for '.app.folders[] | select(.label == "Locked") | .out_since != null' 90 || true
  docker run --rm -v "$VAR:/v" alpine sh -c "sed -i 's/\"$n\":[0-9]*/\"$n\":1000/' /v/outsync.json"; touch "$VAR/watching"
  until_true 'log_has "(outofsync)\|told DSM: outofsync"' 90 && echo "  ok   a folder out of sync for over 30 minutes: DSM notification attempted" || { echo "  FAIL outofsync notification ($(cat "$VAR/outsync.json"))"; fail=1; }
  request "ACTION='folderremove'" "FID_B64='$(b64u "$n")'" || fail=1
  [[ -f "$SHARES/locked/readme.txt" ]] && wait_for '([.app.places[].path] | index("'"$SHARES"'/locked")) == null' 30 && echo "  ok   removed: files untouched, its place let go" || { echo "  FAIL remove"; fail=1; }
  echo; return $fail
}
e2e_part3() {
  local fail=0 pw nid aid did old n cpath
  NKEY=$(key); NID=$(jq -r '.app.my_id' "$VAR/status.json")
  aid=$(cat "$E2E/.alice" 2>/dev/null); did=$(cat "$E2E/.docs" 2>/dev/null); pw=$(cat "$E2E/.pw" 2>/dev/null)
  # ---------------------------------------------------------------- conflicts: both sides edit while paused
  for side in keep drop; do
    printf 'base\n' > "$SHARES/docs/c-$side.txt"
    until_true '[[ "$(afile docs/c-$side.txt)" == "base" ]]' 90 || { echo "  FAIL base c-$side"; fail=1; }
    request "ACTION='devpause'" "DEV_ID='$aid'" "PAUSE='1'" >/dev/null || fail=1
    wait_for '.app.devices[] | select(.id == "'"$aid"'") | .connected == false and .paused' 60 || true
    printf 'NAS edit\n' > "$SHARES/docs/c-$side.txt"; request "ACTION='folderscan'" "FID_B64='$(b64u "$did")'" >/dev/null; sleep 3
    awrite "docs/c-$side.txt" 'Alice edit'; PEER=$ALICE aapi POST "db/scan?folder=$did" >/dev/null; sleep 3
    request "ACTION='devpause'" "DEV_ID='$aid'" "PAUSE='0'" >/dev/null || fail=1
  done
  wait_for '.app.conflicts.count >= 2' 240 && echo "  ok   two conflicts found ($(jq -r .app.conflicts.count "$VAR/status.json")), from editing both sides while paused" || { echo "  FAIL conflicts: $(cat "$VAR/conflicts.json" 2>&1 | head -c 300)"; fail=1; }
  jq -e '.conflicts | map(select(.orig_rel == "c-keep.txt" and .label == "Documents" and (.by | length) > 0 and .size > 0)) | length >= 1' "$VAR/conflicts.json" >/dev/null && echo "  ok   …grouped by original, with device, size and date" || { echo "  FAIL conflict details: $(jq -c '.conflicts[0]' "$VAR/conflicts.json")"; fail=1; }
  until_true 'log_has "(conflicts)\|told DSM: conflicts"' 30 && echo "  ok   …and a DSM notification was attempted" || { echo "  FAIL conflicts notification"; fail=1; }
  cpath=$(jq -r '.conflicts[] | select(.orig_rel == "c-keep.txt") | .path' "$VAR/conflicts.json" | head -1); old=$(cat "$cpath" 2>/dev/null)
  request "ACTION='conflictkeep'" "CONFLICT_B64='$(b64u "$cpath")'" || fail=1
  [[ ! -e "$cpath" && "$(cat "$SHARES/docs/c-keep.txt")" == "$old" ]] && echo "  ok   Keep this version: the copy (\"${old}\") replaced the file" || { echo "  FAIL keep"; fail=1; }
  until_true '[[ "$(afile docs/c-keep.txt)" == "$old" ]] && ! docker exec "$ALICE" sh -c "ls /data/docs | grep -q c-keep.sync-conflict"' 120 && echo "  ok   …on Alice's laptop too, and its copy of the conflict file is gone" || { echo "  FAIL keep sync: $(afile docs/c-keep.txt); $(docker exec "$ALICE" ls /data/docs)"; fail=1; }
  cpath=$(jq -r '.conflicts[] | select(.orig_rel == "c-drop.txt") | .path' "$VAR/conflicts.json" | head -1); old=$(cat "$SHARES/docs/c-drop.txt")
  request "ACTION='conflictdrop'" "CONFLICT_B64='$(b64u "$cpath")'" || fail=1
  [[ ! -e "$cpath" && "$(cat "$SHARES/docs/c-drop.txt")" == "$old" ]] && echo "  ok   Keep the original: the copy is deleted, \"${old}\" stays" || { echo "  FAIL drop"; fail=1; }
  wait_for '.app.conflicts.count == 0' 120 && echo "  ok   no conflicts left" || { echo "  FAIL conflicts left: $(jq -c '[.conflicts[].rel]' "$VAR/conflicts.json")"; fail=1; }
  request "ACTION='conflictkeep'" "CONFLICT_B64='$(b64u /etc/passwd.sync-conflict-20260101-000000-ABCDEFG)'" >/dev/null && { echo "  FAIL a made-up conflict path was acted on"; fail=1; } || echo "  ok   a conflict path outside the synced folders is refused"
  # ---------------------------------------------------------------- folder and device actions
  request "ACTION='folderedit'" "FID_B64='$(b64u "$did")'" "FLABEL_B64='$(b64u 'Documents & "Notes"')'" "FTYPE='sendreceive'" "FDEVICES='$aid'" || fail=1
  wait_for '.app.folders[] | select(.id == "'"$did"'") | .label == "Documents & \"Notes\""' 30 && echo "  ok   renamed, name intact" || { echo "  FAIL rename"; fail=1; }
  request "ACTION='folderversions'" "FID_B64='$(b64u "$did")'" "VTYPE='staggered'" "VKEEP='5'" "VDAYS='90'" || fail=1
  napi GET "config/folders/$did" | jq -e '.versioning.type == "staggered" and .versioning.params.maxAge == "7776000"' >/dev/null && echo "  ok   versioning changed to staggered, 90 days" || { echo "  FAIL staggered"; fail=1; }
  request "ACTION='folderignores'" "FID_B64='$(b64u "$did")'" "IGN_B64='$(b64u $'(?d)@eaDir\n*.tmp')'" || fail=1
  grep -qx '\*.tmp' "$SHARES/docs/.stignore" && echo "  ok   ignore patterns changed" || { echo "  FAIL ignores"; fail=1; }
  request "ACTION='folderpause'" "FID_B64='$(b64u "$did")'" "PAUSE='1'" || fail=1
  wait_for '.app.folders[] | select(.id == "'"$did"'") | .paused' 30 && echo "  ok   folder paused" || { echo "  FAIL pause"; fail=1; }
  request "ACTION='folderpause'" "FID_B64='$(b64u "$did")'" "PAUSE='0'" || fail=1
  request "ACTION='devrename'" "DEV_ID='$aid'" "DEV_NAME_B64='$(b64u "Alice's MacBook")'" || fail=1
  wait_for '.app.devices[] | select(.id == "'"$aid"'") | .name == "Alice'"'"'s MacBook"' 30 && echo "  ok   device renamed" || { echo "  FAIL devrename"; fail=1; }
  # Add by ID (an ID made by Syncthing itself), then remove.
  n=$(docker run --rm --entrypoint sh "$ST_IMG" -c 'syncthing generate --home /tmp/x 2>&1 | grep -o "[A-Z2-7]\{7\}\(-[A-Z2-7]\{7\}\)\{7\}" | head -1')
  request "ACTION='devadd'" "DEV_ID='$n'" "DEV_NAME_B64='$(b64u 'Pixel 8')'" "DEV_ADDR_B64='$(b64u tcp://192.168.1.31:22000)'" || fail=1
  napi GET "config/devices/$n" | jq -e '.name == "Pixel 8" and .addresses == ["tcp://192.168.1.31:22000"]' >/dev/null && echo "  ok   a device added by ID, with its address" || { echo "  FAIL devadd"; fail=1; }
  request "ACTION='devadd'" "DEV_ID='$NID'" "DEV_NAME_B64='$(b64u me)'" >/dev/null && { echo "  FAIL added itself"; fail=1; } || echo "  ok   this Synology's own ID is refused"
  request "ACTION='devremove'" "DEV_ID='$n'" || fail=1
  # Ignoring a device that asks.
  local bid; bid=$(peer_start "$BOB" "" "Bob's PC")
  wait_for '.app.pending_devices | map(select(.id == "'"$bid"'")) | length == 1' 120 || true
  request "ACTION='devignore'" "DEV_ID='$bid'" || fail=1
  wait_for '(.app.pending_devices | length == 0) and (.app.ignored_devices | map(.id) | index("'"$bid"'") != null)' 30 && echo "  ok   Bob's PC ignored: not pending, listed as ignored" || { echo "  FAIL ignore: $(jq -c '{p: .app.pending_devices, i: .app.ignored_devices}' "$VAR/status.json")"; fail=1; }
  docker rm -f "$BOB" >/dev/null 2>&1
  echo; return $fail
}
e2e_part4() {
  local fail=0 pw nid aid did old n cpath
  NKEY=$(key); NID=$(jq -r '.app.my_id' "$VAR/status.json")
  aid=$(cat "$E2E/.alice" 2>/dev/null); did=$(cat "$E2E/.docs" 2>/dev/null); pw=$(cat "$E2E/.pw" 2>/dev/null)
  # ---------------------------------------------------------------- privacy, bandwidth, sync port
  request "ACTION='privacy'" "PRIVACY='anywhere'" "MAX_SEND='500'" "MAX_RECV='0'" "LAN_LIMIT='0'" || fail=1
  napi GET config/options | jq -e '.globalAnnounceEnabled and .relaysEnabled and .natEnabled and .maxSendKbps == 500 and (.listenAddresses | length == 3)' >/dev/null && wait_for '.app.privacy == "anywhere"' 20 \
    && echo "  ok   anywhere: discovery, relays, NAT traversal on; upload limit 500 KiB/s" || { echo "  FAIL anywhere"; fail=1; }
  request "ACTION='privacy'" "PRIVACY='local'" "MAX_SEND='0'" "MAX_RECV='0'" "LAN_LIMIT='0'" || fail=1
  napi GET config/options | jq -e '(.globalAnnounceEnabled or .relaysEnabled or .natEnabled) == false and .maxSendKbps == 0 and .stunServers == []' >/dev/null && wait_for '.app.privacy == "local"' 20 \
    && echo "  ok   local network only again: global discovery, relays and NAT traversal off" || { echo "  FAIL local"; fail=1; }
  request "ACTION='syncport'" "SYNC_PORT='22011'" || fail=1
  napi GET config/options | jq -e '.listenAddresses == ["tcp://0.0.0.0:22011", "quic://0.0.0.0:22011"]' >/dev/null && ss -lntH | grep -q ':22011 ' && echo "  ok   sync port moved to 22011" || { echo "  FAIL syncport"; fail=1; }
  request "ACTION='syncport'" "SYNC_PORT='22000'" >/dev/null || fail=1
  wait_for '.app.devices | map(select(.id == "'"$aid"'" and .connected)) | length == 1' 120 && echo "  ok   …and back on 22000, Alice reconnects" || { echo "  FAIL reconnect after port"; fail=1; }
  request "ACTION='newpw'" || fail=1
  [[ "$(jq -r .password "$VAR/admin-pw.json")" != "$pw" && "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/rest/noauth/auth/password" -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$(jq -r .password "$VAR/admin-pw.json")" '{username: "admin", password: $p}')")" == 204 ]] \
    && echo "  ok   a new GUI password works (and is kept)" || { echo "  FAIL newpw"; fail=1; }
  rm -f "$VAR/secret.json"
  # ---------------------------------------------------------------- network: Docker's, and back
  request "ACTION='settings'" "NET_MODE='bridge'" || fail=1
  docker inspect -f '{{.HostConfig.NetworkMode}}' syncthing-server | grep -qv host && wait_for '.app.up and .app.net == "bridge"' 60 && echo "  ok   on Docker's network, ports published" || { echo "  FAIL bridge"; fail=1; }
  wait_for '.app.devices | map(select(.id == "'"$aid"'" and .connected)) | length == 1' 120 && echo "  ok   …Alice still connects" || { echo "  FAIL bridge connect"; fail=1; }
  request "ACTION='settings'" "NET_MODE='host'" || fail=1
  # ---------------------------------------------------------------- backup and restore keep the device ID
  request "ACTION='backup'" || fail=1
  n=$(jq -r '.backups[0].name' "$VAR/status.json")
  tar -xOf "$APP/backups/$n" "${n%.tar}/config.tar.gz" | tar -tzf - | sort | paste -sd' ' | grep -q 'cert.pem config.xml https-cert.pem https-key.pem key.pem' && echo "  ok   backup $n: config.xml, cert.pem, key.pem (no index)" || { echo "  FAIL backup contents"; fail=1; }
  napi DELETE "config/devices/$aid" >/dev/null; napi PATCH "config/gui" '{"password": "something-else-1"}' >/dev/null
  request "ACTION='restore'" "BACKUP='$n'" || fail=1
  wait_for '.app.my_id == "'"$NID"'" and (.app.devices | map(select(.id == "'"$aid"'" and .connected)) | length == 1)' 180 && echo "  ok   restored: same device ID ${NID:0:7}…, Alice back and connected" || { echo "  FAIL restore: $(jq -c '{id: .app.my_id, d: [.app.devices[] | {name, connected}]}' "$VAR/status.json")"; fail=1; }
  until_true '[[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/rest/noauth/auth/password" -H "Content-Type: application/json" -d "$(jq -nc --arg p "$(jq -r .password "$VAR/admin-pw.json")" "{username: \"admin\", password: \$p}")")" == 204 ]]' 60 \
    && echo "  ok   …the kept GUI password works again" || { echo "  FAIL password after restore"; fail=1; }
  wait_for '.app.folders | map(select(.id == "alice-photos" and .place == "there")) | length == 1' 120 && echo "  ok   …folders back, shared folders mounted" || { echo "  FAIL folders after restore"; fail=1; }
  # ---------------------------------------------------------------- the update path: an older Syncthing, updated from the window
  docker run --rm -v "$APP:/s" alpine sed -i 's|^ST_IMAGE=.*|ST_IMAGE=syncthing/syncthing:2.1.5|' /s/.env
  request "ACTION='settings'" "NET_MODE='bridge'" >/dev/null || true   # made again, now from the older image
  request "ACTION='settings'" "NET_MODE='host'" >/dev/null || true
  request "ACTION='check'" || fail=1
  jq -e '.image_update.available == true and .image_update.current == "2.1.5"' "$VAR/status.json" >/dev/null && echo "  ok   an update is offered: 2.1.5 → $(jq -r .image_update.latest "$VAR/status.json")" || { echo "  FAIL check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  request "ACTION='updateapp'" || fail=1
  [[ "$(docker inspect -f '{{.Config.Image}}' syncthing-server)" == "syncthing/syncthing:$(jq -r .image_update.latest "$VAR/status.json")" ]] && ! docker image inspect syncthing/syncthing:2.1.5 >/dev/null 2>&1 \
    && log_has 'backup syncthing-.*-pre-update' && echo "  ok   updated after a backup; only the old image was removed (by name)" || { echo "  FAIL update: $(docker inspect -f '{{.Config.Image}}' syncthing-server)"; fail=1; }
  wait_for '.app.my_id == "'"$NID"'" and (.app.devices | map(select(.connected)) | length == 1)' 120 && echo "  ok   …same device, Alice connected" || { echo "  FAIL after update"; fail=1; }
  echo; return $fail
}
