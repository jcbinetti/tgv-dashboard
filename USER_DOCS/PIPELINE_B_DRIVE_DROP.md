# Pipeline B — Drive-Drop Intake

> **Was passiert, wenn der User eine Datei manuell in den Drive-Ordner `INBOX/` legt?**
> Schritt-für-Schritt für Nicht-Coder. Stand: **2026-05-22** (Iter 46.C — Multi-Format-Parsing + Re-Triage live).

> 📚 **Lern-Box — „MIME-Typ"**: Jede Datei hat einen technischen Typ-Stempel
> (z.B. `application/pdf` für PDF, `…wordprocessingml.document` für DOCX). WF B
> liest diesen Stempel, um zu entscheiden, welchen Weg die Datei nimmt. Wenn der
> Stempel fehlt/unzuverlässig ist, schaut WF B ersatzweise auf die Datei-Endung
> (`.pdf`, `.docx`, …).

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV WF B v2 Drive Adapter (thin)** |
| n8n-ID | `KRNRcSLSUiVC8nTW` |
| Nodes | **17** (Iter 46.C: +3 parse_docling-Re-Triage-Nodes) |
| Aktiv | ✅ ja |
| **Trigger** | (a) **Schedule** — alle **24 Stunden** (Quota-Schonung, by-design seit Iter 43) · (b) **Webhook** `POST /webhook/tgv-wf-b-v2-trigger` für Ad-hoc-Pickup |
| Quelle | Google Drive TGV-CORE Shared-Drive, Ordner **`INBOX`** (`1wH4pl4uguwvIYbZrMU0QlJtjVpaaL7bF`) |
| Modell | **Thin Adapter** — WF B macht nur Intake + MIME-Routing; die eigentliche Klassifikation/Verarbeitung machen Orchestrator + Skill-Router (inline aufgerufen). |
| n8n-Executions | 1 Exec pro Tick. Leerer INBOX = 1 Exec, 0 Folge-Calls. Pro Datei zusätzlich: Orchestrator-, Router- und Skill-Calls. |
| Token-Verbrauch | 0 wenn INBOX leer. Pro Datei: 1 Orchestrator-Claude-Call (~1.000–2.000 Tok, Haiku) + ggf. Skill-Tokens. |

> ℹ️ **Legacy-Hinweis:** Der frühere **WF B v3** (`c7B4trQwfyRFVm8m`, Cron alle 15 Min,
> eigene CSV/PDF-Parser) ist seit Iter 25+ **gelöscht**. Falls in älteren Dokumenten
> noch von „v3", „15-Min-Cron" oder `c7B4trQwfyRFVm8m` die Rede ist — das ist
> historisch. Aktiv ist ausschließlich das hier beschriebene v2-thin-Modell.

---

## 2. Die Schritte — präzise Tabelle

| # | Akteur (n8n-Node) | Was passiert | n8n-Exec? | Token? | Speichert wo? | Stop/Weiter |
|---|---|---|---|---|---|---|
| 1 | **⏰ Schedule INBOX** (24 h) **oder** **Webhook Manual Trigger** | Weckt den WF | startet 1 Exec | nein | — | Weiter |
| 2 | **📁 Drive List INBOX** | Listet **alle** Dateien im INBOX-Ordner (kein Datums-Filter) | nein | nein | — | Weiter |
| 3 | **🧹 Dedup Filter** | Pro Datei: (a) ist sie schon in `documents`? → raus (Dedup auf `drive_file_id` **und** `drive_file_name`). (b) **MIME-Klassifikation**: setzt `_mime_routing_target` ∈ `documents` / `parse_docling` / `parking_unsupported` — inkl. Endungs-Fallback wenn der Drive-MIME-Typ unzuverlässig ist | nein | nein | — | Weiter |
| 4 | **🔀 IF Has New Files** | Gibt es nach Dedup noch Dateien? | nein | nein | — | nein → **STOP** (NoOp) · ja → Weiter |
| 5 | **💾 INSERT Documents v2** | Pro neue Datei 1 Zeile in `documents`: `source='gdrive'`, `processing_state='inbox'`, `status='pending_review'`, `doc_type='Sonstiges'`, `target_stream='UNBEKANNT'`, `entity='privat'` | nein | nein | ✅ **`documents`** | Weiter |
| 6 | **🏷️ Capture Doc Id** | Merkt sich die neue `documents.id` (`_doc_id`) und reicht das MIME-Routing-Ziel weiter | nein | nein | — | Weiter |
| 7 | **🧭 Route By MIME** | 3-Wege-Switch auf `_mime_routing_target` → siehe Abschnitt 3 | nein | nein | — | 1 von 3 Routen |

Ab Schritt 7 verzweigt der WF in die **3 MIME-Routen** (Abschnitt 3).

---

## 3. Der MIME-Branch — 3 Routen

WF B v2 schickt jede Datei je nach Datei-Typ auf genau **einen** von drei Wegen:

| Route | Formate | Was passiert | Node-Kette |
|---|---|---|---|
| **`documents`** | PDF · CSV · JPEG · PNG · GIF · WEBP | Normale Pipeline: Orchestrator klassifiziert (Vertrag/Rechnung/…) → Skill-Router ruft die geplanten Skills | `POST Orchestrator` → `Capture Plan` → `POST Skill Router` |
| **`parse_docling`** | DOCX · XLSX · PPTX · HTML / XHTML | **Erst** Skill `tgv-parse-docling` (extrahiert Text → `documents.extracted_markdown`), **dann** Re-Triage über Orchestrator + Skill-Router — danach läuft das Office-Doc wie ein PDF | `POST Parse Docling` → `POST Orchestrator Docling` → `Capture Plan Docling` → `POST Skill Router Docling` |
| **`parking`** | alles andere (HEIC · EML · MSG · ZIP · Google-Docs/Sheets · …) | Datei → `DOCUMENTS/_PARKING/unsupported_format/`, Doc-Zeile bekommt `processing_state='unsupported_format'` (Mig 089). Nichts wird „still ignoriert" | `POST Store-File Parking` |

**Wie wird der Typ erkannt?** Der `Dedup Filter` prüft zuerst den Drive-MIME-Typ.
Weil Drive bei manchen Dateien einen unzuverlässigen Typ liefert (z.B. PDFs als
`octet-stream`), gibt es einen **Endungs-Fallback**: erkennt Drive den Typ nicht,
entscheidet die Datei-Endung (`.pdf`, `.docx`, `.xlsx`, `.pptx`, `.html`, …).
Dieser Fallback wurde in Iter 46.C1 eingebaut, nachdem PDFs fälschlich nach
PARKING gerieten.

> 🆕 **Iter 46 — Multi-Format-Parsing:** Vor Iter 46 landeten DOCX/XLSX/PPTX/HTML
> im PARKING („Format nicht unterstützt"). Seit Iter 46 werden sie vom Skill
> `tgv-parse-docling` (self-hosted docling-serve) in Markdown-Text umgewandelt und
> dann ganz normal klassifiziert. **PNG/JPG-OCR** ist noch nicht über docling
> abgedeckt (Bilder gehen weiter über die `documents`-Route / Claude-Document-API).
> **EML/MSG** bleiben vorerst im PARKING (→ Iter 47, Apache Tika).

---

## 4. Übergabe — wie geht es weiter?

**WF B v2 ruft Orchestrator und Skill-Router direkt selbst auf** (inline, kein
Warten auf einen separaten Cascade-Tick). Der genaue Ablauf von Orchestrator und
Skill-Router ist in der [Cascade-Doku](PIPELINE_CASCADE.md) beschrieben.

**Die Datei bleibt zunächst in `INBOX/` liegen.** Der Skill `store-file-to-drive`
(vom Skill-Router aufgerufen) schreibt den finalen Pfad und **verschiebt** die
Datei von `INBOX/` nach `DOCUMENTS/{ENTITY}/{JAHR}/{MONAT}/` bzw. `CONTRACTS/…`
bzw. `DOCUMENTS/_PARKING/<sub>/`.

→ **Wichtig:** Verschwindet die Datei nach einem Lauf **nicht** aus `INBOX/`, hat
ein Skill etwas nicht abgeschlossen (Fehler / Manual-Review nötig).

> ✅ **PARKING-Pfad LIVE (seit Iter 45.B4):** `DOCUMENTS/_PARKING/` mit Unterordnern
> `unsupported_format/`, `low_confidence/`, `extraction_failed/`. Liegt unter
> `DOCUMENTS/` (nicht direkt im TGV-CORE-Root — Service-Account-Permission).

---

## 5. FAQ

### Wie oft läuft WF B?
- **Schedule alle 24 Stunden** — eine Exec pro Tag, auch wenn INBOX leer ist.
- Das ist **Absicht** (Quota-Schonung, by-design seit Iter 43): Drive-Drops sind
  selten, ein 15-Min-Cron würde nur Leerläufe produzieren.
- Wer **sofort** verarbeiten will: Webhook `POST /webhook/tgv-wf-b-v2-trigger`
  manuell auslösen (Ad-hoc-Pickup).

### Welche Datei-Formate werden verarbeitet?
| Format | Route | Verarbeitung |
|---|---|---|
| **PDF** | `documents` | Claude-Klassifikation über Orchestrator |
| **Bilder** (PNG/JPG/GIF/WEBP) | `documents` | wie PDF (Claude-Document-API) |
| **CSV** | `documents` | rule-based BV_DE / BNP_FR / timetrack |
| **DOCX / XLSX / PPTX / HTML** | `parse_docling` | `tgv-parse-docling` → Markdown → dann normale Klassifikation |
| **HEIC / EML / MSG / ZIP / Google-Docs** | `parking` | → `_PARKING/unsupported_format/`, sichtbar in der DB |

→ **Nichts wird mehr „still ignoriert".** Jede Datei bekommt eine `documents`-Zeile.

### Dedup — passiert da was?
- WF B prüft **vor** dem Insert, ob die Datei (per `drive_file_id` **oder**
  `drive_file_name`) schon in `documents` existiert — wenn ja, kein neuer Eintrag.
- Inhaltsgleiche Dateien mit **anderem** Namen erkennt erst der Cascade-Skill
  `detect-duplicate`.

### Wer kann was in INBOX legen?
- Service Account `tgv-n8n-service` (Content Manager) und Jean-Chris Binetti.
- `INBOX/` liegt auf dem TGV-CORE Shared Drive, nicht öffentlich.

### Mail ↔ Drive — gibt es eine Verknüpfung?
**Nein, getrennte Pfade.** WF-B-Docs haben `source='gdrive'`, WF-A2-Docs
`source='email'`. Kein Cross-Source-Dedup: dasselbe PDF per Mail **und** per
Drive-Drop → 2 Doc-Zeilen.

---

## 6. Was passiert NICHT (Mythen-Buster)

| Mythos | Realität |
|---|---|
| „WF B läuft alle 15 Minuten" | ❌ Alle **24 h** (Schedule) + Webhook für Ad-hoc. Der 15-Min-Cron war WF v3 (gelöscht). |
| „WF B ignoriert DOCX/XLSX" | ❌ Seit Iter 46 → Route `parse_docling` → Text wird extrahiert + klassifiziert. |
| „DOCX-Verträge werden vollständig ausgelesen" | ⚠️ Der **Text** wird extrahiert (`extracted_markdown`) und das Doc als Vertrag klassifiziert + abgelegt. Die **strukturierte** Vertragsdaten-Extraktion (`tgv-extract-contract-pdf`) kann aktuell nur PDF — Markdown-Konsum → Iter 47. |
| „Datei wandert automatisch in den Entity-Ordner" | ❌ Erst der Skill `store-file-to-drive` verschiebt sie. WF B liest nur. |
| „WF B ist token-frei" | ❌ Pro Datei läuft mindestens 1 Orchestrator-Claude-Call. |

---

## 7. Was der User selbst sehen/ändern kann

| Was | Wo | Editierbar? |
|---|---|---|
| INBOX-Ordner-Inhalt | Google Drive **TGV-CORE/INBOX** | ✅ Dateien dazu/weg |
| Verarbeitete Docs | Tab **Documents**, Filter `source=gdrive` | Stream/Entity korrigierbar |
| PARKING-Inhalt | Drive **DOCUMENTS/_PARKING/** + Tab Documents (`processing_state=unsupported_format`) | read |
| WF B aktivieren/deaktivieren | n8n-Cloud-Console | ja |
| Ad-hoc-Lauf auslösen | Webhook `tgv-wf-b-v2-trigger` | ja |

---

## 8. TL;DR — die 4 Phasen

1. **SCANNEN** (1–2): alle 24 h (oder per Webhook) den INBOX-Ordner listen.
2. **DEDUP + MIME** (3–4): Bekanntes raus, jede neue Datei mit Routing-Ziel taggen.
3. **EINSPEISEN** (5–6): `documents`-Zeile anlegen (`processing_state='inbox'`).
4. **ROUTEN** (7 + Abschnitt 3): `documents` → Orchestrator · `parse_docling` →
   parse-docling + Re-Triage · `parking` → `_PARKING/`.

---

## 9. Verbesserungspunkte

| Befund | Vorschlag | Iter? |
|---|---|---|
| `tgv-extract-contract-pdf` / `tgv-pdf-invoice-extract` können kein Markdown — geparste Office-Docs werden klassifiziert+abgelegt, aber nicht strukturiert ausgelesen | Extract-Skills `extracted_markdown` lesen lassen | 47 |
| PNG/JPG-OCR nicht über docling (Railway-RAM) | Railway-Upgrade oder Hetzner-Pivot | 47 |
| EML/MSG → PARKING | Apache Tika anbinden | 47 |
| Google-Docs/Sheets landen im PARKING | Export-nach-PDF vor dem Routing | später |
| INBOX-Liegenbleiber unsichtbar | Dashboard-Widget „INBOX-Files älter als 24 h" | 47+ |

---

*Stand: 2026-05-22 · Aktive WF: `KRNRcSLSUiVC8nTW` „TGV WF B v2 Drive Adapter (thin)" — 17 Nodes, 3-Wege-MIME-Branch (Iter 46.C) · Legacy `c7B4trQwfyRFVm8m` v3 gelöscht.*
