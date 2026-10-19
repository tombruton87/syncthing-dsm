    echo "SYNC_PORT='$(printf '%s' "${wizard_sync_port:-22000}" | tr -cd '0-9' | head -c 5)'"
    echo "PRIVACY='$(if [ "${wizard_privacy_local:-false}" = true ]; then echo local; else echo anywhere; fi)'"
