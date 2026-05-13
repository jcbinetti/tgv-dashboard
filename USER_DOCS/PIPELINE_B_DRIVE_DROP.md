# Pipeline B — Drive-Drop Intake

> **Was passiert wenn der User eine Datei manuell in den Drive-Ordner `INBOX/` legt?**
> Schritt-für-Schritt für Nicht-Coder. Stand: 2026-05-13.

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV — B. Google Drive Scanner Intake** |
| Version | **V3 Persistence Fixed** |
| n8n-ID | `c7B4trQwfyRFVm8m` |
| Datei | `TGV -App files/n8n_workflow_B_gdrive_scanner_intake_v3_persistence_fixed.json` |
| Aktiv | ✅ ja (Iter 18: Auto-trigger 12:00 daily fixed) |
| **Trigger (echt)** | **Cron `*/15 * * * *` = alle 15 Minuten** (`minutesInterval: 15`). Plus Webhook für Manual-Trigger |
| Quelle | Google Drive Shared-Drive `0AK457tJJQWBsUk9PVA`, Ordner **`INBOX`** (`1wH4pl4uguwvIYbZrMU0QlJtjVpaaL7bF`) |
| n8n-Executions / Tick | **1 Exec** pro Tick (alle inline). → 96 Execs/Tag = **2.880/Monat**. ⚠️ **Hauptquota-Fresser** wenn INBOX leer ist |
| Token-Verbrauch / Tick | 0 wenn INBOX leer. Pro PDF: **1 Claude-Call** (~1500-3000 Tok). CSV: 0 (rule-based) |

---

## 2. Die Schritte — präzise Tabelle

| # | Akteur (n8n-Node) | Was passiert | Eingang | Ausgang | API? | n8n-Exec? | Token? | Speichert wo? | Sichtbar in Dashboard | Stop/Weiter |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **⏰ Alle 15 Minuten** | Schedule-Trigger weckt den WF | — | Tick | nein | startet 1 Exec | nein | — | Tab **System → Workflows** | Weiter |
| 2 | **⚙️ Filter-Query bauen** | Baut Drive-API-Query: `'INBOX_FOLDER_ID' in parents and trashed=false` | — | Query-String | nein | nein | nein | — | — | Weiter |
| 3 | **📁 Google Drive — Neue Dateien** | `GET drive/v3/files?q=...` listet **ALLE** Dateien in INBOX (nicht nur neue! V3 hat keine modifiedTime-Cutoff) | Query | Array Files | Google-Drive-API | nein | nein | — | — | Weiter (auch wenn leer) |
| 4 | **🔀 Dateien aufteilen** | 1 Drive-Response mit N Files → N Items | Array | N Items | nein | nein | nein | — | — | Weiter, oder STOP wenn 0 Files |
| 5 | **🧭 Supported File Triage V2** | Pro Item: Filtert Google-Doc/Sheet (`vnd.google-apps.*`) und Ordner raus. Behält nur PDF/Image und CSV. Setzt `file_kind='csv'` oder `'pdf'` | Item | Item + file_kind | nein | nein | nein | — | — | Weiter wenn supported |
| 6 | **🧭 Supported File Route V2** | Switch: `file_kind='csv'` → 7a; `'pdf'` → 7b | Item | 1 von 2 | nein | nein | nein | — | — | Weiter |
| 7a | **📊 GDrive CSV Parsen** | Lädt CSV-Inhalt aus Drive, parst Header+Rows | Item | Rows-Array | Drive-API | nein | nein | — | — | Weiter |
| 7b | **⚙️ PDF für Claude vorbereiten** | Lädt PDF-Bytes, base64-encodet für Claude-Document-API | Item | Item + b64-PDF | Drive-API | nein | nein | — | — | Weiter |
| 8a | **🏷️ GDrive CSV Klassifizieren** | Rule-based: Filename + Header → BV_DE / BNP_FR / timetrack / unknown (siehe `feedback_banking_csv_routing`) | Rows | csv_format + entity | nein | nein | nein | — | — | Weiter |
| 8b | **🤖 Claude — PDF klassifizieren** | `POST api.anthropic.com/v1/messages` mit PDF-base64. Modell Sonnet 4.6. Claude liefert: stream/entity/provider/amount/date_document/category | b64-PDF | Claude-JSON | ✅ **Claude API** | nein | ✅ **~2000 Tok/Call** | — | indirekt: später Tab Documents | Weiter |
| 9a | **📦 CSV Array zusammenfassen** | Bündelt N Rows zu 1 Insert-Payload | Rows | Bulk-Array | nein | nein | nein | — | — | Weiter |
| 9b | **📋 GDrive Claude Antwort** | Parst Claude-JSON, baut DB-Datensatz | Claude-Response | Doc-Object | nein | nein | nein | — | — | Weiter |
| 10a | **💾 Supabase — txn_master (GDrive CSV)** | INSERT N Zeilen in `txn_master` mit dedup auf `booking_date+amount+counterparty_raw` | Bulk | DB-Insert | Supabase | nein | nein | ✅ **`txn_master`** | Tab **Transactions** | Weiter |
| 10b | **💾 Supabase — documents (GDrive)** | INSERT in `documents` mit `source='gdrive'`, `drive_file_id`, `drive_file_name`, `final_path` | Doc | DB-Insert | Supabase | nein | nein | ✅ **`documents`** | Tab **Documents** (Filter `source=gdrive`) | Weiter |
| 11 | **Intake Capture/Light/Routing/Drive-Versioning** (4 Sub-Nodes) | Schreibt Audit-Trail: `input_packages`, `input_items`, `file_versions`, `routing_decisions` | Doc | DB-Inserts | Supabase | nein | nein | ✅ 4 Tabellen | Tab **System → Intake-Audit** | Weiter |
| 12 | **Intake Build Records V2** | Baut finales Audit-Aggregat | — | Summary | nein | nein | nein | — | — | **STOP** WF fertig |

---

## 3. Übergabe an die Cascade

**Nicht direkt — gleicher Polling-Mechanismus wie WF A2.** WF B schreibt `documents` mit `status='inbox'`. Die [Cascade](PIPELINE_CASCADE.md) übernimmt im nächsten Cascade-Tick.

**Unterschied zu WF A2:** WF B **lädt die Datei NICHT erneut auf Drive hoch** — sie liegt ja schon in `INBOX/`. Stattdessen schreibt der Skill `store-file-to-drive` (Cascade) den finalen Pfad und **verschiebt** die Datei von `INBOX/` nach `DOCUMENTS/{ENTITY}/{YEAR}/{MONTH}/`.

→ **Wichtig:** Nach erfolgreicher Cascade verschwindet die Datei aus `INBOX/` automatisch. Wenn sie liegen bleibt = Cascade hat etwas nicht verarbeitet (Skill-Fehler, Manual-Review nötig).

---

## 4. FAQ

### Quota-Warnung
- **Cron alle 15 Min** = 96 Ticks/Tag = 2.880/Monat **selbst wenn INBOX dauerhaft leer ist**.
- Vergleich: WF A2 = 60 Execs/Monat (alle 12 h).
- **Iter 12 Quota-Welle** hat diese Frequenz nicht reduziert — Begründung: User erwartet "binnen 15 Min sichtbar".
- **Optimierungsidee Iter 25+:** auf 1× pro Stunde (24/Tag = 720/Monat) reduzieren wenn INBOX-Drop selten passiert.

### Welche Datei-Formate werden verarbeitet?
| Erkannt | Pfad | Skill |
|---|---|---|
| **PDF** | Schritt 7b/8b | Claude-Klassifikation |
| **Bilder** (PNG/JPG/…) | wie PDF (Claude-Document-API verarbeitet Bilder) | Claude |
| **CSV** | Schritt 7a/8a | Rule-based BV_DE/BNP_FR/timetrack |
| **Google Docs/Sheets/Slides** | **ignoriert** (vnd.google-apps.*) | — |
| **Ordner** | ignoriert | — |
| **Andere** (DOCX, XLSX, ZIP…) | **ignoriert in v3** | — |

→ **Bedeutung:** Wenn der User ein .docx oder .xlsx in INBOX legt, wird es **nicht verarbeitet** und bleibt unbemerkt liegen.

### Dedup — passiert da was?
- **CSV:** ja, auf `(booking_date, amount, counterparty_raw)` in `txn_master` Unique-Constraint.
- **PDF:** **schwächer** — nur über `drive_file_id` (jede neue Drive-Datei = neues Doc). Wenn User dieselbe PDF 2× nach INBOX kopiert → 2 Docs in DB. Erst der Cascade-Skill `detect-duplicate` (Iter 16) markiert das als Dup.

### Wer kann was in INBOX legen?
- **Service Account** `tgv-n8n-service` (Content Manager) — kann auch löschen
- **Jean-Chris Binetti** persönlich
- **Niemand sonst** — `INBOX/` ist auf TGV-CORE Shared Drive, nicht öffentlich

### Mail↔Drive — gibt's Verknüpfung?
**Nein, getrennte Pfade.** WF B-Docs haben `source='gdrive'`, WF A2-Docs `source='email'`. Es gibt **keine** Cross-Source-Dedup. Wenn ein PDF erst per Mail kommt und der User es dann zusätzlich nach INBOX legt → 2 Docs in DB (mit unterschiedlichen `drive_file_id`).

### Audit-Trail — was wird wo gespeichert?
| Tabelle | Inhalt |
|---|---|
| `input_packages` | Pro Drive-Scan ein Eintrag: wann, wie viele Files |
| `input_items` | Pro File ein Eintrag: filename, mimetype, hash |
| `file_versions` | Versions-History bei Re-Uploads gleichen Dateinamens |
| `routing_decisions` | Pro File die getroffene Klassifikation (Stream, Entity) |
| `documents` | Der finale Doc-Datensatz (1 Zeile pro File) |
| `txn_master` | Bei CSV: N Zeilen Transaktionen |

→ Tab **System → Intake-Audit** zeigt diese 4 Audit-Tabellen.

---

## 5. Was passiert NICHT (Mythen-Buster)

| Mythos | Realität |
|---|---|
| "WF B sieht nur neue Dateien" | ❌ V3 hat keinen modifiedTime-Filter — listet **alle** in INBOX. Dedup über DB. |
| "WF B verarbeitet auch DOCX" | ❌ Nur PDF/Bild/CSV. Andere Formate werden still ignoriert. |
| "Datei wird automatisch nach Entity-Ordner verschoben" | ❌ Erst die Cascade macht das (`store-file-to-drive`). WF B liest nur. |
| "WF B ist token-frei" | ❌ Jede PDF kostet Claude-Tokens. |

---

## 6. Was der User selbst sehen/ändern kann

| Was | Wo | Editierbar? |
|---|---|---|
| INBOX-Ordner-Inhalt | Google Drive **TGV-CORE/INBOX** | ✅ Files dazu/weg |
| Verarbeitete Docs | Tab **Documents** Filter `source=gdrive` | Stream/Entity korrigierbar |
| Intake-Audit | Tab **System → Intake-Audit** | nein (read) |
| WF B aktivieren/deaktivieren | n8n-Cloud Console | ja |

---

## 7. TL;DR — die 4 Phasen

1. **SCANNEN** (1–4): alle 15 Min Drive-INBOX listen
2. **TRIAGE** (5–6): PDF vs. CSV vs. ignorieren
3. **KLASSIFIZIEREN** (7a/b–9a/b): CSV per Regel · PDF per Claude
4. **EINSPEISEN** (10–12): DB-Insert + Audit-Trail. Cascade übernimmt.

---

## 8. Verbesserungspunkte

| Befund | Vorschlag | Iter? |
|---|---|---|
| 15-Min-Cron zu häufig wenn leer | Stündlich (96→24/Tag, −2.160 Execs/Monat) | 25 |
| DOCX/XLSX still ignoriert | Whitelist-Erweiterung + User-Warnung "Format nicht unterstützt" | 25+ |
| PDF-Dedup nur über drive_file_id | Content-Hash-Dedup wie A2 | 25+ |
| Kein Cross-Source-Dedup Mail↔Drive | `detect-duplicate` auch nach WF B feuern | bereits Cascade, prüfen |
| INBOX-Liegenbleiber unsichtbar | Dashboard-Widget "INBOX-Files älter als 24h" | 24-25 |

---

*Stand: 2026-05-13 · Quelle: `TGV -App files/n8n_workflow_B_gdrive_scanner_intake_v3_persistence_fixed.json` · Iter 24*
