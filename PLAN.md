# zsh-ai-complete — Projektplan

Lokales LLM-gestütztes Shell-Completion für zsh. Tippen, was man will, per **Ctrl+X Ctrl+X** gegen lokalen oMLX (OpenAI-kompatibel) auflösen lassen, Vorschlag landet im Buffer — nie automatisch ausgeführt.

## Ziel / Nicht-Ziel

**Ziel:**
- Freitext-Intent → Kommando per Tastenkürzel (nicht Tab)
- Direkte Buffer-Ersetzung (Ghost text später möglich)
- Kontext (cwd, git status, letzte History-Einträge) wird mitgeschickt
- Läuft komplett gegen lokalen Endpoint (oMLX), keine Cloud-Abhängigkeit nötig
- Safety-Filter: destruktive Muster warnen, Vorschlag trotzdem einsetzen

**Nicht-Ziel (v1):**
- Kein eigenes Modell-Training/LoRA
- Kein Daemon mit eigenem Lifecycle-Management
- Kein automatisches Ausführen von Kommandos
- Kein Ghost text, kein Cache, kein Anthropic-API-Client

## Entscheidungen (v1)

| Thema | Entscheidung |
|-------|--------------|
| Anzeige | Direkte Buffer-Ersetzung; Undo via `Ctrl+X u` (explizites Restore) |
| Trigger | `Ctrl+X Ctrl+X` (zero-config); optional auch `⌥+Enter` |
| Backend | oMLX @ `http://127.0.0.1:8000/v1` |
| API | `POST /v1/chat/completions` |
| Safety | Warnen (`zle -M`) + trotzdem einsetzen |
| Modell | `AI_COMPLETE_MODEL` Pflicht — kein stiller Default |
| Auth | Optional `AI_COMPLETE_API_KEY` (Bearer) für oMLX |
| Client | Bash + curl + jq |

## Architektur

```
┌─────────────┐  Ctrl+X Ctrl+X   ┌──────────────────┐   HTTP POST    ┌────────────────┐
│  zsh Widget  │ ───────────────▶│  bin/ai-complete  │ ──────────────▶│  oMLX          │
│ (ZLE, .zsh)  │◀─────────────── │  (Bash)           │◀────────────── │  :8000/v1      │
└─────────────┘   Buffer-Ersatz  └──────────────────┘   JSON Antwort └────────────────┘
       │
       ▼
  Kontext-Sammlung:
  - $PWD, kurzes Verzeichnis-Listing
  - last_exit ($?) + letztes Kommando
  - git: branch, status --short, log -3, diff --stat
  - letzte N History-Einträge
  - uname/Shell-Info
```

## Projektstruktur

```
zsh-ai-complete/
├── PLAN.md
├── README.md
├── install.sh
├── plugin/ai-complete.plugin.zsh
├── bin/ai-complete
├── lib/context.sh
├── lib/safety.sh
├── config/default.env
└── tests/test_safety.sh
```

## Meilensteine

### M1 — Client
- [x] `bin/ai-complete` → oMLX chat/completions, Sanitize, required model
### M2 — Kontext
- [x] `lib/context.sh`
- [x] Low-effort extras: `last_exit`/`last_command`, branch+log+diff --stat, truncated `ls`
### M3 — Safety
- [x] `lib/safety.sh` + `tests/test_safety.sh` (warn, nicht block)
### M4 — zsh
- [x] ZLE-Widget, `Ctrl+X Ctrl+X`, Buffer-Replace, `ai-enable`/`ai-disable`/`ai-status`
### M5 — Install/Docs
- [x] `install.sh`, `config/default.env`, README

### Experiment — Ghost text (`experiment/ghost-text`)
- [x] `AI_COMPLETE_MODE=ghost`: POSTDISPLAY preview; Tab/→/Enter accept; Ctrl+X u / Ctrl+G / tippen verwerfen
- Fallback: `AI_COMPLETE_MODE=replace` oder Branch `main`

## Abnahmekriterien v1

- Freitext → Ctrl+X Ctrl+X → Kommando im Buffer, kein Auto-Execute
- Ohne `AI_COMPLETE_MODEL` → Fehler, Buffer unverändert
- Destruktive Muster → Warnung, Kommando trotzdem im Buffer
- Nur lokaler Endpoint
- Ein-/Ausschalten ohne `.zshrc` von Hand zu editieren
