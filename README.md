# daikin-hysteresis

Keeps a Daikin air conditioner's fan running between cooling cycles.

In cool, heat and auto modes, Daikin indoor units stop the fan entirely once the setpoint is reached. This script drives the unit through the Daikin Onecta cloud API instead:

- **Cooling** while the room is above `TARGET`
- **Fan only** once the room reaches `TARGET`
- **Back to cooling** when the room exceeds `TARGET + MARGIN`

It is a single bash script (`curl` + `jq`) intended to run as a systemd user service on an always-on Linux machine. Written for a Daikin Perfera (FTXM-A) with the built-in Wi-Fi adapter, which has no local API, but should work with any unit visible in the Onecta app.

## Behaviour

- Only controls the unit during configurable active hours (default 22:00–10:00). No API calls outside them.
- Leaves the unit alone unless it is powered on and in cooling or fan mode, so the remote and the Onecta app keep working normally.
- Enforces a minimum time between mode switches (default 10 minutes) to protect the compressor, and makes no API calls while waiting.
- Sets the unit's own cooling setpoint to `TARGET - SETPOINT_OFFSET`, so the unit does not stop its fan before the script switches it to fan mode. The setpoint is only sent when it differs, and before the mode change.
- Stays within Onecta's limit of 200 API calls per day: polls every 5 minutes, slows down when the remaining daily budget is low, and honours `Retry-After` on HTTP 429.

When switching from fan to cooling the unit briefly stops its fan and resets its louvres before cooling starts. That is the unit's own start-up sequence, not the script.

## Requirements

- Linux with systemd, `bash`, `curl`, `jq` and GNU `date`
- A Daikin Onecta account with the unit registered
- An app registered on the [Daikin developer portal](https://developer.cloud.daikineurope.com)

## Installation

1. **Register an app** on the Daikin developer portal, signed in with the same email as your Onecta account. Daikin allows one app per account. The redirect URI must not contain `localhost` (the portal returns 403). A LAN address such as `https://192.168.0.10:8443/daikin` works, and nothing needs to be listening there.

2. **Install dependencies and files:**
   ```bash
   sudo apt install -y jq curl
   mkdir -p ~/bin ~/.config/daikin ~/.config/systemd/user
   cp daikin-hysteresis.sh ~/bin/ && chmod +x ~/bin/daikin-hysteresis.sh
   cp config.example ~/.config/daikin/config && chmod 600 ~/.config/daikin/config
   cp daikin-hysteresis.service ~/.config/systemd/user/
   ```

3. **Configure** `~/.config/daikin/config`: `CLIENT_ID`, `CLIENT_SECRET`, `REDIRECT_URI` (exactly as registered), `TARGET`, and the active hours.

4. **Sign in once:**
   ```bash
   ~/bin/daikin-hysteresis.sh auth
   ```
   Open the printed URL and sign in. The browser then fails to load the redirect URI, which is expected. Paste that full URL (it contains `code=...`) back into the prompt. The code expires within minutes.

5. **Check the unit is visible:**
   ```bash
   ~/bin/daikin-hysteresis.sh status
   ```

6. **Run as a service** that survives logout and reboot:
   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now daikin-hysteresis
   sudo loginctl enable-linger "$USER"
   ```

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `TARGET` | `23.0` | Switch to fan at or below this temperature (°C) |
| `MARGIN` | `1.0` | Switch back to cooling at `TARGET + MARGIN` |
| `SETPOINT_OFFSET` | `1.0` | Unit's cooling setpoint is `TARGET - SETPOINT_OFFSET` |
| `ACTIVE_START` / `ACTIVE_END` | `22` / `10` | Hours during which the script controls the unit |
| `POLL_SECONDS` | `300` | Poll interval during active hours |
| `LOW_BUDGET_CALLS` | `20` | Slow polling when fewer daily calls than this remain |
| `LOW_BUDGET_POLL_SECONDS` | `1800` | Poll interval when the budget is low |
| `MIN_DWELL_SECONDS` | `600` | Minimum time between mode switches |
| `DEVICE_ID` | empty | Only needed if the account has more than one unit |

## Managing the service

```bash
systemctl --user status daikin-hysteresis                # running? last few log lines
journalctl --user -u daikin-hysteresis -f                # follow the log
journalctl --user -u daikin-hysteresis --since "22:00"   # tonight's activity
systemctl --user restart daikin-hysteresis               # after editing the config
systemctl --user stop daikin-hysteresis                  # stop it
loginctl show-user "$USER" -p Linger                     # should print Linger=yes
```

Closing the `journalctl` window, or logging out, does not stop the service.

## Security

The client secret lives only in `~/.config/daikin/config` (mode 600) and the OAuth tokens in `~/.local/state/daikin` (mode 700). Never commit either. If the refresh token is ever rejected, rerun `daikin-hysteresis.sh auth`.

## Licence

[MIT](LICENSE)
