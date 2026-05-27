# Pipeline Cascade — Inbox-Cascade bis Drive + Reconcile

> **Was passiert nach WF A2, wenn ein Doc mit `status='inbox'` in der DB liegt?**
> Schritt-für-Schritt für Nicht-Coder. Stand: **2026-05-27** (Iter 55: CSV-Skills v0.4/v0.5 6/6-Hardened, classify-party-role v0.6 AL-Hook, reconcile v0.4.2 Tiered-Threshold, Router v0.7.3 Skip-Aware, SG4 merge-duplicates, X2 mail-body-to-pdf).

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV Cascade Trigger** + **TGV Skill Router** + N Skills |
| Cascade-Trigger-Version | **v01.00** (Iter 15.1.c) |
| Skill-Router-Version | **v0.7.3** (Iter 54.B3 Skip-Aware: Skills mit `skipped`-Response werden korrekt als erledigt gewertet statt `skill.error`-Flood). Vorher v0.7.2 (Iter 42/44/48/49). |
| Datei | `07_TESTS/iter15_t1/deploy_cascade_trigger_v0100.py` + `07_TESTS/iter42/x1_deploy_router_v0701.py` + 13 Skill-Files |
| Aktiv | ✅ Cascade-Trigger (Webhook) · ✅ Skill-Router · 13 Skills aktiv |
| **Trigger (echt)** | **2 Pfade:** (a) Webhook `POST /webhook/tgv-cascade-trigger` (via Chatbot/MCP `run_inbox_cascade`) · (b) Schedule Daily 03:00 UTC — **derzeit DISABLED** als Safety-Net |
| n8n-Executions / Cascade-Run | **1 Exec für Cascade-Trigger** + **1 Exec pro Doc für Skill-Router** + **1 Exec pro Skill-Call**. → Bei 50 Inbox-Docs × 3 Skills = **~150 Execs**. ⚠️ **Quota-Hauptverbraucher.** |
| Token-Verbrauch | nur bei Skills die Claude rufen (`pdf-invoice-extract`, `contract-summary`, `tax-extract`). Typisch 1500–3000 Tokens pro RECHNUNG-Doc |
| Quota-Klasse | **HOCH.** Cascade ist der teuerste Teil des Systems. |

---

## 2. Die Schritte — präzise Tabelle

### Phase 1: Cascade-Trigger (1 Execution)

| # | Akteur (n8n-Node) | Was passiert | Eingang | Ausgang | API? | n8n-Exec? | Token? | Speichert wo? | Sichtbar in Dashboard | Stop/Weiter |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Webhook /tgv-cascade-trigger** ODER **Schedule 03:00** | Startet Cascade. Webhook bekommt `{batch_size, dry_run}` als Body. Schedule ist disabled | externer Call | Tick-Event | nein | startet 1 Exec | nein | — | Tab **System → Workflows** | Weiter |
| 2 | **Parse Trigger Input** | Liest `batch_size` (1-200, default 50) und `dry_run` (true/false) | Webhook-Body | Config-Object | nein | nein | nein | — | — | Weiter |
| 3 | **Supabase GET inbox docs** | `GET /documents?processing_state=eq.inbox&select=id,doc_type,provider,target_stream,skills_done_versions&order=id.desc&limit={batch_size}` | — | N Docs | Supabase-API | nein | nein | — | Tab **Documents** (Filter `status=inbox`) | Weiter |
| 4 | **DB-only Pre-Check + Summary** | Filtert Docs die **wirklich** Cascade brauchen. Vergleicht `documents.skills_done_versions[skillName]` mit `skill_definitions.version` — wenn neuer, dann re-run. **Spart Quota** indem schon erledigte Skills übersprungen werden | N Docs | N' ≤ N Docs | nein | nein | nein | — | Tab **Skill-History** (verlängert sich nach jedem Skill-Run) | Weiter |
| 5 | **IF dry_run or empty** | dry_run=true → nur Summary zurückgeben. Inbox leer → "kein Cascade nötig" | Flag | 2 Wege | nein | nein | nein | — | — | dry_run → 6; sonst 7 |
| 6 | **Respond Summary** | Antwortet JSON `{_summary: {total_inbox, would_trigger, doc_ids[]}}` | Summary | HTTP-Response | nein | nein | nein | — | als Chatbot-Antwort sichtbar | **STOP** (dry-run) |
| 7 | **Invoke Skill Router** (pro Doc) | `POST /webhook/tgv-skill-router` mit `{doc_id, _trigger: "cascade-15.1.c"}`. **Pro Doc 1 Call** — d.h. bei 50 Docs werden 50 HTTP-Requests gefeuert (parallel limitiert durch n8n) | je 1 Doc | Skill-Router-Response | n8n-internes Webhook | **+1 Exec pro Doc** (Skill-Router-WF) | nein | — | — | Weiter |
| 8 | **Aggregate Results** | Sammelt alle Skill-Router-Antworten | N Responses | 1 Aggregat | nein | nein | nein | — | — | Weiter |
| 9 | **Respond with Summary** | Antwortet `{triggered: N, results: [...]}` | Aggregat | HTTP-Response | nein | nein | nein | — | als Chatbot-Antwort + n8n-Log | **STOP** Cascade-Trigger fertig |

### Phase 2: Skill Router (1 Exec pro Doc)

| # | Akteur | Was passiert | Eingang | Ausgang | Token? | Speichert |
|---|---|---|---|---|---|---|
| R1 | **Webhook /tgv-skill-router** | Empfängt `{doc_id}` | doc_id | Trigger | nein | — |
| R2 | **Supabase GET doc** | Holt vollständige Doc-Zeile: `target_stream`, `entity`, `drive_file_id`, `confidence_score`, etc. | doc_id | Doc-Row | nein | — |
| R3 | **Lock-Pattern (Mig 047)** | Setzt `processing_state='processing'` ATOMIC mit Where-Clause, um Doppel-Runs zu verhindern (Pattern #1 seit Iter 18) | Doc | Lock-Status | nein | `documents.processing_state` |
| R4 | **Stream-Switch** | Routet basierend auf `target_stream`: RECHNUNG/STEUER → Invoice-Path · VERTRAG → Contract-Path · BANKING → CSV-Path · PROJEKT → Project-Path | Doc | 1 von 4 Wegen | nein | — |
| R5 | **Skill-Calls** (siehe Phase 3) | Feuert die entsprechenden Skill-Webhooks | Doc | Skill-Results | unterschiedlich | unterschiedlich |
| R6 | **State-Update** | `processing_state='triaged'` oder `'needs_review'` oder `'done'`. Updated `skills_done_versions` mit dem geleisteten Skill+Version | Skill-Result | DB-Update | nein | `documents` |
| R7 | **learning_events INSERT** | Schreibt 1 Zeile in `learning_events` (Iter 13): `doc_id, skill_id, version, result, duration_ms`. **Wichtig für Telemetrie + Auto-Learning** | Skill-Result | DB-Insert | nein | `learning_events` |
| R8 | **Response** | Antwortet an Cascade-Trigger | Result | HTTP-Response | nein | — |

### Phase 3: Skills (1 Exec pro Skill-Call)

> **Pre-Cascade-Skill `parse-docling`:** Office-Dokumente (DOCX/XLSX/PPTX/HTML)
> durchlaufen **vor** dem Orchestrator den Skill `tgv-parse-docling` — aufgerufen
> vom **WF B parse_docling-Branch** (siehe [Pipeline B](PIPELINE_B_DRIVE_DROP.md)),
> **nicht** vom Skill-Router. Er extrahiert den Text nach
> `documents.extracted_markdown`; danach läuft das Doc wie ein PDF durch
> Orchestrator + Router (Re-Triage, Iter 46.C2).

> **Pre-Cascade-Skill `pdf-text-snippet` (Iter 48.A1):** PDF-Dokumente aus der
> WF-B-`documents`-Route durchlaufen **vor** dem Orchestrator den Skill
> `tgv-pdf-text-snippet` (analog `parse-docling`). Er extrahiert die ersten
> 2000 Zeichen nach `documents.extracted_text_snippet` → der Orchestrator sieht
> den Inhalt schon beim ersten Plan-Lauf → korrekte Klassifikation + voller
> Skill-Plan inkl. `store-file-to-drive`. Vorher (Iter 47): Orchestrator plante
> mit leerem Snippet → Cold-Start-Plan ohne store-file → Doc landete un-gefilet
> in `needs_review`.

> **OCR-Fallback `pdf-ocr-fallback` (Iter 49.B1+B2 LIVE):** Wenn `pdf-text-snippet`
> einen Snippet < 50 chars liefert (= Scan-PDF, kein Text-Layer), ruft WF B v2
> direkt im documents-Branch den Skill `tgv-pdf-ocr-fallback` (n8n WF
> `zKjQkYKKmSe076KM`) auf. Der schickt das PDF an docling-serve mit `do_ocr=true`
> + Tesseract de+fr+en, schreibt den OCR-Text in `extracted_text_snippet` zurück
> → Orchestrator bekommt jetzt Inhalt zu sehen statt leerem Snippet.
> Caps: 20 MB File-Size, 120 s timeout, 3 retries, `onError=continueRegularOutput`.
> **Caveat:** OCR-Skill ist abhängig von docling-serve-Verfügbarkeit (Memory ⭐
> `project-docling-serve-sleep-502` für aktuelle Crash-Loop-Diagnose).

| Skill | Webhook | Was er tut | Token? | DB-Schreibt | Drive? |
|---|---|---|---|---|---|
| **parse-docling** v0.1 (Iter 46 · WF-B-invoked, *nicht* Router-dispatched) | `/webhook/tgv-skill-parse-docling` | DOCX/XLSX/PPTX/HTML → Markdown via self-hosted **docling-serve** (Railway EU). Setzt `extracted_markdown` + `extracted_text_snippet`. **Verändert `processing_state` NICHT** (Iter 46.C2) — die Re-Triage übernimmt der Orchestrator | nein (docling-serve, kein Claude) | `documents.extracted_markdown` + `agent_events` | nein |
| **store-file-to-drive** v0.7.1 (Iter 45.A1+B3+B4a, P2 Pattern Iter 43.D2) | `/webhook/tgv-skill-store-file-to-drive` | Lädt PDF aus DB (`documents.id` → holt Binär aus Mail-Cache oder vorhandenem Drive-Speicher) hoch nach `DOCUMENTS/{ENTITY}/{YEAR}/{MONTH}/`. Setzt `drive_file_id`, `drive_file_name`, `final_path`. **v0.6 (Iter 45.A1):** Build Supabase Patch Gate verschärft (final_path Pflicht, STORAGE_FAIL_STATES blocken), Merge Move/Upload best-effort `move_verified` Flag, `processing_state='done'` explicit (Mig-085-Race-Schutz), idempotent skip += `dbDoc.drive_file_id` (Phantom-Skip-Schutz). **v0.7 (Iter 45.B3):** `routing_target` Payload-Field unterstützt `'documents'` (default), `'parking_unsupported'`, `'parking_low_conf'`, `'parking_extraction_failed'` — bei PARKING-Routes wird der documents-Branch automatisch nach `DOCUMENTS/_PARKING/<sub>/` umgelenkt. **v0.7.1 (Iter 45.B4a):** processing_state per routing_target gemappt (documents→done, parking_unsupported→unsupported_format, parking_low_conf→needs_review, parking_extraction_failed→source_lost). Iter-44.B1 `target_subfolder` (Kreditor/Debitor/Transfer) bleibt für Subordner-Routing (Iter 46 Block C). **D2-Pattern P2:** emittiert `agent_event` pro Item | nein | `documents` + `agent_events` | ✅ |
| **resolve-supplier** v0.1 | `/webhook/tgv-skill-resolve-supplier` | Sucht in `kb_suppliers` per ILIKE + token-overlap fuzzy. Findet z.B. "IONOS SE" → supplier_id=564, category_l1=Betrieb | nein | `documents.supplier_id` | nein |
| **pdf-invoice-extract** v0.3 (Iter 43.A2 Recipient + **Iter 49.D2 Gutschrift-Detection**) | `/webhook/tgv-skill-pdf-invoice-extract` | Lädt PDF → Claude-API mit Vision/Document-API → extrahiert Betrag, Rechnungsdatum, Lieferant, Positionen + **Recipient**. **Iter 49.D2:** doc_type-Schema erweitert auf enum `Rechnung\|Gutschrift\|Quittung\|Zahlungsbeleg` + Detection-Regeln (Avoir/Credit Note/Rückerstattung → Gutschrift; Quittung-Kennzeichen → Quittung; Bestätigung ohne USt → Zahlungsbeleg). Marker `GUTSCHRIFT-DETECTION-v49D2`. | ✅ **1500-3000 Tok** | `documents` (Felder inkl. `recipient`, `doc_type` enum) + `ai_suggestion` | nein |
| **pdf-ocr-fallback** v0.1 (**Iter 49.B1** · WF-B-invoked, *nicht* Router-dispatched) | `/webhook/tgv-skill-pdf-ocr-fallback` | Scan-PDF (snippet leer) → docling-serve mit `do_ocr=true` + Tesseract de+fr+en → schreibt `extracted_text_snippet` (max 2000 chars). Caps: 20 MB file-size, 120 s timeout, 3 retries. **Lazy-trigger**: nur wenn `pdf-text-snippet` length<50 chars liefert. | nein (docling-serve OCR, kein Claude) | `documents.extracted_text_snippet` + `agent_events` | nein |
| **reconcile-payment** v0.4.2 (Iter 54.B Tiered-Threshold) | `/webhook/tgv-skill-reconcile-payment` | Sucht in `txn_master` Match auf entity + ABS(amount) + Datum + Provider-Overlap. **v0.4.0:** Terminal-Skip (amount=0, status=duplicate/source_lost) + amount=0 distinction. **v0.4.1:** Router v0.7.3 Skip-Aware (kein `skill.error`-Flood). **v0.4.2:** Tiered Threshold — provider_matched+conf>=85 → auto (nicht nur >=60). Live-Links #7402 IONOS + #6932 BOUYGUES verified | nein | `txn_master.document_id`, `documents.txn_id`, `documents.status='auto_reconciled'` | nein |
| **contract-summary** v0.1 | `/webhook/tgv-skill-contract-summary` | Lädt PDF → Claude → extrahiert Vertragspartner, Laufzeit, Kündigungsfrist, monatl. Betrag. Schreibt in `prf_contracts` | ✅ 2000-4000 Tok | `prf_contracts` + `documents.contract_id` | nein |
| **detect-duplicate** v0.1 | `/webhook/tgv-skill-detect-duplicate` | Sucht in `documents` nach Hash/Provider+Amount+Date-Match. Markiert Duplikate mit `status='duplicate'` | nein | `documents.status` | nein |
| **tax-extract** v0.2 | `/webhook/tgv-skill-tax-extract` | Erkennt Steuer-relevante Docs (Lohnsteuer, USt) und kennzeichnet sie für STEUERBERATER-Skill | ✅ 1000-2000 Tok | `documents.tax_relevant` | nein |
| **classify-csv** v0.4 (Iter 55.B1 6/6-Hardened) | `/webhook/tgv-skill-classify-csv` | Rule-based: BV_DE / BNP_FR / **GENERIC_DE_FR** / timetrack / unknown anhand Header-Anchors. **Iter 55.B1:** Volle 6-Pattern-Compliance (P1 DB-Lookup, P2 agent_events, P3 graceful_skip, P4 idempotency via `skills_done_versions`, P5 version_stamp, AL agent_decisions + `_suggestion`). Schreibt `csv_type` + `bank_format` direkt auf `documents`. | nein | `documents.csv_type` + `documents.bank_format` + `skills_done_versions` + `agent_events` + `agent_decisions` | nein |
| **import-banking-csv** v0.5 (Iter 55.B2 6/6-Hardened) | `/webhook/tgv-skill-import-banking-csv` | Parst CSV, INSERT in `txn_master`. Dedup auf booking_date+amount+counterparty. BV_DE+BNP_FR feste Spalten, GENERIC_DE_FR dynamische Spalten-Detection. **Iter 55.B2:** Volle 6-Pattern-Compliance (P1 DB-Lookup, P2 agent_events mit Import-Summary, P3 graceful_skip, P4 idempotency via `skills_done_versions`, P5 version_stamp, AL agent_decisions + `_suggestion`). | nein | `txn_master` (N Zeilen) + `skills_done_versions` + `agent_events` + `agent_decisions` | nein |
| **kb-learn** v0.3.1 | `/webhook/tgv-skill-kb-learn` | Schreibt `new_pattern_suggestion` aus Triage → `mail_processing_patterns_candidates`. Promoter (Iter 17) entscheidet ob → aktive Pattern | nein | `mail_processing_patterns_candidates`, ggf. `mail_processing_patterns` | nein |
| **monthly-closing-prep** v0.2 | `/webhook/tgv-skill-monthly-closing-prep` | Multi-Anker-Lücken-Detection: Vertrag, Letzter Monat, Vorjahr, User-Annotation, Chat. Iter 22 | nein | `monthly_gaps` | nein |
| **send-to-accountant** | `/webhook/tgv-buchhalter-versand` | Versendet Monatsbündel an Steuerberater (WF E v1.7.2) | nein | `documents.sent_to_accountant_at` | ✅ (PDF-Bundle) |
| **classify-party-role** v0.6 (Iter 54.Fr1 AL-Hook) | `/webhook/tgv-skill-classify-party-role` | DB-only: Klassifiziert `documents.party_role` (kreditor/debitor/transfer/intern). Provider+Recipient gegen `entity_signatures.tokens` (inkl. v0.4 `aliases TEXT[]`). Bank-Eigenbeleg-Prioritaet vor Recipient-Match. **v0.6 (Iter 54.Fr1):** Volles AL-Pattern mit `agent_decisions` POST + `_suggestion` Block in Response (Pattern #6, Matrix 6/6). | nein | `documents.party_role` + `agent_decisions` + `agent_events` | nein |
| **merge-duplicates** (SG4, Iter 53.D1) | `/webhook/tgv-skill-merge-duplicates` | Findet Duplikat-Cluster (gleicher Provider+Amount+Date, verschiedene IDs) und mergt sie (dry_run/apply-Mode). Iter 54.D1: n8n-WF `jhSkefNGBdT0xMi7` LIVE, dry_run smoke 0 clusters (Bestand sauber) | nein | `documents.status='duplicate'` (beim Merge) | nein |
| **mail-body-to-pdf** (X2, Iter 53+54.E1) | `/webhook/tgv-skill-mail-body-to-pdf` | Rendert HTML-Mail-Body als PDF via Gotenberg (Hetzner). Fuer Body-only-Mails ohne PDF-Anhang (z.B. Canva/Vercel-Receipts). 15-Node n8n-WF, idempotent. Erzeugt `MailBody_{doc_id}_{subject}.pdf` in Drive INBOX | nein | `documents.drive_file_id` + `drive_file_name` | ✅ |
| **store-file-to-drive (contracts)** | gleicher Webhook, `target_root=contracts` | Verschiebt Vertrag nach `CONTRACTS/{ENTITY}/` | nein | `documents.final_path` | ✅ |

---

## 3. FAQ — die wichtigsten Fragen

### Wie wird die Cascade konkret gestartet?
**3 Wege:**
1. **Chatbot:** "Cascade laufen lassen" → MCP-Tool `run_inbox_cascade` → Webhook
2. **MCP-direkt:** `mcp__tgv__run_inbox_cascade(batch_size=50, dry_run=False)`
3. **Schedule:** **derzeit aus** (war als Safety-Net 03:00 UTC geplant, aber Quota-Risiko zu groß → Iter 15 disabled)

### Wo sehe ich was die Cascade gerade macht?
| Sicht | Wo |
|---|---|
| Live-Status pro Doc | Tab **Documents** — Spalte `processing_state` (`inbox` → `processing` → `triaged`/`needs_review`/`done`) |
| Skill-Historie pro Doc | Tab **Skill-History** — zeigt welche Skills wann gelaufen sind |
| Quota-Verbrauch | Tab **Cost** — Executions/Tokens/EUR pro Skill |
| Fehler | n8n-Cloud-Console (Execution-Log) |
| Reconcile-Treffer | Tab **Reconcile-Queue** — zeigt vorgeschlagene + akzeptierte Matches |

### Token-Kosten konkret
Bei 50 Inbox-Docs mit Mix:
- 30 RECHNUNG × (pdf-invoice-extract 2000 Tok + reconcile 0) = **60.000 Tok**
- 5 VERTRAG × contract-summary 3000 Tok = **15.000 Tok**
- 10 BANKING × 0 (rule-based) = **0 Tok**
- 5 SONSTIGES × 0 = **0 Tok**
- **Summe: ~75.000 Tokens** ≈ **0.30–0.50 €** (Sonnet) bzw. **0.05–0.10 €** (Haiku)

Plus n8n: 50 Docs × ~3 Skills + 1 Cascade-Trigger + 1 Skill-Router pro Doc = **~200 Execs**.

### Quota-Schutz
- **`batch_size`-Limit:** max 200, default 50.
- **`dry_run`-Mode:** zeigt nur was *würde* passieren.
- **Versions-Skip:** Pre-Check (Schritt 4) überspringt Skills die schon erledigt sind.
- **Lock-Pattern:** verhindert dass ein Doc 2× parallel cascadet wird.

### Was wird der Cascade übergeben (Abgrenzung zu WF A2)?
**Nichts direkt.** Cascade liest nur **`documents.id` + Felder** aus der DB. Der Handoff-Contract aus WF A2 (`_tgv02_handoff`) wird **nicht weitergegeben** — er existiert nur im n8n-Item von A2. Die Cascade rekonstruiert alles aus DB-Spalten.

→ **Bedeutung:** Wenn WF A2 eine Information **nicht** in `documents` schreibt, ist sie für die Cascade verloren. Aktuell vermisst: `ai_request`-Full-Payload, `binary_keys`. (Verbesserungspunkt — siehe A2-Doc Sektion 8.)

### Multi-Skill pro Doc — wie geordnet?
- Skill-Router nutzt `skills_needed[]` aus dem Orchestrator-Output, sonst fällt er auf `LEGACY_MAP[target_stream]` zurück.
- **Reihenfolge LEGACY_MAP[RECHNUNG/STEUER] seit Iter 42.X (Router v0.7.1):**
  1. `tgv-store-file-to-drive` — **MUSS ZUERST** (sonst hat `pdf-invoice-extract` kein `drive_file_id`)
  2. `tgv-skill-detect-duplicate`
  3. `tgv-resolve-supplier`
  4. `tgv-pdf-invoice-extract` — braucht `drive_file_id` aus Schritt 1
  5. `tgv-reconcile-payment` — braucht `amount`/`invoice_date` aus Schritt 4
  6. `tgv-skill-upsert-contract-from-invoice`
- **Reihenfolge LEGACY_MAP[VERTRAG]:** `tgv-extract-contract-pdf` → `tgv-store-file-to-drive`
- **Reihenfolge LEGACY_MAP[BANKING]:** `tgv-classify-csv` → `tgv-import-banking-csv`
- **Reihenfolge LEGACY_MAP[TIMETRACK]:** `tgv-import-timetrack-csv`
- **Parallel?** Nein — sequenziell (SplitInBatches batch=1), weil spätere Skills auf Output früherer angewiesen sind.

> **Hintergrund Iter 42.X:** Pre-Iter-42-Reihenfolge war `[pdf-invoice-extract, detect-duplicate, resolve-supplier, reconcile-payment, upsert-contract, store-to-drive]` — `pdf-invoice-extract` lief vor `store-to-drive` und scheiterte am Pre-Skill-Check `requires_inputs=[drive_file_id]` → 53 % aller Rechnungen ohne `amount`. Promote v0.7.1 hat den Reorder live behoben (2026-05-20, 18/19 with-drive-Bestands-Docs nachträglich geheilt).

---

## 4. Was passiert NICHT (häufige Fehlannahmen)

| Mythos | Realität |
|---|---|
| "Cascade läuft automatisch alle 5 Min" | ❌ Nur auf Webhook-Trigger. Schedule disabled. |
| "Alle Docs in Inbox werden in 1 Run abgearbeitet" | ❌ Limitiert auf `batch_size` (default 50). Mehr → 2. Run nötig. |
| "PDF kommt sofort in Drive" | ❌ Erst wenn `store-file-to-drive` lief — Iter 48.B4 hat den BANKING-Stream defensive ergänzt (CSV-Move nach Import). Aktuell defensive für **RECHNUNG/STEUER** (Iter 44.F3) + **BANKING** (Iter 48.B4). Andere Streams (VERTRAG/PROJEKT/SONSTIGES) abhängig vom Orchestrator-Plan. |
| "Reconcile passiert immer" | ❌ Nur bei `auto_reconcile_confidence ≥ 60`. Sonst landet's in Reconcile-Queue für User. |
| "Skill-Calls sind kostenlos weil n8n" | ❌ Jeder Skill = 1 n8n-Execution (Quota) **+** ggf. Anthropic-Tokens. |
| "Cascade kann doppelt laufen für 1 Doc" | ❌ Lock-Pattern (`processing_state='processing'`) blockt das. |

---

## 5. Was der User selbst sehen/ändern kann

| Was | Wo im Dashboard | Editierbar? |
|---|---|---|
| Inbox-Queue (Docs mit `status=inbox`) | Tab **Documents** — Filter | nein |
| Skill-Historie pro Doc | Tab **Skill-History** | nein |
| Reconcile-Queue | Tab **Reconcile-Queue** | ✅ accept/reject |
| Skill-Definitions (Versions) | Tab **System → Skills** | aktuell nur SQL |
| `kb_suppliers` (256 Zeilen) | Tab **Suppliers** | aktuell nur SQL |
| Cascade manuell starten | Chatbot: "Cascade auf 20 Docs" | ja |
| Drive-Ordner-Inhalt | Google Drive direkt | ja (Datei verschieben triggert NICHT die DB-Update) |

---

## 6. Limits + Hard-Coded-Konstanten

| Limit | Wert | Quelle |
|---|---|---|
| `batch_size` max | 200 | MCP-Tool + Cascade-Trigger |
| `batch_size` default | 50 | MCP-Tool |
| Skill-Call-Timeout | 60 Sek | Cascade-Trigger Node |
| Reconcile-Datumsfenster | ±90 Tage (Skill v0.1) bzw. ±45 (Legacy) | Skill-Code |
| Reconcile-Confidence-Threshold | ≥60 für auto, sonst manual | Skill v0.1 |
| Drive-Pfad RECHNUNG | `DOCUMENTS/{ENTITY}/{YEAR}/{MONTH}/` | `store-file-to-drive` v0.3 |
| Drive-Pfad VERTRAG | `CONTRACTS/{ENTITY}/` | gleich |
| Confidence-Threshold "inbox" vs "pending_review" | 70 (aus WF A2) | A2 v01.27 |

---

## 7. TL;DR — die 3 Phasen

1. **EINSAMMELN** (1–4): Inbox-Docs aus DB holen, Pre-Check welche überhaupt müssen
2. **VERTEILEN** (5–9): Pro Doc → Skill-Router → richtigen Skill aufrufen
3. **AUSFÜHREN** (R1–R8, Phase 3): Skill arbeitet, schreibt Ergebnis in DB + ggf. Drive

---

## 8. Verbesserungs-Punkte (für künftige Iters)

| Befund | Vorschlag | Iter? |
|---|---|---|
| Schedule disabled — keine Auto-Verarbeitung | Nightly 03:00 UTC re-aktivieren wenn Quota-Reserve > 400 | 25 |
| Skill-Routing hard-coded in Router (Stream-Switch) | Tabelle `skill_routing_rules` analog zu `mail_routing_rules` | 25+ |
| Skill-Versions-Drift schwer sichtbar | Dashboard-Widget "Skills mit Version-Lag pro Doc" | 24-25 |
| Cascade-Trigger kennt keinen `priority`-Filter | High-confidence-Docs zuerst durch | 25 |
| `learning_events` nicht im Dashboard | Tab **Learning** mit Skill-Trefferquote-Trend | 24 |
| Reconcile-Confidence-Formel hard-coded | Tabelle `reconcile_scoring_weights` editierbar | 25+ |

---

## 9. Cascade ≠ Heilung — wenn ein Doc hängt

> **Merksatz:** Die Cascade ist **kein Heiler**, sondern der **Verteiler**. Sie liest nur
> `processing_state='inbox'`-Docs und weckt den **Skill-Router**. Der Router ohne Plan
> (`target_stream='UNBEKANNT'`) findet nichts → das Doc bleibt hängen. Das *denkende
> Gehirn* ist der **Orchestrator** — nur er erzeugt den Plan.

→ **Ein un-triagiertes Doc heilt die Cascade nicht.** Heilung = direkter **Orchestrator**-Trigger.
Und: die Cascade sieht `triaged`-Docs **gar nicht** (sie filtert strikt `inbox`) — `triaged`-Zombies brauchen immer einen direkten Trigger.

| Symptom (`processing_state` + `target_stream`) | Heilung |
|---|---|
| `inbox` + `UNBEKANNT` | **Orchestrator**-Trigger (re-triage) → dann Router |
| `inbox` + Stream gesetzt | normale Cascade (`run_inbox_cascade`) |
| `triaged` + Stream gesetzt | **Skill-Router** direkt |
| `triaged` + `UNBEKANNT` | **Orchestrator** zuerst, dann Router |
| `processing` (alt) | `processing_state` → `inbox` zurücksetzen, dann re-cascade |
| `needs_review` | keine Heilung — User-Review |
| `source_lost` / `unsupported_format` | nicht/anders heilbar (Re-Import / Re-Route) |

**Stuck-Docs finden:** `python 08_OPS/audit_stuck_docs.py` — listet alle Zombies mit
Heil-Empfehlung (Orchestrator vs. Router). Voller Heil-Runbook:
`07_TESTS/iter47/C_RUNBOOK_CASCADE_VS_HEILUNG.md` (Iter 47.C).

---

*Stand: 2026-05-27 · Quelle: `07_TESTS/iter15_t1/deploy_cascade_trigger_v0100.py` + `07_TESTS/iter42/x1_deploy_router_v0701.py` + Skill-Deploy-Scripts · Iter 53: SG4 merge-duplicates + X2 mail-body-to-pdf · Iter 54: reconcile v0.4.2, Router v0.7.3 Skip-Aware, classify-party-role v0.6 AL-Hook · Iter 55.B: classify-csv v0.4 + import-banking-csv v0.5 (6/6 Pattern-Hardened)*
