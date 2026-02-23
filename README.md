# power-checker

Real-time power & battery monitoring CLI for macOS.

![demo](https://github.com/ruucm/power-checker/raw/main/demo.png)

```
⚡ Power Checker                        [Live] 2s refresh
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔋 Battery
  Charge:        67% ████████████████░░░░░░░░░░
  Status:        ⚡ Charging
  Health:        85% (Normal) · 298 cycles
  Temperature:   30.5°C
  Time to Full:  1h 23m
  Design Cap:    8579 mAh

🔌 AC Charger
  Connected:     ✓ Yes
  Wattage:       140W
  Voltage:       28.00V
  Charging:      Yes

📊 Power Draw
  Current:       3489 mA
  Voltage:       11.33V
  Power:         ~39.5W

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Press q to quit, +/- to adjust refresh rate
```

## Features

- **Real-time refresh** — 2-second auto-refresh (adjustable 1–10s)
- **Battery details** — charge %, progress bar, health, temperature, cycle count, remaining time
- **Charger info** — connection status, wattage, voltage, charging state
- **Power draw** — live current, voltage, computed wattage
- **Color-coded** — red/yellow/green based on charge level
- **Zero dependencies** — pure Bash, uses only built-in macOS commands (`ioreg`)

## Install

### Homebrew (recommended)

```bash
brew install ruucm/tap/power-checker
```

### curl

```bash
curl -fsSL https://raw.githubusercontent.com/ruucm/power-checker/main/power-checker.sh -o /usr/local/bin/power-checker && chmod +x /usr/local/bin/power-checker
```

### Manual

```bash
git clone https://github.com/ruucm/power-checker.git
cd power-checker
chmod +x power-checker.sh
./power-checker.sh
```

## Usage

```bash
power-checker
```

| Key | Action |
|-----|--------|
| `q` | Quit |
| `+` / `=` | Faster refresh (min 1s) |
| `-` / `_` | Slower refresh (max 10s) |

## Requirements

- macOS (uses `ioreg` for battery data)
- Bash 3.2+ (ships with macOS)

## How it works

Reads battery metrics from `ioreg -rn AppleSmartBattery` every refresh cycle and renders them with ANSI escape codes. No external dependencies, no sudo, no background daemons.

| Metric | Source |
|--------|--------|
| Charge % | `CurrentCapacity` / `MaxCapacity` |
| Health | `NominalChargeCapacity` / `DesignCapacity` |
| Temperature | `Temperature` ÷ 100 → °C |
| Voltage | `AppleRawBatteryVoltage` (mV) |
| Current | `Amperage` (mA, unsigned→signed) |
| Power (W) | Voltage × Current ÷ 10⁶ |
| Charger | `AdapterDetails` (Watts, Voltage) |
| Cycles | `CycleCount` |

## License

MIT
