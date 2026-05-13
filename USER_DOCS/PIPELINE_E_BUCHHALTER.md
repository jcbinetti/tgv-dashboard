# Pipeline E — Buchhalter-Versand (Monats-Bundle)

> **Was passiert wenn am Monatsende die Rechnungen an den Steuerberater geschickt werden?**
> Schritt-für-Schritt für Nicht-Coder. Stand: 2026-05-13.

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV Workflow E — Buchhalter Versand** |
| Version | **v1.7.2** (LIVE laut CLAUDE.md) — neueste im Repo `v2.0_PROD_20260503` (ggf. nicht deployed) |
| n8n-ID | `YvTqsmvC4lpgylDH` |
| Datei | `TGV -App files/TGV_Workflow_E_v1.7.2_DEPLOY.json` (live) bzw. `v2.0_PROD` (neueste im Repo) |
| Aktiv | ✅ ja |
| **Trigger** | **Webhook `POST /webhook/tgv-buchhalter-versand`** — manuell aus Chatbot/MCP |
| Body | `{ entity: string, month: int 1-12, year: int, force_resend?: bool, allow_legacy_sent?: bool, include_test_docs?: bool }` |
| n8n-Executions / Call | **1 Exec** für Versand-WF + N Drive-Downloads. **kein Skill-Call** (eigenständige Pipeline) |
| Token-Verbrauch | **0 — Token-frei.** Reines DB+Drive+SMTP |

---

## 2. Die Schritte — präzise Tabelle

| # | Akteur | Was passiert | Eingang | Ausgang | API? | n8n-Exec? | Token? | Speichert wo? | Sichtbar in Dashboard | Stop/Weiter |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Webhook Buchhalter** | Empfängt Body | externer POST | Trigger | nein | startet 1 Exec | nein | — | — | Weiter |
| 2 | **Load Documents** | `GET /documents?entity=eq.{entity}&invoice_date=gte.{from}&invoice_date=lte.{to}&doc_type=in.(Rechnung,invoice,facture,receipt)&select=...&order=payment_account.asc,invoice_date.asc`. Filter-Logik: nur `target_stream='RECHNUNG'` + `routing_result='direct_route'` + `review_required=false`. Test-Docs (`[tgvtest]`, `test c4`, …) werden standardmäßig **ausgefiltert** | Body | Doc-Array + blocked-Liste | Supabase | nein | nein | — | — | Weiter |
| 3 | **IF totalDocs > 0** | Sind überhaupt versandfähige Docs da? | Anzahl | true/false | nein | nein | nein | — | — | "nein" → 4a; "ja" → 5 |
| 4a | **Empty Mail "Keine Rechnungen"** | Versendet Info-Mail an Steuerberater: "Für {month} keine Rechnungen vorhanden". Sprache: deutsch (C3) oder französisch (C4) | — | SMTP-Send | SMTP | nein | nein | `documents.accounting_status='sent'` für die 0 Docs (nichts), aber `notification_log` Eintrag | Tab **Buchhalter-Log** | **STOP** |
| 5 | **Group by payment_account** | Gruppiert Docs nach `payment_account` (DE29…/FR…/Bar) für sortiertes Anhängen | Docs | Gruppen | nein | nein | nein | — | — | Weiter |
| 6 | **Download PDFs aus Drive** (Schleife) | Pro Doc: `GET drive/v3/files/{drive_file_id}?alt=media` lädt die PDF als binary. Bei fehlender `drive_file_id` aber vorhandener `direct_download_url` (z.B. Stripe) wird die URL gefetcht | Doc | Binary | Drive-API + ggf. HTTP | nein | nein | — | — | Weiter |
| 7 | **Build PDF-Bundle** | Hängt alle PDFs in 1 ZIP zusammen (oder als Mail-Multi-Attachment, je nach Version) + erstellt Excel-Übersicht mit allen Docs (provider, amount, date, drive_link) | N Binaries | 1 ZIP + 1 XLSX | nein | nein | nein | — | — | Weiter |
| 8 | **Build Mail-Body** | Generiert HTML-Mail. Sprache + Layout je Entity: **C3 = deutsch + Logo Convis + Adresse Auerbachstr. 10 Berlin**. **C4 = français + Logo Convis + Tour CIT Montparnasse Paris** | Entity+Gruppen | HTML | nein | nein | nein | — | — | Weiter |
| 9 | **SMTP Send** | Sendet an Steuerberater-Adresse (in `entity_config` hinterlegt). Anhang: ZIP + XLSX. CC: `jcbinetti@gmail.com` für Audit | HTML+Anhänge | SMTP-Response | SMTP | nein | nein | — | — | Weiter |
| 10 | **PATCH documents** | Pro versendetem Doc: `documents.accounting_status='sent'`, `accounting_period='{year}-{month}'`, `sent_to_accountant_at=now()` | Docs | DB-Update | Supabase | nein | nein | ✅ **`documents`** | Tab **Documents** + **Buchhalter-Log** | Weiter |
| 11 | **Audit-Log** | INSERT in `accounting_sends`: timestamp, entity, month, doc_count, recipient, bundle_size_kb, blocked_count | — | DB-Insert | Supabase | nein | nein | ✅ `accounting_sends` | Tab **Buchhalter-Log** | Weiter |
| 12 | **Response** | `{success, sent: N, blocked: M, blocked_details: [...]}` | — | HTTP-Response | nein | nein | nein | — | — | **STOP** |

---

## 3. FAQ

### Doppel-Versand-Schutz?
**Ja, dreifach:**
1. **Default:** Docs mit `accounting_status='sent'` UND `accounting_period={month}` werden **übersprungen**.
2. **`force_resend=true`** im Body: hebt diesen Schutz auf (alle eligible Docs werden versendet, auch schon-gesendete).
3. **`allow_legacy_sent=true`**: erlaubt Re-Send älterer Docs die in Vorversionen anders markiert wurden.

### Welche Docs sind "versandfähig"?
**Alle 3 Bedingungen gleichzeitig erfüllt:**
- `target_stream = 'RECHNUNG'`
- `routing_result = 'direct_route'` (nicht "needs_review", nicht "manual")
- `review_required = false`

Wenn eines fehlt → in `blocked[]`-Liste mit Begründung (`review_required_true_or_null` / `routing_result_not_direct_route` / `target_stream_not_rechnung` / `test_marker_filtered`).

### Test-Docs?
Erkennt Marker `tgvtest`, `[tgvtest:`, `test c4`, `test priv` in provider/subject/sender/drive_file_name. **Standardmäßig ausgefiltert**. Override: `include_test_docs=true`.

### Sprach-Routing
| Entity | Sprache | Adresse |
|---|---|---|
| `c3-convis-gmbh` | Deutsch | Auerbachstr. 10, Berlin |
| `c4-convis-sarl` | Français | Tour CIT Montparnasse, Paris |
| `privat` | Deutsch | privat Adresse |
| `kivisai` | Deutsch | wie c3 |

Vorlagen sind im WF hard-coded — Änderung erfordert Re-Deploy.

### Was wenn ein PDF in Drive fehlt?
`hasMissing=true` im Response. Versand wird trotzdem ausgeführt für die vorhandenen, fehlende werden im Mail-Body separat aufgelistet ("⚠️ Folgende Belege konnten nicht angehängt werden: ..."). Der User muss diese manuell nachreichen.

### Audit-Trail
- **`accounting_sends`-Tabelle**: 1 Zeile pro Versand-Run.
- **`documents.sent_to_accountant_at`**: Timestamp pro Doc.
- **Mail-Kopie an `jcbinetti@gmail.com`** (CC) als zusätzlicher Audit-Anker.

### Kosten — Quota
- **Token-frei** (keine KI).
- **Execs:** 1 pro Versand + ~N Drive-API-Calls (zählen als 1 Exec).
- **Bandbreite:** N × PDF-Größe (typisch 30-50 MB/Monat C3).

---

## 4. Was passiert NICHT (Mythen-Buster)

| Mythos | Realität |
|---|---|
| "Versand läuft automatisch am Monatsende" | ❌ Nur per Webhook-Trigger. Schedule existiert nicht. |
| "Alle Docs mit `doc_type=Rechnung` werden gesendet" | ❌ 3 zusätzliche Bedingungen (siehe FAQ). |
| "Test-Docs landen beim Steuerberater" | ❌ Marker-Filter blockt. |
| "Mehrere Versendungen sammeln sich" | ❌ Idempotent — bereits gesendete Docs ignoriert. |

---

## 5. Was der User selbst sehen/ändern kann

| Was | Wo | Editierbar? |
|---|---|---|
| Versand starten | Chatbot "Buchhalter C3 April senden" | ✅ |
| Vorab-Check | Filter `target_stream=RECHNUNG, status=ok` im Documents-Tab | ja (Reclass nötig) |
| Versendungs-Historie | Tab **Buchhalter-Log** | nein |
| Steuerberater-Adresse | `entity_config`-Tabelle | aktuell nur SQL |
| Sprache/Vorlage | hard-coded im WF | nicht ohne Re-Deploy |

---

## 6. TL;DR — die 4 Phasen

1. **SAMMELN** (1–5): Docs aus DB nach Entity+Monat, gefiltert auf versandfähig
2. **PACKEN** (6–7): PDFs aus Drive holen + ZIP/XLSX bauen
3. **SENDEN** (8–9): Sprach-spezifische Mail an Steuerberater
4. **PROTOKOLLIEREN** (10–12): DB-Update + Audit-Log

---

## 7. Verbesserungspunkte

| Befund | Vorschlag | Iter? |
|---|---|---|
| Kein Auto-Schedule am Monatsende | Optional Cron 5. d. Monats 09:00 mit Vorab-Check | 25 |
| Sprache/Vorlage hard-coded | Tabelle `accountant_templates` editierbar | 26+ |
| Empfänger-Adresse SQL-only | UI in **System → Entity-Config** | 25 |
| `hasMissing` nicht auto-recovered | Re-Run-Trigger für fehlende `drive_file_id` | 25+ |

---

*Stand: 2026-05-13 · Quelle: `TGV -App files/TGV_Workflow_E_v1.10_FINAL.json` + `v2.0_PROD` · Iter 24*
