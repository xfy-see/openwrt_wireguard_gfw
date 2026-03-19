# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an OpenWrt router configuration toolkit for bypassing the GFW (Great Firewall of China) using WireGuard and policy-based routing. Scripts run on OpenWrt routers (ash/sh), not on the development machine.

## Architecture

The system routes GFW-blocked traffic through a WireGuard interface (`wg_aws`) using two mechanisms working in tandem:

1. **DNS-level interception**: `dnsmasq-full` intercepts DNS queries for blocked domains and populates nftables sets (`gfw_list_v4`, `gfw_list_v6`) with resolved IPs via the `nftset` directive.

2. **IP-level routing**: nftables marks packets destined for IPs in those sets with `MARK_GFW=0x1`. A policy routing rule sends marked packets through routing table 100, which routes them out `wg_aws`.

### File Roles

| File | Role |
|------|------|
| `wg_route` | OpenWrt init.d service (install to `/etc/init.d/wg_route`). Orchestrates everything: installs dnsmasq-full, writes nft rules to `/etc/nftables.d/gfwlist.nft`, configures policy routing via UCI, calls `update-proxy-domains.sh` |
| `update-proxy-domains.sh` | Downloads GFW domain list from Loyalsoldier's `v2ray-rules-dat` release, appends extra AI/chat domains, generates `/etc/dnsmasq.d/gfw-proxy.conf` with `server=` and `nftset=` rules per domain |
| `src/geoip2nftset.c` | C tool that parses `geoip.dat` protobuf binary and generates nftables set definitions for country IP ranges (replaces `geoip2nftset.py`) |
| `src/geosite2nftset.c` | C tool that parses `geosite.dat` protobuf binary and generates dnsmasq nftset configs for specific categories (replaces `geosite2nftset.py`) |
| `src/protobuf.h` | Shared header-only protobuf decoder used by both C tools |
| `src/util.h` | Shared utility header: colored output, file I/O, dynamic string arrays |
| `Makefile` | Build system for C tools: `make` for local, `make CC=... LDFLAGS="-static"` for cross-compilation |
| `geoip2nftset.py` | **Deprecated** — Python 3 version, superseded by C binary |
| `geosite2nftset.py` | **Deprecated** — Python 3 version, superseded by C binary |
| `verify-nftset.sh` | Validates the dnsmasq→nftset pipeline is working by querying a test domain and checking if nftables set entries increase |
| `add-telegram-ip.sh` | Manually adds Telegram IP ranges (AS62041/AS62014) to the nftables sets |
| `sing-box.json` | sing-box client config for use on client devices (not the router). Uses TUN mode with geosite/geoip rule sets, multiple outbound proxies (Shadowsocks, VLESS+Reality) with selector groups |
| `wg_roadwarrior.sh` | Sets up a WireGuard road-warrior VPN server on OpenWrt via UCI |
| `add_roadwarrior_peer.sh` | Adds a new peer to the road-warrior server, generates keys and QR code configs |
| `clash_service` | OpenWrt init.d service for Clash Premium (downloads binary to tmpfs at boot) |

## Deployment

Scripts are deployed to an OpenWrt router, not executed locally. Typical deployment:

```sh
# Copy service script
scp wg_route root@<router>:/etc/init.d/wg_route
chmod +x /etc/init.d/wg_route

# Copy update script to a persistent location
scp update-proxy-domains.sh root@<router>:/etc/gfwlist/
chmod +x /etc/gfwlist/update-proxy-domains.sh

# Enable and start
/etc/init.d/wg_route enable
/etc/init.d/wg_route start
```

## Key Configuration Values

All scripts have a "配置区" (config section) at the top that must match across scripts:

- **WireGuard interface**: `wg_aws` (in `wg_route`, `add-telegram-ip.sh`)
- **nftables table**: `inet fw4` (OpenWrt's default fw4 table)
- **nftset names**: `gfw_list_v4` / `gfw_list_v6`
- **Routing mark**: `0x1`, table `100`
- **dnsmasq config**: `/etc/dnsmasq.d/gfw-proxy.conf`
- **nft rules file**: `/etc/nftables.d/gfwlist.nft`

## Building C Tools

```sh
# Local build (macOS / Linux)
make

# Cross-compile for OpenWrt (aarch64 musl)
make CC=aarch64-openwrt-linux-musl-gcc LDFLAGS="-static"
```

## `geoip2nftset` / `geosite2nftset` Usage

```sh
# Generate CN IP nftables set definition
./geoip2nftset -g /path/to/geoip.dat -c CN -o cn_direct.nft

# Generate CN CIDR list
./geoip2nftset -g /path/to/geoip.dat -c CN -l -o cn_cidrs.txt

# List all available country codes
./geoip2nftset -g /path/to/geoip.dat --list-countries

# Generate dnsmasq nftset config for a geosite category
./geosite2nftset -g /path/to/geosite.dat -c google -n "4#inet#fw4#gfw_list_v4" -o google.conf

# Generate domain list
./geosite2nftset -g /path/to/geosite.dat -c cn -l -o cn_domains.txt

# List all available categories
./geosite2nftset -g /path/to/geosite.dat --list-categories
```

The `geosite.proto` file documents the protobuf schema used by the tools.

## `update-proxy-domains.sh` Environment Variables

- `BIND_IFACE`: If set (e.g., `wg_aws`), wget downloads the domain list through that interface's IP — used to bypass GFW to download the list itself.

## Notes

- `wg_route` guards all UCI writes with existence checks to protect OpenWrt flash memory from unnecessary writes.
- The `clash_service` downloads Clash Premium to a tmpfs mount at `/tmp/clash` — the binary is not persisted across reboots.
- `add_roadwarrior_peer.sh` requires `qrencode` to generate QR code SVGs for mobile clients.
