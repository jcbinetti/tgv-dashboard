# Pipeline A2 — Mail-Intake bis DB-Eintrag

> **Was passiert wenn eine neue Mail in `factures@convis.fr` ankommt?**
> Schritt-für-Schritt für Nicht-Coder. Stand: 2026-05-13.

---

## 1. Steckbrief

| Feld | Wert |
|---|---|
| Workflow | **TGV WF A2 Mail Intake + Universal Triage** |
| Version | **v01.27** (`native_supabase`) |
| n8n-ID | `fx9POuhD3ybynhat` |
| Datei | `TGV -App files/TGV_WFA2_v0127_native_supabase.json` |
| Aktiv | ✅ ja (`active: true`) |
| **Trigger (echt)** | **Cron `0 0,12 * * *` = täglich 00:00 + 12:00 UTC** (alle 12 Stunden, nicht 15 Min — der alte Node-Name "Schedule 15 Minuten" ist nur Label) |
| n8n-Executions / Tick | **1 Execution pro Tick** (alle Inline-Nodes laufen darin), unabhängig von Mail-Zahl. Sub-WFs würden extra zählen — aber v01.27 ruft keinen Sub-WF auf. → **~60 Execs/Monat fix.** |
| Token-Verbrauch / Tick | **1 Claude-Call pro Anhang ohne Rule-Match** (nicht pro Mail!). Modell: `claude-haiku-4-5`. max_tokens=1000. → typisch 0–3 Calls/Tick. |
| Quota-Klasse | Niedrig — der teure Teil ist die Cascade danach. |

---

## 2. Die 20 Schritte — präzise Tabelle

| # | Akteur (n8n-Node) | Was passiert | Eingang | Ausgang | API? | n8n-Exec? | Token? | Speichert wo? | Sichtbar in Dashboard | Stop/Weiter |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Schedule (cron)** | Weckt den WF auf | — | Tick-Event | nein | startet die 1 Exec | nein | — | Tab **System → Workflows** (Status + letzter Run) | Weiter |
| 2 | **IMAP Read Unseen** | Login an IONOS-IMAP, holt **alle** ungelesenen Mails aus `factures@convis.fr`. Anhänge werden mit-runtergeladen (`downloadAttachments: true`) | IMAP-Credential | n8n-Item pro Mail mit `json` (Header) + `binary` (Anhänge `attachment_0…19`) | IMAP-Login (kein Token) | nein, im selben Exec | nein | nichts (RAM only) | indirekt: Tab **Mail-Pipeline** zeigt letzte gefetchte Mails | Weiter wenn ≥1 Mail |
| 3 | **IF Mail vorhanden** | Hat IMAP überhaupt was geliefert? | n8n-Item | true/false-Zweig | nein | nein | nein | — | — | "Nein" → **Schritt 4a (NoOp)**, "Ja" → 5 |
| 4a | **NoOp — Keine ungelesenen Mails** | "Still beenden" = WF endet ohne Fehler, ohne Log, ohne DB-Write. Heißt **nicht** dass etwas verloren geht — nur dass nichts zu tun war | — | — | nein | nein | nein | nichts | nur in n8n-Execution-Log "executed, 0 items" | **STOP** |
| 5 | **Mail sichern** | Vereinheitlicht Mail-Felder (`from`, `subject`, `text`, `message_id`, `date`). HTML wird zu Plain-Text gestrippt, Body auf **6000 Zeichen begrenzt**. **NICHT auf Disk gesichert** — nur im n8n-RAM für die nächsten Nodes | n8n-Item roh | n8n-Item normalisiert | nein | nein | nein | RAM (kein Disk-Backup an dieser Stelle) | — | Weiter |
| 6 | **Normalisierung** | Pro Anhang wird klassifiziert: PDF/ZIP/CSV/SPREADSHEET/TEXT_DOCUMENT/IMAGE/ATTACHED_EMAIL/TEXT/MAIL_BODY. **Signaturen/Logos/Inline-Bilder werden hier verworfen** (siehe FAQ 5). Erkennt `#c3 #c4 #privat #kivisai` im Subject als Entity-Hint. Erkennt `Fwd:` / "Weitergeleitete Nachricht" → `is_forwarded=true` | Mail | Mail + Array `attachments[]` (gefilterte) + `ignored_attachments[]` | nein | nein | nein | RAM | — | Weiter |
| 7 | **Split Attachments** | 1 Mail mit 3 Anhängen → **3 separate Items**, ab hier parallel verarbeitet. 1 Mail ohne brauchbaren Anhang → 1 Item mit Family `MAIL_BODY` | Mail mit Array | N Items | nein | nein | nein | — | — | Weiter |
| 8 | **Index setzen** | Vergibt `attachment_index` (0, 1, 2…) damit der Anhang im DB-Datensatz später eindeutig zur Mail rückführbar ist | Item | Item + index | nein | nein | nein | — | — | Weiter |
| 9 | **Dedup Check + Dedup Kontext** | Setzt `_dedup_check_mode='pass_through_insert_constraint_guard'`. **Es wird hier NICHT gegen die DB geprüft** — sondern auf den Unique-Index `idx_documents_dedup` (auf `message_id` + `attachment_index`) vertraut. Doppelter Insert kommt als HTTP-409 zurück und wird in Schritt 16 toleriert | Item | Item + Flag | nein | nein | nein | — | — | Weiter |
| 10 | **IF bereits verarbeitet?** | (in v01.27 immer `false` da Mode=pass-through) | Flag | true/false | nein | nein | nein | — | — | "false" → 11; "true" → NoOp |
| 11 | **Routing Rules laden** | Liest **alle aktiven** Regeln aus Supabase-Tabelle `mail_routing_rules`. **Das ist 1 PostgREST-Request** (kein extra n8n-Exec; native Supabase-Node) | — | Array Regeln | Supabase-API (kein Token, kein Claude) | nein | nein | — | Tab **System → Mail-Routing-Rules** | Weiter |
| 12 | **Routing Rules anwenden** | Geht die Regeln (sortiert nach `priority`) durch. Felder pro Regel: `match_field` (from/subject/attachment/manual), `match_value`, `match_type` (`contains`/`exact`/`starts_with`/`regex`). Erste Treffer-Regel gewinnt | Item + Regeln | Item + `_routing_rule` + `_rule_matched` + `_blocked_by_rule` | nein | nein | nein | — | — | Weiter |
| 13 | **IF Rule block** | Regel hat `action='block'`? → kein Doc-Insert, **NoOp**. Beispiele: Newsletter, Spam-Patterns. Begründung steckt im Regel-Datensatz selbst (`description` / `notes`) | Flag | true/false | nein | nein | nein | — | Tab **System → Mail-Routing-Rules** zeigt geblockte Absender | "block" → **STOP**; sonst 14 |
| 14 | **IF Rule matched** | Regel hat zugeschlagen (≠ block)? → **AI überspringen**, direkt Merge. Sonst → AI-Pfad (15a-c) | Flag | 2 Wege | nein | nein | nein | — | — | matched → 16; unmatched → 15 |
| 15a | **Patterns laden** | Liest `mail_processing_patterns` aus Supabase (7 Seeds, Verhaltensregeln für die KI) | — | Patterns | Supabase | nein | nein | — | Tab **System → Patterns** | Weiter |
| 15b | **Kontext aufbauen** | Baut den Claude-Prompt: System-Prompt + Mail-Text (Body+Subject, 6000 chars max) + Patterns + Rule-Hinweis | Item+Patterns | Item + `_system_prompt` + `_user_content` | nein | nein | nein | — | — | Weiter |
| 15c | **Universal Triage Agent** | **HTTP-POST an `api.anthropic.com/v1/messages`** mit Modell `claude-haiku-4-5-20251001`, max_tokens=1000. Claude liefert JSON: `{stream, entity, provider, amount, currency, date_document, category_l1, category_l2, confidence, requires_review, skills_needed, detected_patterns, new_pattern_suggestion, routing_reason}` | Prompt | Claude-Antwort | ✅ **Claude API** | nein (gleicher Exec) | ✅ **~800 Input + ~300 Output Tokens / Anhang** | — | indirekt: Tab **Documents** zeigt das fertige Doc | Weiter |
| 16 | **Merge Rule + AI Triage** | Führt Rule-Ergebnis + Claude-Ergebnis zusammen. **Rule sticht AI** — wenn eine Regel zugeschlagen hat, wird ihr `doc_type/entity` genommen, Konfidenz auf 100 gesetzt | Item | Item + `triage` | nein | nein | nein | — | — | Weiter |
| 17 | **Triage Ergebnis zusammenfuehren** | Baut den finalen DB-Datensatz. Setzt `target_skill` deterministisch (siehe FAQ 13). `confidence ≥ 70` → `review_status='inbox'`, sonst `pending_review` | Item | Item + `preprocessing_contract` + `target_skill` | nein | nein | nein | — | — | Weiter |
| 18 | **Supabase INSERT documents** | **DER PERSISTENZ-PUNKT.** Native Supabase-Node legt Zeile in `documents` an mit: `source`, `sender`, `subject`, `message_id`, `doc_type`, `target_stream`, `entity`, `provider`, `amount`, `currency`, `date_received`, `invoice_date`, `category`, `status`, `confidence_score`, `original_from`, `mail_attachment_index`, `mail_subject`, `routing_reason`, `todo_manual`, `is_correction`, `project_hint`. **HTTP 201/200** = OK. **HTTP 409** = Duplikat (toleriert, kein Fehler) | Item | DB-Row + HTTP-Status | Supabase-API | nein | nein | ✅ **`documents`-Tabelle** | Tab **Documents** (alle Belege), Tab **Mail-Pipeline** (Triage-Zeile) | Weiter |
| 19 | **INSERT Ergebnis auswerten** | Erkennt 201/200=ok, 409=duplicate, sonst=error. Setzt `document_id` aus Response. Workflow läuft trotzdem weiter (`continueOnFail`) | DB-Response | Item + Flags | nein | nein | nein | — | — | Weiter |
| 20 | **A2 Handoff Contract bauen** | Schreibt den fertigen Übergabe-Vertrag `_tgv02_handoff` mit: `document_id, stream, entity, skills_needed, target_skill, preprocessing_contract, …`. **Genau das wird in FAQ 18 abgefragt** — siehe unten "Was wird übergeben" | Item | Item + Handoff-Objekt | nein | nein | nein | — | — | Weiter |
| 21 | **Konfidenz Router (Switch)** | Routet nach `triage.stream`: RECHNUNG / BANKING / VERTRAG / PROJEKT / *fallback*. In v01.27 münden **alle 5 Äste in denselben Log-Node** — der Switch ist also nur Vorbereitung für künftige Sub-WF-Trigger | Item | gleiches Item, 1 von 5 Outputs | nein | nein | nein | — | — | Weiter |
| 22 | **LOG — Triage Output** | `console.log` ins n8n-Execution-Log. **ENDE des WF.** | Item | — | nein | nein | nein | n8n-Execution-Log | Tab **System → Executions** (n8n-Cloud-Console) | **STOP — WF fertig.** |

---

## 3. Übergabe an die Cascade

**Wichtig:** WF A2 **ruft die Cascade nicht aktiv auf.** Der vorgesehene Push-Node `Post Intake Handoff vorbereiten` (Webhook `/webhook/tgv-post-intake`) ist in v01.27 mit `disabled: true` markiert und ohne Connection — ein bewusster Rückbau.

**Stattdessen: Polling-Architektur.**
WF A2 hinterlässt nur einen Datensatz in `documents` mit `status='inbox'` (oder `pending_review`). Die **Inbox-Cascade** (separater WF) prüft via Webhook `/webhook/tgv-cascade-trigger` oder Nightly-Cron diese Zeilen und übernimmt: Drive-Upload, Skill-Routing, Reconcile.

→ Siehe [PIPELINE_CASCADE.md](PIPELINE_CASCADE.md).

📚 **Lern-Box — Push vs. Polling**
- **Push** = A ruft B sofort an (Webhook). Schnell, aber A bricht wenn B down ist.
- **Polling** = B schaut selbst regelmäßig in die DB ("gibt's was Neues?"). Langsamer, robuster.
- v01.27 nutzt Polling, weil der Push-Pfad in Iter 22/23 mehrfach gebrochen ist.

---

## 4. FAQ — Antworten auf deine 23 Fragen

### Frage 1 — Trigger und Token/Exec präzise
- **Wann genau?** Cron `0 0,12 * * *` = **00:00 und 12:00 UTC** (also 01:00/13:00 Berlin im Sommer, 02:00/14:00 Paris im Winter). **Nicht alle 15 Minuten.**
- **Wer auch?** IMAP-Login bei IONOS (Credential `IMAP factures convis.fr`).
- **Token pro Schritt:** alle 22 Schritte sind **token-frei außer Schritt 15c** (Claude). 1 Claude-Call pro **Anhang** (nicht Mail) der **ohne Rule-Match** durchgeht. Bei 1 Mail mit 2 Anhängen, beide ohne Regel → 2 Calls.
- **n8n-Exec pro Schritt:** alle 22 Schritte = **1 Execution gesamt**. Native Supabase-Nodes + HTTP-Requests zählen nicht extra — nur Sub-Workflow-Calls würden, aber davon hat v01.27 keinen.

### Frage 2 — Was heißt "still beenden"?
"Still" = WF beendet sich ordnungsgemäß als **Success** mit 0 Items, ohne Fehler-Log und ohne DB-Eintrag. Das ist der **Normal-Zustand**, wenn die Inbox leer ist. **Nicht verlieren** — die Mail ist ja in IMAP gar nicht angekommen. Wird sichtbar nur in der n8n-Execution-Liste mit Status "succeeded · 0 items".

### Frage 3 — Wo wird gesichert? In welchem Format? Wie abrufbar?
| Etappe | Wo gesichert | Format | Wann sichtbar in TGV |
|---|---|---|---|
| Schritt 2 (IMAP-Fetch) | nichts → nur n8n-RAM | — | — |
| Schritt 5 (Mail sichern) | **nichts auf Disk!** trotz Name. Nur RAM. | — | — |
| Schritt 18 (INSERT documents) | **Supabase-Tabelle `documents`** | 22 Spalten, BIGINT-`id` | Tab **Documents** sofort nach Tick |
| Anhang als Datei | **passiert nicht in WF A2 v01.27** | — | erst durch Cascade → Drive (siehe FAQ 16) |

→ "Mail sichern" ist ein **irreführender Name** — der Node normalisiert, sichert aber nichts. Echter Persistenz-Punkt ist Schritt 18.

### Frage 4 — Alle Sprachen? Alle Formate? Limits?
- **Sprachen:** Claude versteht DE/FR/EN problemlos, das System-Prompt ist sprach-agnostisch. Patterns enthalten DE+FR Beispiele.
- **Mail-Formate:** HTML+Plain werden zu Plain gestrippt. RFC822-Header werden gelesen. `multipart/alternative` ok. Mail-in-Mail (`.eml` als Anhang) wird erkannt → Skill `extract_attached_email` (Cascade).
- **Anhang-Formate erkannt:** PDF, ZIP, CSV, XLS(X)/ODS, DOC(X)/ODT/RTF, PNG/JPG/GIF/WEBP/TIFF, TXT/MD/JSON/XML, EML/MSG.
- **Limits:**
  - **max 20 Anhänge pro Mail** (Loop `attachment_0..19`).
  - **Body auf 6000 Zeichen** für Claude (Schutz vor Riesen-Mails).
  - **max_tokens=1000** für Claude-Antwort.
  - **Bilder ≤ 120 KB** werden als Signatur/Logo verworfen.
  - n8n-Workflow-Timeout: default (5min).

### Frage 5 — Signatur/Logo-Bilder + Mail↔Anhang-Verknüpfung
**Korrekt — Signaturen/Logos werden NICHT gespeichert.** Die `Normalisierung` (Schritt 6) wirft jeden Anhang weg, wenn:
- `disposition: inline` ODER `content_id` gesetzt (CID-Referenz im HTML),
- Dateiname matched `logo|signature|signatur|facebook|linkedin|twitter|instagram|youtube|icon|spacer|pixel|banner` oder `image001.png`-Pattern,
- Bild ≤ 120 KB.

**Mail↔PDF-Verknüpfung — JA, sauber rückverfolgbar.** Jedes Doc in `documents` hat:
- `message_id` (RFC822 Message-ID — global eindeutig pro Mail)
- `sender`, `original_from` (bei Forwards)
- `subject` / `mail_subject`
- `date_received`
- `mail_attachment_index` (welcher Anhang dieser Mail das war)
- `routing_reason`

→ Frage *"Wann wurde dieses PDF an TGV gesendet, in welcher Mail, von wem?"* beantwortbar durch SQL/Dashboard auf `documents.id`.

### Frage 6 — Unique-ID über alle Mails?
**Ja, doppelt abgesichert:**
1. **`message_id`** = RFC822 Message-ID — global eindeutig vom sendenden Mailserver vergeben. Format `<xxx@domain>`.
2. **DB-Constraint `idx_documents_dedup`** auf (vermutlich) `message_id + mail_attachment_index` → garantiert dass dieselbe Mail+Anhang nie 2× in `documents` landet (HTTP 409 in Schritt 18).
3. **`documents.id`** = BIGINT auto-increment — eindeutig pro Doc-Zeile.

### Frage 7 — "Kontext aufbauen" — LLM oder nicht?
**Kein LLM.** Schritt 15b ist reines JS — zieht den System-Prompt + Patterns + Mail-Text zusammen, formatiert sie als Strings. Der LLM-Call kommt erst **danach** in Schritt 15c (Claude).

### Frage 8 — Dedup gegen "gleicher Mail-Inhalt aber 1 Anhang mehr"?
**Nein, das wird in v01.27 NICHT erkannt.** Dedup arbeitet auf `message_id + attachment_index`. Wenn jemand die Mail neu sendet mit +1 Anhang, kommt eine **neue Message-ID** rein → alle Anhänge werden als neue Docs angelegt (auch die schon bekannten).

→ **Echtes Content-Dedup ist Aufgabe der Cascade** (Skill `detect-duplicate` v0.1, seit Iter 16). Sucht über Hash/Provider+Amount+Date.

### Frage 9 — Wo Regeln sehen/ändern? Lernen die mit?
- **Sehen:** Dashboard-Tab **System → Mail-Routing-Rules** (54 Zeilen aus `mail_routing_rules`).
- **Ändern:** Aktuell **nur per SQL/Supabase-UI** (nicht im Dashboard editierbar — UI-Edit ist Roadmap-Item).
- **Liste-Herkunft:** Migration 016 (`gmail_filter_routing_rules`) — 23 Regeln aus den Gmail-Filtern importiert. Plus 31 manuell ergänzte.
- **Lernen sie mit?** **Teilweise.** Claude darf in jeder Antwort `new_pattern_suggestion` zurückgeben → landet in `mail_processing_patterns` (Schritt 15a-Seeds). Es gibt einen separaten Skill `kb-learn` (v0.3.1, Iter 17) der promotet Suggestions zu echten Patterns. Aber `mail_routing_rules` selbst werden **nicht automatisch erweitert** — die sind manuell.

📚 **Lern-Box — Rules vs. Patterns**
- **Rules** (`mail_routing_rules`): harte Wenn-Dann-Regeln (Absender → Entity). Override für Claude.
- **Patterns** (`mail_processing_patterns`): weiche Hinweise für Claude ("wenn Subject XYZ enthält, ist es meist STEUER"). Claude darf abweichen.

### Frage 10 — Block-Verfahren / Token?
**Kein Token-Verbrauch.** Routing Rules (Schritt 12) ist pures JS-Matching (contains/exact/starts_with/regex) — keine KI involviert. Pro Mail nur 1× durch alle 54 Regeln durchgegangen (O(n), sub-ms).

### Frage 11 — Was wird blockiert? Wo dokumentiert?
**Geblockt wird:** der ganze WF-Pfad nach Schritt 13 — also: **kein Doc-Insert in DB**, **kein Drive-Upload**, **keine Cascade**. Mail+Anhang existieren nur weiter in IMAP (IONOS-Postfach selbst).

**Wo dokumentiert:** In der `mail_routing_rules`-Zeile selbst — Felder `description` und Match-Felder zeigen *warum*. Im n8n-Execution-Log steht `blocked_by_rule=true` und welche Rule-ID gegriffen hat.

📌 **Lücke:** Es gibt **keine separate `blocked_mails`-Tabelle** — der Block ist NUR im n8n-Exec-Log nachvollziehbar (30 Tage retention). Für Audit-Trail wäre das ein Verbesserungspunkt.

### Frage 12 — *(klar)*

### Frage 13a — Skill-Routing deterministisch oder LLM?
**Hybrid, aber primär deterministisch.** Der Pfad:
1. Claude schlägt `skills_needed[]` vor (LLM).
2. **Triage Ergebnis zusammenfuehren** (Schritt 17) **überschreibt deterministisch** anhand von Datei-Format + Stream:
   - `.zip` / mime=zip → `unzip` **immer hinzufügen**
   - `.eml/.msg` / mime=rfc822 → `extract_attached_email` immer
   - `.csv` oder stream=BANKING → `csv_banking` immer
   - `.pdf` UND stream=RECHNUNG → `pdf_invoice_extract` immer
   - stream=VERTRAG → `contract_summary` immer
3. **`target_skill`** (der zuerst zu feuernde Skill) wird per **Priority-Cascade** gewählt: `extract_attached_email > unzip > csv_banking > pdf_invoice_extract > contract_summary > classify_spreadsheet > classify_image_document > classify_text_document > classify_mail_content > route_project_document > flag_for_review`.

**Rule-Tabelle?** Diese Priority-Liste ist **hard-coded** in `A2 Handoff Contract bauen` (Schritt 20). Es gibt **keine** dedizierte `skill_routing_rules`-Tabelle. → Verbesserungspunkt für Iter 25+.

### Frage 13b — Wer bestimmt wie der Prompt erstellt wird?
**Fest in Code.** Der System-Prompt für Claude steht im Node `Kontext aufbauen` (Schritt 15b) als JavaScript-Konstante. Patterns (`mail_processing_patterns`) werden **als Daten injiziert**, aber der **Prompt-Aufbau selbst** ist hardcoded. → kein Skill, der den Prompt generiert.

### Frage 13c — Multi-Klasse möglich?
- **`triage.stream`**: **Einzelwert** (genau eines aus `RECHNUNG / BANKING / VERTRAG / PROJEKT / STEUER / SONSTIGES`). → Single-Label.
- **`skills_needed[]`**: **Array** — ein Doc kann mehrere Skills brauchen (z.B. `["unzip", "csv_banking"]`). → Multi-Label.
- **`target_skill`**: Einzelwert — der **erste** Skill, der gefeuert wird. Die anderen aus `skills_needed[]` werden im Cascade-WF abgearbeitet.
- **Vertrag + Projekt gleichzeitig**: ein Doc kann **nicht** stream=VERTRAG **und** stream=PROJEKT gleichzeitig sein. Aber: über `project_hint` (eigenes Feld) kann ein VERTRAG-Doc einem Projekt zugeordnet werden. → Verbesserung: echte Tags-Tabelle für Multi-Domain wäre Iter 25+ Thema.

📚 **Lern-Box — Single-Label vs. Multi-Label vs. Tags**
- **Single-Label** = genau eine Kategorie pro Doc (wie heute `stream`). Einfach, aber unflexibel.
- **Multi-Label** = Array von Kategorien (wie heute `skills_needed[]`).
- **Tags** = beliebig viele freie Labels (separate Junction-Tabelle `documents_tags`). Maximal flexibel — heute nicht implementiert.

### Frage 14 — *(Rules angesehen)*

### Frage 15 — Wo die API-Call-Chunks finden?
- **Pro Doc:** `documents.routing_reason` zeigt Kurzbegründung, `confidence_score` zeigt Konfidenz, aber **nicht den vollen Claude-Request/Response**.
- **Voller Request/Response:** **derzeit nicht persistiert.** Steht nur kurz im n8n-Execution-Log (30 Tage).
- **Was *wäre* nötig:** Schritt 18 müsste das `_user_content` + `_ai_raw_response` mit-speichern. → Verbesserungspunkt.
- **Reines DB-Bild pro Doc:** Tab **Documents → Detail-Modal** zeigt alle 22 Spalten plus `ai_suggestion` (falls Cascade gefüllt hat).

### Frage 16 — Werden Belege physisch in Drive INBOX sichtbar?
**Nicht durch WF A2 v01.27.** Die Drive-Upload-Nodes (`Route A2 File Persist`, `Prepare A2 Drive Upload`, `Upload A2 Attachment to Drive`, `Merge A2 Drive File ID`) **existieren im JSON, sind aber ohne Connection = tote Nodes**.

→ Der **Drive-Upload erfolgt erst in der Cascade** über den Skill `store-file-to-drive`. Zielordner:
- `DOCUMENTS/{ENTITY}/{YEAR}/{MONTH}/` für Rechnungen
- `CONTRACTS/{ENTITY}/` für Verträge
- `INBOX/` ist der **Drive-Drop-Ordner für WF B** (manueller Upload), **nicht** für Mail-Pipeline.

### Frage 17 — *(klar)*

### Frage 18 — Was wird der Cascade übergeben?
Inhalt des `_tgv02_handoff`-Contracts (in v01.27 **nur im n8n-Item**, da Cascade per Polling auf `documents` zugreift):

```
contract_version: "tgv02-a2-handoff-v1"
source: "email"
workflow: "WF A2"
workflow_version: "v01.27"
message_id, sender, subject, text_excerpt (1200 chars), date_received
document_id          ← echter FK auf documents.id
attachment_index, filename, mime_type, attachment_family, file_ext
binary_keys[], original_binary_key
stream, entity, provider, project_hint
skills_needed[]      ← z.B. ["pdf_invoice_extract"]
target_skill         ← z.B. "pdf_invoice_extract"
preprocessing_contract { … alles oben + triage-Detail … }
requires_review (bool), confidence (0-100)
triage { full Claude-Output }
ignored_attachments[] (Signaturen/Logos zur Audit)
metadata { from, subject, date, message_id, entity_hint, original_from, routing_reason, is_correction }
```

Die Cascade liest **nicht** dieses Objekt direkt — sie liest `documents`-Zeile + holt sich die binäre Datei woanders (siehe FAQ 16).

### Frage 19 — *(klar)*

---

## 5. Was passiert NICHT in WF A2 v01.27 (häufige Fehlannahmen)

| Mythos | Realität |
|---|---|
| "WF A2 lädt das PDF auf Drive hoch" | ❌ Nodes vorhanden, aber **disconnected**. Macht die Cascade. |
| "Schedule läuft alle 15 Min" | ❌ Node-Name lügt — Cron ist alle 12 h. |
| "Mail sichern legt eine Datei an" | ❌ Reine Feld-Normalisierung im RAM. |
| "Dedup fragt die DB" | ❌ pass-through; Dedup-Garantie kommt vom Unique-Index `idx_documents_dedup`. |
| "Post Intake feuert die Cascade" | ❌ Node ist `disabled: true`. Cascade pollt selbst. |
| "Geblockte Mails landen in einer Audit-Tabelle" | ❌ Nur im n8n-Exec-Log (30 d retention). |

---

## 6. Was der User selbst sehen/ändern kann

| Was | Wo im Dashboard | Editierbar? |
|---|---|---|
| Aktive WFs + letzte Runs | Tab **System → Workflows** | nein (read-only) |
| Mail-Routing-Rules (54) | Tab **System → Mail-Routing-Rules** | aktuell nur SQL |
| Mail-Processing-Patterns (7+) | Tab **System → Patterns** | aktuell nur SQL |
| Fertige Docs aus Mail-Intake | Tab **Documents** (Filter `source=email`) | Stream/Entity/Status korrigierbar im Detail-Modal |
| Triage-Resultate pro Doc | Tab **Mail-Pipeline** | nein |
| Quota / Token-Verbrauch | Tab **Cost** | nein (Telemetrie-Read) |
| n8n-Execution-Log | n8n-Cloud-Console (nicht im Dashboard) | nein |

---

## 7. TL;DR — die 4 Phasen

1. **HOLEN** (Schritte 1–4): Cron + IMAP fetch
2. **AUFBEREITEN** (5–10): Normalisierung, Split, Filtern (Signaturen weg), Dedup-Vorbereitung
3. **KLASSIFIZIEREN** (11–17): Regeln zuerst → falls keine → Claude-Haiku → Merge → deterministisches Skill-Routing
4. **EINSPEISEN** (18–22): DB-INSERT → Handoff bauen → Log. **Cascade übernimmt im nächsten Polling-Zyklus.**

---

## 8. Verbesserungs-Punkte (für künftige Iters)

| Befund | Vorschlag | Iter? |
|---|---|---|
| Claude-Request/Response wird nicht persistiert | `documents.ai_request` + `documents.ai_response` (JSONB) | 25+ |
| Geblockte Mails ohne Audit-Trail | Tabelle `mail_blocked_log` mit Rule-ID + timestamp | 25+ |
| Skill-Routing hard-coded | Tabelle `skill_routing_rules` (analog `mail_routing_rules`) | 25+ |
| Multi-Domain-Klassifikation unmöglich | `document_tags` Junction-Tabelle | 25+ |
| `mail_routing_rules` nicht im Dashboard editierbar | UI in Tab **System → Mail-Routing-Rules** | 24–25 |
| "Schedule 15 Minuten" Node-Name lügt | Rename in `Schedule 12h (00:00 + 12:00 UTC)` | 24 (1-min-Fix) |
| Inhalt-basiertes Dedup ("1 Anhang mehr") fehlt | Skill `detect-duplicate` schon da, aber A2 ruft ihn nicht — Cascade tut's | bereits Cascade |

---

*Stand: 2026-05-13 · Quelle: `TGV -App files/TGV_WFA2_v0127_native_supabase.json` · Iter 24*
