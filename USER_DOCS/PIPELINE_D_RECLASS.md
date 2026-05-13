# Pipeline D — Reclass (Doc-Korrektur)

> **Was passiert wenn der User ein bereits klassifiziertes Doc korrigiert (z.B. "war keine Rechnung, sondern Vertrag")?**
> Schritt-für-Schritt für Nicht-Coder. Stand: 2026-05-13.

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV WF D — Reclass Doc Dispatcher** |
| Version | **v0.2.0** (Iter 11) |
| n8n-ID | `RDA4Hv8058hqxTOf` |
| Datei | `TGV -App files/deploy_wfd_reclass_v0200_dispatcher.py` |
| Aktiv | ✅ ja |
| **Trigger** | **Webhook `POST /webhook/tgv-reclass-doc`** — manuell aus Dashboard/Chatbot/MCP |
| Body | `{ doc_id: int, drive_file_id?: string, drive_file_name?: string }` |
| n8n-Executions / Call | **1 Exec D** + **1 Exec pro Re-Skill-Call** + **1 Exec kb-learn**. Typisch ~3 Execs |
| Token-Verbrauch / Call | hängt vom Skill ab. Bei RECHNUNG-Reclass via pdf-invoice-extract: ~2000 Tok |

---

## 2. Die Schritte — präzise Tabelle

| # | Akteur | Was passiert | Eingang | Ausgang | API? | n8n-Exec? | Token? | Speichert wo? | Sichtbar in Dashboard | Stop/Weiter |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Webhook /tgv-reclass-doc** | Empfängt `{doc_id, drive_file_id?, drive_file_name?}` | externer POST | Trigger | nein | startet 1 Exec | nein | — | — | Weiter |
| 2 | **Snapshot BEFORE** | `GET /documents?id=eq.{doc_id}` — speichert aktuellen Zustand des Docs (doc_type, entity, provider, amount, …) | doc_id | Snapshot-JSON | Supabase | nein | nein | — | — | Weiter |
| 3 | **Dispatch nach doc_type** | Switch auf `doc_type`: RECHNUNG → pdf-invoice-extract, VERTRAG → extract-contract-pdf, sonst → flag_for_review | doc_type | 1 von N Wegen | nein | nein | nein | — | — | Weiter |
| 4 | **Re-Run Skill** | `POST /webhook/tgv-skill-{pdf-invoice-extract\|extract-contract-pdf}` mit `{doc_id, force=true}`. Der Skill **läuft neu** und überschreibt die DB-Felder | doc_id | Skill-Result | n8n-internes Webhook | **+1 Exec** (Skill-WF) | hängt vom Skill ab | `documents` Felder | Tab **Documents** + **Skill-History** | Weiter |
| 5 | **Snapshot AFTER** | `GET /documents?id=eq.{doc_id}` erneut | doc_id | Snapshot-JSON | Supabase | nein | nein | — | — | Weiter |
| 6 | **Diff-Berechnung** | Vergleicht BEFORE vs AFTER — welche Felder haben sich geändert | 2 Snapshots | Diff-Object | nein | nein | nein | — | — | Weiter |
| 7 | **doc_type kanonisieren** | Normalisiert auf UPPERCASE: RECHNUNG/VERTRAG/BANKING/ZAHLUNGSBELEG/SONSTIGES | doc_type | normalisiert | nein | nein | nein | `documents.doc_type` | Tab **Documents** | Weiter |
| 8 | **Status = pending_review** | PATCH `documents.status='pending_review'` damit User die neuen Werte prüft (nicht silent auto-confirm) | doc_id | DB-Update | Supabase | nein | nein | `documents.status` | Tab **Documents** | Weiter |
| 9 | **POST kb-learn** | `POST /webhook/tgv-skill-kb-learn` mit `{doc_id, diff, trigger='reclass'}`. **Die KB lernt aus der Korrektur** — z.B. wenn provider="IONOS" jetzt anders zugeordnet wird, wird das im `kb_suppliers`-Pattern verstärkt | Diff | KB-Insert | n8n-internes Webhook | **+1 Exec** kb-learn | nein | `kb_suppliers` / `mail_processing_patterns_candidates` | Tab **System → Learning** | Weiter |
| 10 | **Workflow-Version + Audit** | Schreibt `processed_at`, `workflow_version='v0.2.0'`, Model-Info aus Skill-Response | — | DB-Update | Supabase | nein | nein | `documents.workflow_version` | — | Weiter |
| 11 | **Response** | Antwortet `{success, doc_id, diff, before, after}` an den Webhook-Caller | — | HTTP-Response | nein | nein | nein | — | — | **STOP** |

---

## 3. Wann wird WF D aufgerufen?

| Quelle | Wie |
|---|---|
| **Dashboard** Tab Documents | Klick "Re-klassifizieren" auf Doc-Detail → POST Webhook |
| **Chatbot** | "doc 1234 ist ein Vertrag, nicht Rechnung" → MCP-Tool ruft Webhook |
| **MCP-Tool** | `mcp__tgv__record_user_decision(doc_id, doc_type='VERTRAG')` |
| **Bulk-Script** | `08_OPS/reclass_docs.py` für historische Korrekturen |

---

## 4. FAQ

### Warum nicht direkt PATCH machen?
Weil der **Skill mehr macht als nur doc_type setzen.** Bei Reclass auf VERTRAG wird via extract-contract-pdf der Vertrag in `prf_contracts` extrahiert (Laufzeit, Kündigungsfrist…), das Doc wird auf `CONTRACTS/{ENTITY}/` verschoben (via Cascade), und der KB lernt das Provider-Pattern.

Reines `doc_type='VERTRAG'`-Update würde diese Sekundär-Effekte überspringen.

### Lernt das System wirklich aus Korrekturen?
**Ja, zweiteilig:**
1. **Sofort** (Schritt 9): `kb-learn` schreibt das Diff in `mail_processing_patterns_candidates`.
2. **Promotion** (separater Skill, Iter 17): Wenn dieselbe Korrektur mehrfach kommt, wird der Kandidat zu einer **aktiven Pattern** in `mail_processing_patterns` befördert → ab dann **vermeidet die Triage in WF A2 den ursprünglichen Fehler**.

→ Tab **System → Learning** zeigt Patterns + Stand der Promotion.

### Was wenn die Re-Klassifikation wieder falsch ist?
Status bleibt `pending_review`, User klickt nochmal. Theoretisch unbegrenzte Iterationen — jeder Klick = 1 Exec + Tokens.

→ **Quota-Warnung:** Reclass von 50 Docs in Folge = ~150 Execs + ~100k Tokens.

### Welche Skills sind erreichbar?
| `doc_type` (Eingang) | Skill (Re-Run) |
|---|---|
| RECHNUNG | `pdf-invoice-extract` v0.2 |
| VERTRAG | `extract-contract-pdf` |
| BANKING | `classify-csv` + `import-banking-csv` |
| STEUER | `tax-extract` v0.2 |
| sonst | `flag_for_review` (kein Skill, nur Status-Update) |

### Audit-Trail
- `documents.workflow_version` zeigt die WF-D-Version pro Reclass.
- `documents.processed_at` Timestamp.
- `learning_events` (Iter 13): 1 Zeile pro Reclass mit Doc-ID + Skill + Diff-Größe.

---

## 5. Was passiert NICHT (Mythen-Buster)

| Mythos | Realität |
|---|---|
| "Reclass macht silent automatisch" | ❌ Setzt `pending_review`, User muss explizit bestätigen. |
| "WF D arbeitet die ganze Inbox ab" | ❌ Einzeln pro doc_id. Bulk → eigenes Script. |
| "Drive-Datei wird sofort verschoben" | ❌ Erst nach Cascade-Re-Run mit `store-file-to-drive`. |
| "Reclass ändert nur doc_type" | ❌ Re-runs den vollen Skill — alle abhängigen Felder werden überschrieben. |

---

## 6. Was der User selbst sehen/ändern kann

| Was | Wo | Editierbar? |
|---|---|---|
| Reclass-Knopf | Tab **Documents → Detail-Modal** | ✅ |
| Vor/Nach-Diff | Tab **Documents** (Spalten History) | nein |
| KB-Lerneffekt | Tab **System → Learning** | nein (read) |
| Bulk-Reclass | Chatbot oder `08_OPS/reclass_docs.py` | ja |

---

## 7. TL;DR — die 3 Phasen

1. **EINFANGEN** (1–2): Webhook + Snapshot vorher
2. **NEU-VERARBEITEN** (3–7): Skill rufen, Felder überschreiben
3. **LERNEN** (8–11): Diff an KB, `pending_review` setzen, antworten

---

## 8. Verbesserungspunkte

| Befund | Vorschlag | Iter? |
|---|---|---|
| Bulk-Reclass kein UI | Tab-Aktion "Alle ausgewählten reclassen" mit Quota-Warnung | 25 |
| Diff nicht persistiert | `reclass_history`-Tabelle | 25+ |
| Promotion-Schwelle hard-coded | `learning_promotion_rules`-Tabelle | 26+ |

---

*Stand: 2026-05-13 · Quelle: `TGV -App files/deploy_wfd_reclass_v0200_dispatcher.py` · Iter 24*
