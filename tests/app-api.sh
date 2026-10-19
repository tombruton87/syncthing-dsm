# Syncthing's CGI checks (sourced by chassis/tests/test-api.sh).
ID=ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ23-4567ABC-DEFGHIJ-KLMNOPQ-RSTUVWX
ID2=BBCDEFG-HIJKLMN-OPQRSTU-VWXYZ23-4567ABC-DEFGHIJ-KLMNOPQ-RSTUVWX
expect "devaccept" 202 "$(post "$me" devaccept "action=devaccept&dev=abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx&name=Alice%27s+laptop")"; request_is "devaccept request (ID normalised, name base64url)" "ACTION='devaccept'
DEV_ID='$ID'
DEV_NAME_B64='QWxpY2UncyBsYXB0b3A'
BY='$me'"
expect "devaccept bad id" 400 "$(post "$me" devaccept 'action=devaccept&dev=ABC%24(id)&name=x')"
expect "devaccept 1 in id" 400 "$(post "$me" devaccept "action=devaccept&dev=${ID/A/1}&name=x")"
expect "devaccept no name" 400 "$(post "$me" devaccept "action=devaccept&dev=$ID&name=")"
expect "devadd address" 202 "$(post "$me" devadd "action=devadd&dev=$ID&name=Pixel+8&addr=tcp%3A%2F%2F192.168.1.30%3A22000")"; request_is "devadd request" "ACTION='devadd'
DEV_ID='$ID'
DEV_NAME_B64='UGl4ZWwgOA'
DEV_ADDR_B64='dGNwOi8vMTkyLjE2OC4xLjMwOjIyMDAw'
BY='$me'"
expect "devadd bad address" 400 "$(post "$me" devadd "action=devadd&dev=$ID&name=x&addr=http%3A%2F%2Fevil")"
expect "devpause" 202 "$(post "$me" devpause "action=devpause&dev=$ID&pause=1")"; rm -f "$CHASSIS_VAR/request"
expect "devpause bad" 400 "$(post "$me" devpause "action=devpause&dev=$ID&pause=2")"
expect "folderadd" 202 "$(post "$me" folderadd "action=folderadd&label=Photos&path=%2Fvolume1%2Fphotos%2FPhone&type=sendreceive&devices=$ID%2B$ID2&vtype=simple&vkeep=7&vdays=0&ignores=(%3Fd)%40eaDir%0D%0A(%3Fd)%23recycle")"; request_is "folderadd request" "ACTION='folderadd'
FLABEL_B64='UGhvdG9z'
FPATH_B64='L3ZvbHVtZTEvcGhvdG9zL1Bob25l'
FTYPE='sendreceive'
FDEVICES='$ID+$ID2'
VTYPE='simple'
VKEEP='7'
VDAYS='0'
IGN_B64='KD9kKUBlYURpcgooP2QpI3JlY3ljbGU'
BY='$me'"
expect "folderadd traversal" 400 "$(post "$me" folderadd "action=folderadd&label=x&path=%2Fvolume1%2F..%2Fetc&type=sendreceive&vtype=none")"
expect "folderadd quote" 400 "$(post "$me" folderadd "action=folderadd&label=x&path=%2Fvolume1%2Fa%22b&type=sendreceive&vtype=none")"
expect "folderadd bad type" 400 "$(post "$me" folderadd "action=folderadd&label=x&path=%2Fvolume1%2Fa&type=x&vtype=none")"
expect "folderadd staggered 0 days" 400 "$(post "$me" folderadd "action=folderadd&label=x&path=%2Fvolume1%2Fa&type=sendonly&vtype=staggered&vdays=0")"
expect "folderaccept" 202 "$(post "$me" folderaccept "action=folderaccept&fid=abcd+efgh&dev=$ID&label=Docs&path=%2Fvolume1%2Fsync%2FDocs&type=receiveonly&devices=$ID&vtype=trashcan&vdays=30")"; request_is "folderaccept request" "ACTION='folderaccept'
FLABEL_B64='RG9jcw'
FPATH_B64='L3ZvbHVtZTEvc3luYy9Eb2Nz'
FTYPE='receiveonly'
FDEVICES='$ID'
VTYPE='trashcan'
VKEEP='5'
VDAYS='30'
FID_B64='YWJjZCBlZmdo'
DEV_ID='$ID'
BY='$me'"
expect "folderignores empty" 202 "$(post "$me" folderignores "action=folderignores&fid=abcde-12345&ignores=")"; request_is "folderignores empty → a comment" "ACTION='folderignores'
FID_B64='YWJjZGUtMTIzNDU'
IGN_B64='Ly8gbm8gcGF0dGVybnM'
BY='$me'"
expect "folderremove" 202 "$(post "$me" folderremove "action=folderremove&fid=abcde-12345")"; rm -f "$CHASSIS_VAR/request"
expect "folderremove no id" 400 "$(post "$me" folderremove "action=folderremove&fid=")"
expect "conflictkeep" 202 "$(post "$me" conflictkeep "action=conflictkeep&file=%2Fvolume1%2Fdocs%2Fa.sync-conflict-20261019-101500-ABCDEFG.txt")"; rm -f "$CHASSIS_VAR/request"
expect "conflictkeep not a conflict" 400 "$(post "$me" conflictkeep "action=conflictkeep&file=%2Fetc%2Fpasswd")"
expect "privacy" 202 "$(post "$me" privacy "action=privacy&mode=local&maxsend=500&maxrecv=0&lanlimit=1")"; request_is "privacy request" "ACTION='privacy'
PRIVACY='local'
MAX_SEND='500'
MAX_RECV='0'
LAN_LIMIT='1'
BY='$me'"
expect "privacy bad" 400 "$(post "$me" privacy "action=privacy&mode=everywhere")"
expect "syncport" 202 "$(post "$me" syncport "action=syncport&port=22001")"; rm -f "$CHASSIS_VAR/request"
expect "syncport low" 400 "$(post "$me" syncport "action=syncport&port=80")"
expect "settings with network" 202 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F192.168.1.20%3A8384&port=8384&ssl_proxy=0&tz=Europe%2FLondon&net=bridge')"; grep -q "^NET_MODE='bridge'$" "$CHASSIS_VAR/request" && { (( pass++ )); echo "  ok   settings carry the network"; } || { (( fail++ )); echo "  FAIL settings network"; }; rm -f "$CHASSIS_VAR/request"
expect "settings bad network" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F192.168.1.20%3A8384&port=8384&ssl_proxy=0&tz=Europe%2FLondon&net=none')"
expect "activity" 200 "$(get "$me" 'action=activity')"; expect "conflicts" 200 "$(get "$me" 'action=conflicts')"
expect "showpw none → 404" 404 "$(get "$me" 'action=showpw')"
expect "viewer showpw → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=showpw')"
