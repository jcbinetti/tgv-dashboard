# USER_DOCS — No-Coder-Dokumentation

Diese Doku erklärt das TGV-System in der Sprache des Nutzers, nicht der Maintainer.

## Dokumentations-Schema (systematisch)

Jeder Workflow / jede Pipeline wird **identisch** dokumentiert nach folgendem Aufbau:

1. **Steckbrief** (1 Block, max. 8 Felder)
   - Name & Version · Datei-Quelle · Trigger (cron+human) · Aktiv-Status
   - Token-Kosten typisch · n8n-Executions typisch · Quota-Klasse
2. **Schritt-Tabelle** mit den Pflicht-Spalten:
   | # | Akteur (Node) | Was passiert (no-coder) | Daten-Eingang | Daten-Ausgang | API-Call? | n8n-Exec? | Token? | Was wird gespeichert? | Wo sichtbar im Dashboard? | Stop/Weiter |
3. **Lern-Boxen** für jeden technischen Begriff (📚)
4. **Was NICHT passiert** (häufige Fehlannahmen, tote Nodes)
5. **Was kann der User selbst sehen / ändern** (Dashboard-Pfade)
6. **Limits** (Encoding, max-Größe, max-Anzahl, Timeouts)
7. **TL;DR** (3–4 Phasen, je 1 Satz)

## Dateien

| Pipeline | Was | Trigger | Datei |
|---|---|---|---|
| **A2 Mail-Intake** | Mail → `factures@convis.fr` → DB-Eintrag | Cron 00:00 + 12:00 UTC | [PIPELINE_A2_MAIL_INTAKE.md](PIPELINE_A2_MAIL_INTAKE.md) |
| **B Drive-Drop** | Datei in Drive `INBOX/` → DB-Eintrag | Cron alle 15 Min | [PIPELINE_B_DRIVE_DROP.md](PIPELINE_B_DRIVE_DROP.md) |
| **Cascade** | DB-Inbox → Drive-Upload + Skills + Reconcile | Webhook + Chatbot | [PIPELINE_CASCADE.md](PIPELINE_CASCADE.md) |
| **D Reclass** | User-Korrektur an Doc → Re-Run Skill + Lernen | Webhook (UI/Chatbot) | [PIPELINE_D_RECLASS.md](PIPELINE_D_RECLASS.md) |
| **E Buchhalter** | Monats-Bundle an Steuerberater | Webhook (Chatbot) | [PIPELINE_E_BUCHHALTER.md](PIPELINE_E_BUCHHALTER.md) |

## Schema-Begründung — warum **diese** Spalten

| Spalte | Warum sie Pflicht ist |
|---|---|
| **Akteur** | n8n-Node-Name. Wer auf den Node klickt findet ihn 1:1 in n8n. |
| **Was passiert** | Eine no-coder-tauglicher Satz. Keine Variablen-Namen, keine JS. |
| **Daten-Eingang/-Ausgang** | Macht sichtbar **wo Daten umkippen können** — der häufigste Bug-Layer in Iter 22/23. |
| **API-Call?** | Kostenpunkt Claude/Supabase/Drive. User muss sehen, ob ein Schritt Geld kostet. |
| **n8n-Exec?** | Quota-Anker. 1 Schedule-Tick = 1 Execution für alle Inline-Nodes; nur **Sub-Workflow-Calls** zählen extra. |
| **Token?** | Direkt Anthropic-Kosten. Zeigt wo die KI angerufen wird. |
| **Was wird gespeichert?** | Persistenz-Punkt — danach ist der Schritt "überlebt". |
| **Wo sichtbar?** | Dashboard-Tab, damit User es selbst nachprüfen kann (ohne Coder). |
| **Stop/Weiter** | Macht die Stop-Punkte explizit (NoOp / Blocked / Duplicate). |

## Update-Regel

Wenn ein WF eine neue Version bekommt:
1. Steckbrief-Felder anpassen (Version, cron, aktiv)
2. Schritt-Tabelle: nur betroffene Zeilen ändern, **Versions-Datum unten erneuern**
3. Bei strukturellem Umbau (neue Phase): TL;DR auch anpassen
