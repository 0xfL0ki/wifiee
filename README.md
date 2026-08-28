# wifiee

**WiFi EAP Evil-twin & PEAP Relay Toolkit**

Automated rogue AP setup for PEAP relay attacks using [hostapd-mana](https://github.com/sensepost/hostapd-mana) and [wpa_sycophant](https://github.com/sensepost/wpa_sycophant). Handles target scanning, BSSID spoofing, client deauthentication, RADIUS certificate cloning, and relay orchestration — all from a single script.

```
  ╦ ╦╦╔═╗╦╔═╗╔═╗
  ║║║║╠╣ ║║╣ ║╣
  ╚╩╝╩╚  ╩╚═╝╚═╝
  WiFi EAP Evil-twin & PEAP Relay
```

## What it does

1. **Scans** for the target SSID and lists all broadcasting APs (BSSID, channel, signal)
2. **Lets you choose** how to spoof — clone the real BSSID, use a random one, or set a custom MAC
3. **Probes** the real AP to extract the RADIUS server certificate subject for realistic cloning
4. **Deauths** clients from the real AP (aircrack-ng / mdk4 / scapy — uses whatever is installed)
5. **Launches** the rogue AP (hostapd-mana) and the EAP relay (wpa_sycophant) simultaneously
6. **Captures** PEAP/MSCHAPv2 challenge-response hashes in the terminal (MANA WPE output)

## Requirements

- **OS:** Kali Linux 2024+ (tested on 2025/2026, kernel 6.x, OpenSSL 3.x)
- **Adapters:** Two wireless interfaces with AP mode support
- **Packages:** Installed automatically if missing

| Package | Purpose |
|---------|---------|
| `hostapd-mana` | Rogue AP with MANA/WPE/sycophant support |
| `aircrack-ng` | Deauthentication (aireplay-ng + airmon-ng) |
| `build-essential libssl-dev libnl-3-dev libnl-genl-3-dev` | Building wpa_sycophant |

Optional: `xterm` (sycophant runs in a separate window), `mdk4`, `python3-scapy`

### Tested adapters

| Adapter | Chipset | Notes |
|---------|---------|-------|
| Alfa AWUS036AXML | MediaTek MT7921AU | Driver in mainline kernel (mt7921u). VMware USB passthrough may cause `probe_req: send failed` — use random BSSID or run bare metal. |
| Alfa AWUS036ACH | Realtek RTL8812AU | Needs out-of-tree driver. Good for deauth-only role. |
| Alfa AWUS036ACM | MediaTek MT7612U | Works well in AP mode on Linux. |

## Install

```bash
git clone https://github.com/YOUR_USERNAME/wifiee.git
cd wifiee
chmod +x wifiee.sh
```

## Usage

### Interactive (recommended)

```bash
sudo ./wifiee.sh
```

You'll be prompted for the target SSID, then guided through BSSID selection, channel options, and deauth.

### With flags

```bash
# Specify everything up front
sudo ./wifiee.sh --ssid "CorpWiFi" --channel 6 --country AU

# Use specific interfaces
sudo ./wifiee.sh --ssid "CorpWiFi" --iface-ap wlan1 --iface-relay wlan0

# Skip deauth
sudo ./wifiee.sh --ssid "CorpWiFi" --no-deauth

# Custom certificate details for realism
sudo ./wifiee.sh --ssid "CorpWiFi" --cert-cn "radius.corp.com" --cert-org "Acme Corp"
```

### All options

```
Options:
  --ssid NAME           Target SSID (prompted if omitted)
  --bssid MAC           Target BSSID (auto-scanned if omitted)
  --channel N           Channel (auto-detected if omitted)
  --iface-ap IFACE      Rogue AP interface (default: wlan0)
  --iface-relay IFACE   Relay interface (default: wlan1)
  --country CC          Regulatory domain (default: US)
  --cert-cn CN          Fake RADIUS cert CN
  --cert-org ORG        Fake RADIUS cert Org
  --deauth N            Deauth burst count (default: 10)
  --no-deauth           Skip deauth phase
  -h, --help            Show help
```

## Attack flow

```
┌──────────────┐     deauth      ┌──────────────┐
│   Real AP    │◄────────────────│   wlan1       │
│  (CorpWiFi)  │                 │  (relay)      │
└──────┬───────┘                 └──────┬────────┘
       │                                │
       │  clients forced off            │  sycophant relays
       │                                │  EAP exchange
       ▼                                ▼
┌──────────────┐   EAP relay    ┌───────────────┐
│   Client     │───────────────►│   wlan0        │
│  reconnects  │                │  (rogue AP)    │
│  to rogue    │                │  hostapd-mana  │
└──────────────┘                └───────┬────────┘
                                        │
                                        ▼
                                 ┌──────────────┐
                                 │  Captured     │
                                 │  MSCHAPv2     │
                                 │  hashes       │
                                 └──────────────┘
```

## VMware notes

If running Kali as a VMware guest with USB-passthrough adapters:

- Set **VM > Settings > USB Controller** to **USB 3.1**
- Connect the adapter via **VM > Removable Devices > MediaTek Wireless_Device > Connect**
- If you see `handle_probe_req: send failed`, select **Random BSSID** (option 2) or try the **2.4GHz channel override**
- For best results, run Kali on **bare metal** or a **Raspberry Pi**

## Cracking captured hashes

MANA WPE outputs MSCHAPv2 challenge-response pairs. Crack with hashcat:

```bash
# Extract the hash line from hostapd-mana output (format: NETNTLM)
hashcat -m 5500 captured_hash.txt wordlist.txt
```

Or with john:

```bash
john --format=netntlmv1 captured_hash.txt --wordlist=wordlist.txt
```

## Disclaimer

This tool is intended for **authorised security assessments only**. Only use against networks you have explicit written permission to test. Unauthorised use is illegal in most jurisdictions.

## Credits

- [SensePost](https://github.com/sensepost) — hostapd-mana, wpa_sycophant
- [1mm0rt41PC](https://github.com/1mm0rt41PC) — original PEAP relay script concept

## License

GPL-2.0
