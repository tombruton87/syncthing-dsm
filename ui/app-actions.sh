# Syncthing's actions, validated by the CGI before they become a request file (and again in the setup container).
# Free text (names, paths, folder IDs, ignore patterns) goes on as base64url (*_B64); device IDs in Syncthing's own shape.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
DEV_RE='^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$'
CONFLICT_RE='\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]{7}'
bad_text() { local bad='[[:cntrl:]]'; [[ -z "$1" || ${#1} -gt $2 || "$1" =~ $bad ]]; }
dev_norm() {   # what someone pasted → a device ID in Syncthing's shape (dashes, upper case), or nothing
  local d; d=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -d ' -')
  [[ "$d" =~ ^[A-Z2-7]+$ && ${#d} -eq 56 ]] || return 1
  d="${d:0:7}-${d:7:7}-${d:14:7}-${d:21:7}-${d:28:7}-${d:35:7}-${d:42:7}-${d:49:7}"
  [[ "$d" =~ $DEV_RE ]] && echo "$d"
}
# Each *_param checks one field and sets a V_* variable (never inside $(…): error must end the CGI itself).
dev_param() { V_DEV=$(dev_norm "$(decode "$(param dev "$1")")") || error "400 Bad Request" "A device ID is eight groups of seven letters and digits, like ABCDEFG-HIJKLMN-…"; }
fid_param() { local f; f=$(decode "$(param fid "$1")"); bad_text "$f" 255 && error "400 Bad Request" "Pick a folder."; V_FID=$(b64u "$f"); }
path_param() {
  local p bad='[[:cntrl:]$"`\\]'; p=$(decode "$(param path "$1")"); p=${p%/}
  [[ "$p" == /?* && "$p" != *..* && "$p" != *//* && ${#p} -le 400 && ! "$p" =~ $bad ]] || error "400 Bad Request" "A folder is a path like /volume1/photos or /volume1/photos/Phone."
  V_PATH=$(b64u "$p")
}
label_param() { local l; l=$(decode "$(param label "$1")" | sed 's/^ *//; s/ *$//'); bad_text "$l" 100 && error "400 Bad Request" "Give the folder a name (up to 100 characters)."; V_LABEL=$(b64u "$l"); }
type_param() { local t; t=$(param type "$1"); [[ "$t" =~ ^(sendreceive|sendonly|receiveonly)$ ]] || error "400 Bad Request" "Pick send & receive, send only or receive only."; V_TYPE=$t; }
devices_param() {   # dev IDs joined by + or , → the same joined by +, or none
  local v d out="" n=0; v=$(decode "$(param devices "$1")" | tr ',' '+')
  V_DEVS=none; [[ -z "$v" || "$v" == none ]] && return 0
  local IFS=+
  for d in $v; do d=$(dev_norm "$d") || error "400 Bad Request" "One of the devices isn't a device ID."; out="${out:+$out+}$d"; (( ++n <= 32 )) || error "400 Bad Request" "Too many devices."; done
  V_DEVS=${out:-none}
}
ignores_param() {   # the patterns, one per line → base64url ("" when empty)
  local v l bad='[[:cntrl:]]'; v=$(decode "$(param ignores "$1")" | tr -d '\r')
  (( ${#v} <= 3000 )) || error "400 Bad Request" "That's too many ignore patterns for the window — edit them in Syncthing's own interface."
  (( $(grep -c '' <<< "$v") <= 200 )) || error "400 Bad Request" "At most 200 ignore patterns."
  while IFS= read -r l; do [[ ${#l} -le 300 && ! "$l" =~ $bad ]] || error "400 Bad Request" "An ignore pattern is one line of up to 300 characters."; done <<< "$v"
  V_IGN=""; [[ -n "$(tr -d ' \n' <<< "$v")" ]] && V_IGN=$(b64u "$v"); true
}
versioning_lines() {   # body → VTYPE/VKEEP/VDAYS lines
  local t k d; t=$(param vtype "$1"); k=$(param vkeep "$1"); d=$(param vdays "$1")
  [[ "$t" =~ ^(none|trashcan|simple|staggered)$ ]] || error "400 Bad Request" "Pick how versions are kept."
  [[ -z "$k" ]] && k=5; [[ -z "$d" ]] && d=0
  [[ "$k" =~ ^[0-9]{1,3}$ ]] && (( 10#$k >= 1 )) || error "400 Bad Request" "Keep 1 to 999 versions."
  [[ "$d" =~ ^[0-9]{1,4}$ ]] && (( 10#$d <= 3650 )) || error "400 Bad Request" "Days: 0 to 3650."
  [[ "$t" == staggered ]] && (( 10#$d < 1 )) && error "400 Bad Request" "Keep versions for at least a day."
  V_VERS="VTYPE='$t'
VKEEP='$((10#$k))'
VDAYS='$((10#$d))'"
}
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 d n p v f i
  case "$a" in
    conflictscan|newpw|sharescan) lines="ACTION='$a'" ;;
    devaccept|devadd|devrename)
      dev_param "$body"; d=$V_DEV; n=$(decode "$(param name "$body")" | sed 's/^ *//; s/ *$//')
      bad_text "$n" 60 && error "400 Bad Request" "Give the device a name (up to 60 characters)."
      lines="ACTION='$a'
DEV_ID='$d'
DEV_NAME_B64='$(b64u "$n")'"
      if [[ "$a" == devadd ]]; then v=$(decode "$(param addr "$body")" | tr -d ' ')
        if [[ -n "$v" && "$v" != dynamic ]]; then
          [[ "$v" =~ ^(tcp|quic)[46]?://([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$ ]] || error "400 Bad Request" "An address looks like tcp://192.168.1.30:22000 — or leave it empty to find the device by itself."
          lines="$lines
DEV_ADDR_B64='$(b64u "$v")'"; fi; fi ;;
    devignore|devremove) dev_param "$body"; d=$V_DEV; lines="ACTION='$a'
DEV_ID='$d'" ;;
    devpause) dev_param "$body"; d=$V_DEV; p=$(param pause "$body"); [[ "$p" =~ ^[01]$ ]] || error "400 Bad Request" "Pause or resume?"; lines="ACTION='devpause'
DEV_ID='$d'
PAUSE='$p'" ;;
    folderadd|folderaccept)
      label_param "$body"; path_param "$body"; type_param "$body"; devices_param "$body"; versioning_lines "$body"; ignores_param "$body"
      lines="ACTION='$a'
FLABEL_B64='$V_LABEL'
FPATH_B64='$V_PATH'
FTYPE='$V_TYPE'
FDEVICES='$V_DEVS'
$V_VERS"
      if [[ "$a" == folderaccept ]]; then dev_param "$body"; fid_param "$body"; lines="$lines
FID_B64='$V_FID'
DEV_ID='$V_DEV'"; fi
      [[ -n "$V_IGN" ]] && lines="$lines
IGN_B64='$V_IGN'" ;;
    folderdecline) dev_param "$body"; fid_param "$body"; lines="ACTION='folderdecline'
FID_B64='$V_FID'
DEV_ID='$V_DEV'" ;;
    folderedit) fid_param "$body"; label_param "$body"; type_param "$body"; devices_param "$body"; lines="ACTION='folderedit'
FID_B64='$V_FID'
FLABEL_B64='$V_LABEL'
FTYPE='$V_TYPE'
FDEVICES='$V_DEVS'" ;;
    folderversions) fid_param "$body"; versioning_lines "$body"; lines="ACTION='folderversions'
FID_B64='$V_FID'
$V_VERS" ;;
    folderignores) fid_param "$body"; ignores_param "$body"; [[ -n "$V_IGN" ]] || V_IGN=$(b64u "// no patterns")
      lines="ACTION='folderignores'
FID_B64='$V_FID'
IGN_B64='$V_IGN'" ;;
    folderscan|folderoverride|folderrevert|folderremove) fid_param "$body"; lines="ACTION='$a'
FID_B64='$V_FID'" ;;
    folderpause) p=$(param pause "$body"); [[ "$p" =~ ^[01]$ ]] || error "400 Bad Request" "Pause or resume?"; fid_param "$body"; lines="ACTION='folderpause'
FID_B64='$V_FID'
PAUSE='$p'" ;;
    conflictkeep|conflictdrop)
      f=$(decode "$(param file "$body")")
      [[ "$f" == /?* && "$f" != *..* && ${#f} -le 1000 && "$(basename "$f")" =~ $CONFLICT_RE ]] && ! bad_text "$f" 1000 || error "400 Bad Request" "Pick a conflict copy from the list."
      lines="ACTION='$a'
CONFLICT_B64='$(b64u "$f")'" ;;
    privacy)
      v=$(param mode "$body"); [[ "$v" =~ ^(anywhere|local)$ ]] || error "400 Bad Request" "Anywhere, or the local network only?"
      local s r l; s=$(param maxsend "$body"); r=$(param maxrecv "$body"); l=$(param lanlimit "$body")
      [[ -z "$s" ]] && s=0; [[ -z "$r" ]] && r=0
      [[ "$s" =~ ^[0-9]{1,7}$ && "$r" =~ ^[0-9]{1,7}$ ]] || error "400 Bad Request" "Limits are in KiB/s: 0 for none, up to 9999999."
      [[ "$l" =~ ^[01]$ ]] || l=0
      lines="ACTION='privacy'
PRIVACY='$v'
MAX_SEND='$((10#$s))'
MAX_RECV='$((10#$r))'
LAN_LIMIT='$l'" ;;
    syncport) p=$(param port "$body"); [[ "$p" =~ ^[0-9]{4,5}$ ]] && (( 10#$p >= 1024 && 10#$p <= 65535 )) || error "400 Bad Request" "The sync port is a number from 1024 to 65535."
      lines="ACTION='syncport'
SYNC_PORT='$((10#$p))'" ;;
  esac
}
app_cgi_settings() {   # body → appends NET_MODE to $lines, or errors
  local net; net=$(param net "$1")
  [[ -z "$net" ]] && return 0
  [[ "$net" =~ ^(host|bridge)$ ]] || error "400 Bad Request" "The network is the NAS's own (host) or Docker's (bridge)."
  lines="$lines
NET_MODE='$net'"
}
app_cgi_get() {   # action query → replies, or returns for "unknown"
  case "$1" in
    activity)  reply "200 OK" application/json "$(cat "$VAR/activity.json" 2>/dev/null || echo '{"items":[]}')" ;;
    conflicts) reply "200 OK" application/json "$(cat "$VAR/conflicts.json" 2>/dev/null || echo '{"count":0,"conflicts":[]}')" ;;
    showpw) [[ -f "$VAR/admin-pw.json" ]] || error "404 Not Found" "The package hasn't kept a password yet: New password makes one, and it's kept from then on."
            reply "200 OK" application/json "$(cat "$VAR/admin-pw.json")" ;;
  esac
}
