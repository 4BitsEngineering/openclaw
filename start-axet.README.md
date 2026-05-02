# Axet (NTT) provider — wiring it up

`start-axet.sh` boots the axet-gateway sidecar (`:4010`) and completes the
Okta device-flow, but the OpenClaw gateway also needs to know about the
provider. That part is **per-machine config**: `openclaw.json` is treated
as runtime state and is in `.gitignore`, so the snippet below has to be
pasted into the active config file once per environment.

## Where to paste

Pick the file matching the overlay you run:

| Overlay   | Active config                                  |
| --------- | ---------------------------------------------- |
| base      | `~/.openclaw/openclaw.json`                    |
| asesoria  | `~/.openclaw/asesoria/openclaw.json`           |
| content   | `~/.openclaw/content/openclaw.json`            |
| custom    | whatever path your `OPENCLAW_CONFIG_PATH` env var points at |

Paste the `axet` entry inside `models.providers`, alongside `xiaomi` and
`ollama`. `${AXET_GATEWAY_TOKEN}` resolves at gateway boot from the env —
`start-axet.sh` exports it from `../axet-gateway/.env`.

```json
"axet": {
  "baseUrl": "http://127.0.0.1:4010/v1",
  "apiKey": "${AXET_GATEWAY_TOKEN}",
  "api": "openai-completions",
  "models": [
    {
      "id": "gpt-5.2-chat-latest",
      "name": "GPT-5.2 (NTT/Axet)",
      "reasoning": true,
      "input": ["text"],
      "cost": { "input": 1.75, "output": 14, "cacheRead": 0, "cacheWrite": 0 },
      "contextWindow": 200000,
      "maxTokens": 32000
    },
    {
      "id": "gpt-5-mini",
      "name": "GPT-5 Mini (NTT/Axet)",
      "reasoning": false,
      "input": ["text"],
      "cost": { "input": 0.25, "output": 2, "cacheRead": 0, "cacheWrite": 0 },
      "contextWindow": 128000,
      "maxTokens": 16384
    }
  ]
}
```

## Verifying it took

After restart, the work-console's `/api/gateway/models` should list both
`axet/gpt-5.2-chat-latest` and `axet/gpt-5-mini`. If they're missing,
check that:

1. The active `openclaw.json` has the block under `models.providers`.
2. `AXET_GATEWAY_TOKEN` is set in the gateway's process env (use
   `start-axet.sh` or source `axet-gateway/.env` before launching openclaw).
3. The axet-gateway sidecar is up (`curl http://127.0.0.1:4010/v1/health`
   with the token).

## Why this lives here, not in openclaw-ntt

`openclaw-ntt` previously carried this provider block in its tracked
`openclaw.json`. Since openclaw uses the same gateway code and
talks to axet via the same OpenAI-compatible interface, ntt is redundant
once the snippet above is applied to the active overlay.
