# 🧙‍♂️ NodeWizard

A lightweight Linux VPS initialization and deployment tool.

```text
  _   _           _     __        ___                  _ 
 | \ | | ___   __| | ___\ \      / (_)______ _ _ __ __| |
 |  \| |/ _ \ / _` |/ _ \\ \ /\ / /| |_  / _` | '__/ _` |
 | |\  | (_) | (_| |  __/ \ V  V / | |/ / (_| | | | (_| |
 |_| \_|\___/ \__,_|\___|  \_/\_/  |_/___|\__,_|_|  \__,_|
```

## Quick Start

Run directly on a fresh Debian / Ubuntu machine:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/JohnsonGond/NodeWizard/main/nodewizard.sh)"
```

Or via Git:

```bash
git clone https://github.com/JohnsonGond/NodeWizard.git
cd NodeWizard
chmod +x nodewizard.sh
./nodewizard.sh
```

## Overview

Interactive terminal menu options:

- **[1] Full Deployment**: System hardening, security setup, and proxy services.
- **[2] Inspect Status**: View current configuration, open ports, and service status.
- **[3] Security Only**: Configure maintenance user, SSH keys, port hardening, and firewall.
- **[4] Proxy Only**: Configure proxy backend and outbound routing.
- **[5] View Client Configs**: Export connection links and configurations.
- **[6] IPv6 Management**: Dual-stack routing governance and outbound policy toggle.

## Requirements

- Debian 11/12+ or Ubuntu 20.04/22.04/24.04+ (x86_64 / arm64)
- Root privileges
