---
name: homeassistant
description: Control Home Assistant - smart plugs, lights, scenes, automations.
homepage: https://www.home-assistant.io/
metadata: {"openclaw":{"emoji":"🏠","requires":{"bins":["curl"],"env":["HA_URL"]},"primaryEnv":"HA_URL"}}
---

# Home Assistant

Control smart home devices via Home Assistant API.

## Setup

On this RPi5, call Home Assistant through Agent Vault (your `HTTP_PROXY`):
- `HA_URL`: `http://ha.home.arpa:8123`, a loopback alias the proxy brokers
- `HA_TOKEN`: the placeholder `__ha_token__`; Agent Vault swaps in the real token. You never hold it.

## Quick Commands

### List entities by domain
```bash
curl -s "$HA_URL/api/states" -H "Authorization: Bearer __ha_token__" | \
  jq -r '.[] | select(.entity_id | startswith("switch.")) | .entity_id'
```

### Turn on/off
```bash
# Turn on
curl -s -X POST "$HA_URL/api/services/switch/turn_on" \
  -H "Authorization: Bearer __ha_token__" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "switch.office_lamp"}'

# Turn off
curl -s -X POST "$HA_URL/api/services/switch/turn_off" \
  -H "Authorization: Bearer __ha_token__" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "switch.office_lamp"}'
```

### Control lights
```bash
# Turn on with brightness
curl -s -X POST "$HA_URL/api/services/light/turn_on" \
  -H "Authorization: Bearer __ha_token__" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "light.living_room", "brightness_pct": 80}'
```

### Trigger scene
```bash
curl -s -X POST "$HA_URL/api/services/scene/turn_on" \
  -H "Authorization: Bearer __ha_token__" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "scene.movie_time"}'
```

### Call any service
```bash
curl -s -X POST "$HA_URL/api/services/{domain}/{service}" \
  -H "Authorization: Bearer __ha_token__" \
  -H "Content-Type: application/json" \
  -d '{"entity_id": "...", ...}'
```

### Get entity state
```bash
curl -s "$HA_URL/api/states/{entity_id}" -H "Authorization: Bearer __ha_token__"
```

## Entity Domains

- `switch.*` — Smart plugs, generic switches
- `light.*` — Lights (Hue, LIFX, etc.)
- `scene.*` — Pre-configured scenes
- `automation.*` — Automations
- `climate.*` — Thermostats
- `cover.*` — Blinds, garage doors
- `media_player.*` — TVs, speakers
- `sensor.*` — Temperature, humidity, etc.

## Notes

- HA runs locally on this RPi5 — no external network needed
- API returns JSON by default
- Long-lived tokens don't expire — store securely in `~/.secrets/`
- Test entity IDs with the list command first
