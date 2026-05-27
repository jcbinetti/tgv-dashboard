# Pipeline E — Buchhalter-Versand (Monats-Bundle)

> **Was passiert wenn am Monatsende die Rechnungen an den Steuerberater geschickt werden?**
> Schritt-für-Schritt für Nicht-Coder. Stand: 2026-05-15 (Iter 30 Block A5: v2.0 Strangler LIVE).

---

## ⚡ Versionen — Iter 30 (Strangler)

| Version | n8n-Status | Beschreibung |
|---|---|---|
| **v2.0** (Iter 30 NEU) | ✅ **ACTIVE** | Strangler: ersetzt SMTP-Node durch HTTP-Call an `tgv-skill-send-mail` v0.1.0. Multi-Local-Part (`c3@`/`c4@`/`kivisai@convis.fr`), reply_to=`tgv@convis.fr`. Footer kommt automatisch aus `entity_signatures` (mit KIVISAI-Inheritance). Provider: **Resend** (Free-Tier). Hardcoded JWT raus → `$vars.TGV_SUPABASE_*`. Webhook: `/webhook/tgv-buchhalter-versand-v2` |
| v1.11 FINAL FIXED | ⏸ inactive (Strangler-Park) | Iter 29 Versuch, SMTP intakt; archiviert |
| v1.7.2 | ⏸ inactive (Strangler-Park) | Pre-Strangler-Baseline; hatte einen hardcodierten Supabase-Service-Key (Iter-29-Audit-Finding, Key tot/rotiert); archiviert |

**Strangler-Pattern (KONZEPT §5):** v1.x bleibt im n8n Cloud archiviert (nicht gelöscht) bis v2.0 stabil ≥30 Tage. Rollback wäre per WF-Toggle (1 Click) möglich.

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

---

# Pipeline E v2.0 — Strangler-Architektur (Iter 30 Block A5 NEU)

## 8. v2.0 Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV WF E - Buchhalter Versand v2.0** |
| n8n-ID | `hVt5zeQkKX0vk521` |
| Aktiv | ✅ ja (ACTIVE seit Iter 30 Block A5 2026-05-15) |
| **Trigger** | **Webhook `POST /webhook/tgv-buchhalter-versand-v2`** — manuell oder via Chatbot/MCP |
| Body (Schema unverändert ggü. v1.7.2) | `{ entity, month, year, force_resend?, allow_legacy_sent?, include_test_docs?, to_email? }` |
| **Neu in v2.0** | `to_email?` Override-Recipient (Default: jcbinetti@gmail.com, Phase 2 echte Buchhalter-Adressen) |
| Token-Verbrauch | **0 — Token-frei.** DB + HTTP-Call an Skill + DB |
| Provider (Send) | **Resend** Free-Tier (1× verifizierte Domain `convis.fr`) |

## 9. Architektur-Diagramm v2.0

```
POST /webhook/tgv-buchhalter-versand-v2
   ↓
Webhook Buchhalter v2
   ↓
Load Documents  (Supabase SELECT eligible RECHNUNG docs, $vars statt hardcoded JWT)
   ↓
Check Completeness (IF totalDocs > 0)
   ↓ true                              ↓ false
Build Mail                          Respond Empty {ok:true, skip:true}
   ↓                                    ↓
Call Send-Mail-Skill  (HTTP POST → /webhook/tgv-skill-send-mail)
   ↓                                    │
   Skill: lookup entity_signature → Signature-Append (Logo + Footer aus DB) → POST Resend → INSERT outbound_mails
   ↓
Update Accounting Status (PATCH documents.accounting_sent_at)
   ↓
Respond Success {ok, updated, provider_msg_id, outbound_mail_id, sent_mail_link}
```

## 10. Schritt-für-Schritt v2.0 (Tabelle)

| # | Node | Was passiert | Neu in v2.0 |
|---|---|---|---|
| 1 | Webhook Buchhalter v2 | Empfängt POST mit Body | neuer path `/tgv-buchhalter-versand-v2` |
| 2 | Load Documents | Supabase SELECT (entity+month+target_stream=RECHNUNG+direct_route+review_required=false) | $vars statt hardcoded JWT (Iter 29 Audit-Fix) |
| 3 | Check Completeness | IF totalDocs > 0 | unverändert |
| 4 (true) | Build Mail | Generiert Subject + body_html (Tabellen pro Konto VISA/EC/SEPA, DE für C3, FR für C4) | **Kein Footer mehr** (kommt aus Skill via entity_signatures) |
| 4b (false) | Respond Empty | `{ok:true, skip:true, reason:'no_eligible_docs'}` | strukturierte Response, kein Empty-Mail-Send |
| 5 | Call Send-Mail-Skill | POST `tgv-skill-send-mail` mit {entity, to_email, subject, body_html, body_text, use_case='buchhalter_versand', idempotency_key='buchhalter-<entity>-<month>'} | **REPLACES SMTP-Node** komplett |
| 6 | Update Accounting Status | PATCH `documents` SET accounting_status='sent', accounting_sent_at=now() | $vars statt hardcoded JWT (Iter 29 Audit-Fix) |
| 7 | Respond Success | Skill-Response durchgereicht: `{ok, updated, total_docs, provider_msg_id, outbound_mail_id, sent_mail_link}` | sent_mail_link = `https://resend.com/emails/<msg_id>` |

## 11. Was v2.0 verbessert (Pain-Points behoben)

| Pain | v1.7.2 | v2.0 |
|---|---|---|
| **Hardcoded JWT** in Code-Nodes | hardcodierter Supabase-Service-Key (Iter-29-Audit-Finding; 2026-05-17 rotiert/tot, Wert hier redacted) | $vars.TGV_SUPABASE_SERVICE_ROLE_KEY |
| **TEST-MODUS Warnung im Body** | gelber `TEST-MODUS - Diese Mail geht an jcbinetti@gmail.com` Block | entfernt (Recipient via to_email Override transparent) |
| **Footer hard-coded** | Adresse `Auerbachstraße 10 | 14193 Berlin | Tel: ...` + Logo-URL fest im JS | aus `entity_signatures` mit KIVISAI-Inheritance (Logo + Legal-Info pro Entity DB-driven) |
| **From-Adresse einheitlich** | `factures@convis.fr` für alle Entities | Multi-Local-Part: c3@/c4@/kivisai@convis.fr (Display: „Convis Consult & Marketing GmbH/SARL/KIVISAI") |
| **reply_to gleich wie From** | `j.binetti@convis.com` | `tgv@convis.fr` (dedicated TGV-System-Postfach mit Forward → jcbinetti@gmail.com) |
| **Provider IONOS SMTP** | instabil, 535-Auth-Fehler seit Mai 7 | **Resend** (Free-Tier, 3k Mails/mo) — stabile API, DKIM auto, Bounce-Webhook |
| **Kein Audit-Trail beyond accounting_sent_at** | nur `documents` updated | **`outbound_mails` Tabelle** (Mig 077) hält jede Send-Action vollständig (status, provider_msg_id, retry, error, bounce) |
| **Keine Idempotency** | force_resend overwriting same docs | `idempotency_key='buchhalter-<entity>-<month>'` dedup-fähig (Skill checkt outbound_mails) |
| **Keine Bounce-Erkennung** | bouncing Mails fielen still aus | **Bounce-Webhook** (Iter 30 A7) — Resend POSTet Events → `outbound_mails.bounced_at` |
| **Keine Failure-Notify** | bei Auth-Failure stille Stille | **Failure-Notify-Cron** (Iter 30 A6) — ≥5 failed/24h → Sammel-Mail |

## 12. Side-Components

| Komponente | n8n-ID | Aktiv | Funktion |
|---|---|---|---|
| `tgv-skill-send-mail` v0.1.0 | `XZhRMWSvKzTqvwt1` | ✅ | Generischer Mail-Sender via Resend (Pattern #1-#5 compliant). Lookup entity_signatures → Signature-Append → INSERT outbound_mails → POST Resend. |
| `TGV Cron Mail Failure-Notify v0.1` | `G9a0SNY1bMhPfIUS` | ✅ | Cron 08:00 UTC daily. Threshold ≥5 failed/24h → Sammel-Mail via Skill (use_case=failure_notify, override_from=noreply@convis.fr). |
| `TGV Webhook Resend Bounce v0.1` | `8n3VhGkb4OqU7g8c` | ✅ | Receiver für Resend-Events (bounced/complained/delivered/opened/clicked). Lookup outbound_mails by provider_msg_id → PATCH status. |

## 13. DB-Schema (Iter 30 Block A1+A3)

- **`entity_signatures`** (Mig 076): entity PK, parent_entity FK (self-reference für KIVISAI=Marke-of-C3), display_name, legal_name, address_lines, ust_id, registration, bank_iban, bank_bic, bank_holder, representative, representative_role, logo_url, email_default, email_reply_to, signature_text, active. **RPC `lookup_entity_signature(text)` mit Parent-Inheritance-Merge** (Legal-Felder COALESCE aus parent; Display-Felder/Email bleiben self).
- **`outbound_mails`** (Mig 077): id PK, entity FK, to_email, reply_to, subject, body_html, body_text, attachments JSONB, use_case, trigger_doc_id, trigger_skill, status (queued/sending/sent/bounced/failed), provider, provider_msg_id, retry_count, last_error, notified, scheduled_at, sent_at, bounced_at, failed_at. **5 Indizes** für Failure-Notify, Bounce-Lookup, Use-Case-Filter.

## 14. Migration v1.7.2 → v2.0 — User-Sicht

**Was bleibt gleich**: Body-Schema (`entity`, `month`, `year`, `force_resend`, `allow_legacy_sent`, `include_test_docs`). Bestehende Chatbot-Trigger und Automatisierungen funktionieren ohne Änderung — nur Webhook-Path tauschen.

**Was sich ändert**:
- Webhook-Path: `/tgv-buchhalter-versand` (alt v1.7.2) → `/tgv-buchhalter-versand-v2` (neu v2.0)
- Response-Format: jetzt strukturiert `{ok, updated, total_docs, provider_msg_id, outbound_mail_id, sent_mail_link}` statt früherer Mail-Body-Echo
- Default-Recipient: weiterhin `jcbinetti@gmail.com` (Phase 1) — Phase 2 echte Buchhalter-Adressen via `agent_config` (Iter 31+)
- Mail-Branding: KIVISAI bekommt eigenes Display („KIVISAI <kivisai@convis.fr>") aber Legal-Footer von C3 (via Inheritance)

---

*Stand: 2026-05-15 · Quelle: 09_SKILLS/tgv-skill-send-mail/ + 05_SCHEMA/076-079 · Iter 30 Block A1-A8*
