# ITER MAN#01 — TGV Core Debitoren-Rechnungen

Diese Iteration ergänzt TGV Core um einen Finanzen-Reiter **Debitoren**. Ziel ist nicht die automatische Rechnungserstellung, sondern die saubere manuelle Pflege von Ausgangsrechnungen für **C3**, **C4** und **PRIV** im bestehenden TGV-Geist: klein, prüfbar, mit Dokumenten-, Transaktions- und späterer Gabriel-/Life-Memory-Anschlussfähigkeit.

## Fachliche Leitplanken

Die bestehende Rechnungsnummernlogik bleibt erhalten: **Entität–Jahr–laufende ID–Text/Projekt**. Rechnungen werden nach Leistungszeitraum getrennt erfasst. Zahlungsstatus wird nicht als isolierte Checkbox geführt, sondern kann auf `txn_master` zeigen. Skonto und Gutschriften sind im Modell vorgesehen, werden aber in MAN#01 noch nicht automatisch berechnet oder gebucht. Wichtig für den Review-Seed: **Offen** und **Bezahlt** stammen aktuell aus der statischen Ausgangsliste beziehungsweise den von dir gelieferten Excel-/Arbeitslisten; sie bedeuten noch nicht, dass eine automatische Reconciliation gegen Banktransaktionen durchgeführt wurde. Die echte Reconciliation ist über `linked_txn_id` vorbereitet und wird in einer Folgeiteration zur Statusableitung genutzt.

| Entität | Fortführung 2026 | Hinweis |
|---|---:|---|
| C3 | C3-26-014 | Anschluss an bestehende C3-Liste nach C3-26-013; sichtbare Reservierungen 014ff. werden berücksichtigt. |
| C4 | C4-26-1216 | Anschluss an C4 2025 bis 1215; 2026 bisher keine Rechnung. |
| PRIV | JC-26-001 | Startlogik vor erster echter Rechnung fachlich bestätigen. |

## Nutzerfeedback während Review

Am 2026-06-02 wurde im Review festgestellt, dass **Entität** und **Zeitraum** bereits global oben im TGV-Core-Kontext gewählt werden. Der Debitoren-Reiter darf diese Auswahl daher nicht als zweite Fachauswahl duplizieren. MAN#01 wurde entsprechend angepasst: Debitoren nutzt `gEntity` und `gPeriod` aus der bestehenden globalen Filterleiste und zeigt darunter nur noch den fachlichen Kontext sowie Detailfilter für **Art**, **Zahlungsstatus** und **Projekt/Projektnummer**. Der Projektfilter wird aus `project_no` beziehungsweise `project_ref` der aktuell sichtbaren Debitoren-Rechnungen dynamisch aufgebaut und filtert auch die KPI-Werte.

Da die Supabase-DDL aus der Sandbox nicht direkt angewendet werden konnte, enthält die UI einen klar markierten **Review-Seed**. Dieser Seed macht die bisher bekannten C3- und C4-Rechnungen aus den bereitgestellten Arbeitslisten sichtbar, bis die Migration auf der Live-Datenbank ausgeführt ist. Sobald `debtor_invoices`, `debtor_customers` und `invoice_number_sequences` live existieren, ersetzt die App den Seed automatisch durch Supabase-Daten.

## Gelieferte Artefakte

| Artefakt | Zweck |
|---|---|
| `migrations/20260602_iter_man01_debitoren.sql` | Tabellen `debtor_customers`, `invoice_number_sequences`, `debtor_invoices` inklusive RLS-Policies, Sequenz-Seed und initialem C3-/C4-Backfill. |
| `index.html` | Neuer Finanzen-Reiter **Debitoren** mit KPI-Karten, global gekoppeltem Kontext, Detailfiltern, Tabelle, Nummern-Hinweisen, Review-Seed und Minimalformular. |
| `USER_DOCS/ITER_MAN01_DEBITOREN.md` | Fachliche Dokumentation, Review- und Abschlussnotizen. |

## Live-Migration

Die Migration muss für echte Persistenz in Supabase ausgeführt werden. Ohne diese Migration ist der Reiter im Review sichtbar und lesbar, Speichern bleibt jedoch geschützt deaktiviert beziehungsweise führt zu einem Hinweis. Die vorbereitete Migration legt die fachliche Zielstruktur an und seedet folgende Startpunkte: C3/2026 nächste Rechnung `C3-26-014`, C4/2026 nächste Rechnung `C4-26-1216`, JC/PRIV/2026 nächste Rechnung `JC-26-001` sowie separate Gutschrift-Sequenzen.

## Review-Prozess

Der Branch wurde nach deiner Go-Freigabe für MAN#01 finalisiert. Abschlussreihenfolge: lokale Prüfung, Git-Commit, Push/Merge, danach Memory-/Dokumentationsabschluss. Die Live-Migration bleibt als expliziter Datenbankschritt markiert, weil die direkte DB-Verbindung aus der Sandbox nicht erreichbar war und der Supabase-Pooler den bekannten Tenant/User nicht akzeptierte.

- Debitoren zeigt zusätzlich **Umsatz Leistungsjahr**: Netto-Umsatz wird anteilig nach `service_period_start`/`service_period_end` dem ausgewählten Leistungsjahr zugeordnet, damit Rechnungsdatum und wirtschaftliche Abgrenzung getrennt sichtbar bleiben.
- Debitoren enthält nun einen dynamischen **Projektfilter**. Dieser nutzt die vorhandenen Werte aus `project_no` oder `project_ref`, zum Beispiel `3-24-007-PM`, `3-25-014 EA ÖA`, `4-16-DQS-Loyer` oder `4-25-002`.
- Statushinweis für MAN#01: Der Review-Status ist aktuell eine importierte beziehungsweise statische Arbeitslisten-Angabe. Erst nach Live-Migration und Transaktionslinking kann `linked_txn_id` als technische Grundlage für „bezahlt/reconciled“ verwendet werden.
