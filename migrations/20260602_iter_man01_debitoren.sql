-- ITER MAN#01 — Debitoren-Rechnungen in TGV Core
-- Zweck: manuelle Pflege von Ausgangsrechnungen, fortgeführte Rechnungsnummernlogik,
-- Leistungszeitraum, Skonto, Gutschriften und Transaktionsverknüpfung.
-- Hinweis: Ausführung erst nach Review/Freigabe gegen Supabase.

create table if not exists public.debtor_customers (
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in ('c3','c4','priv')),
  customer_name text not null,
  customer_code text,
  vat_id text,
  billing_address text,
  email text,
  payment_terms_days integer default 30,
  active boolean not null default true,
  source_document_id bigint references public.documents(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity, customer_name)
);

create table if not exists public.invoice_number_sequences (
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in ('c3','c4','priv')),
  fiscal_year integer not null,
  document_kind text not null default 'invoice' check (document_kind in ('invoice','credit_note','storno','reservation')),
  prefix text,
  next_sequence_no integer not null,
  padding integer not null default 3,
  format_hint text,
  notes text,
  updated_at timestamptz not null default now(),
  unique (entity, fiscal_year, document_kind)
);

create table if not exists public.debtor_invoices (
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in ('c3','c4','priv')),
  fiscal_year integer not null,
  document_kind text not null default 'invoice' check (document_kind in ('invoice','credit_note','storno','reservation')),
  running_no integer not null,
  invoice_number_full text not null,
  project_ref text,
  project_no text,
  customer_id uuid references public.debtor_customers(id) on delete set null,
  customer_name text not null,
  title text,
  service_period_start date,
  service_period_end date,
  recognition_year integer,
  invoice_date date,
  due_date date,
  expected_payment_date date,
  net_amount numeric(12,2),
  vat_rate numeric(5,2) default 19.00,
  vat_amount numeric(12,2) generated always as (round(coalesce(net_amount,0) * coalesce(vat_rate,0) / 100, 2)) stored,
  gross_amount numeric(12,2) generated always as (round(coalesce(net_amount,0) * (1 + coalesce(vat_rate,0) / 100), 2)) stored,
  discount_rate numeric(5,2),
  discount_amount numeric(12,2),
  discount_due_date date,
  expected_payment_amount numeric(12,2),
  payment_status text not null default 'open' check (payment_status in ('draft','open','partial','paid','overdue','cancelled','credited')),
  paid_at date,
  linked_txn_id uuid references public.txn_master(id) on delete set null,
  source_document_id bigint references public.documents(id) on delete set null,
  drive_file_id text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity, fiscal_year, document_kind, running_no),
  unique (invoice_number_full)
);

create index if not exists idx_debtor_invoices_entity_year on public.debtor_invoices(entity, fiscal_year);
create index if not exists idx_debtor_invoices_status on public.debtor_invoices(payment_status);
create index if not exists idx_debtor_invoices_txn on public.debtor_invoices(linked_txn_id);
create index if not exists idx_debtor_customers_entity on public.debtor_customers(entity, active);

alter table public.debtor_customers enable row level security;
alter table public.invoice_number_sequences enable row level security;
alter table public.debtor_invoices enable row level security;

do $$ begin
  create policy debtor_customers_auth_all on public.debtor_customers for all to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy invoice_number_sequences_auth_all on public.invoice_number_sequences for all to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy debtor_invoices_auth_all on public.debtor_invoices for all to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

insert into public.invoice_number_sequences(entity, fiscal_year, document_kind, prefix, next_sequence_no, padding, format_hint, notes)
values
  ('c3', 2026, 'invoice', 'C3-26', 14, 3, 'C3-26-014 · optional Text/Projekt', 'C3: Fortführung nach vorhandenen Rechnungen C3-26-001 bis C3-26-013; 014ff. aus Tabelle sichtbar.'),
  ('c4', 2026, 'invoice', 'C4-26', 1216, 0, 'C4-26-1216 · optional Text/Projekt', 'C4: 2026 bisher keine Rechnung; Fortführung nach 2025 bis C4-25-1215.'),
  ('priv', 2026, 'invoice', 'JC-26', 1, 3, 'JC-26-001 · optional Text/Projekt', 'JC/PRIV: Startlogik offen, vor erster Rechnung validieren.'),
  ('c3', 2026, 'credit_note', 'C3-GS-26', 1, 3, 'C3-GS-26-001 · Bezug Rechnung', 'Separate Gutschrift-Nummernlogik.'),
  ('c4', 2026, 'credit_note', 'C4-GS-26', 1, 0, 'C4-GS-26-1 · Bezug Rechnung', 'Separate Gutschrift-Nummernlogik.'),
  ('priv', 2026, 'credit_note', 'JC-GS-26', 1, 3, 'JC-GS-26-001 · Bezug Rechnung', 'Separate Gutschrift-Nummernlogik.')
on conflict (entity, fiscal_year, document_kind) do nothing;

-- MAN#01 initial invoice backfill from existing C3/C4 working tables supplied during review.
-- C3/C4/JC keep format Entität-Jahr-ID-Text/Projekt; C4 continues its historical running sequence with C4 prefix.
insert into public.debtor_customers(entity, customer_name, customer_code, active, notes)
values
  ('c3','eWerk','ewerk',true,'MAN#01 seed from C3 invoice table'),
  ('c3','ZfAM','zfam',true,'MAN#01 seed from C3 invoice table'),
  ('c3','convis GmbH','convis',true,'MAN#01 seed from C3 invoice table'),
  ('c3','EA','ea',true,'MAN#01 seed from C3 invoice table'),
  ('c4','Berthon','berthon',true,'MAN#01 seed from C4 invoice table'),
  ('c4','Le Moal','le-moal',true,'MAN#01 seed from C4 invoice table'),
  ('c4','RATP CAP','ratp-cap',true,'MAN#01 seed from C4 invoice table'),
  ('c4','DQS','dqs',true,'MAN#01 seed from C4 invoice table'),
  ('c4','RATP MOP','ratp-mop',true,'MAN#01 seed from C4 invoice table')
on conflict (entity, customer_name) do update set active=excluded.active, updated_at=now();

insert into public.debtor_invoices(entity, fiscal_year, document_kind, running_no, invoice_number_full, project_ref, project_no, customer_name, title, service_period_start, service_period_end, recognition_year, invoice_date, expected_payment_date, net_amount, vat_rate, discount_amount, expected_payment_amount, payment_status, paid_at, notes)
values
  ('c3',2025,'invoice',23,'C3-25-023',null,null,'eWerk','Seminar März 2026','2026-03-01','2026-03-31',2026,'2025-12-18',null,1660.00,19.00,null,1975.40,'paid',null,'MAN#01 seed C3; Zahlungsdatum nicht aus Screenshot ablesbar'),
  ('c3',2026,'invoice',1,'C3-26-001','3-24-007-PM','3-24-007-PM','ZfAM','Plan ZfAM 3Q und 4Q 2025 PM','2025-07-01','2025-12-31',2025,'2026-01-12',null,10218.70,19.00,null,12160.25,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',2,'C3-26-002','3-24-007-ÖA','3-24-007-ÖA','ZfAM','Plan ZfAM 3Q und 4Q 2025 ÖA','2025-07-01','2025-12-31',2025,'2026-01-12',null,7271.48,19.00,null,8653.06,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',3,'C3-26-003','00 convis-MKT','00 convis-MKT','convis GmbH','Pauschalleistungen Januar','2026-01-01','2026-01-31',2026,'2026-02-02',null,6819.75,19.00,null,8115.50,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',4,'C3-26-004','3-25-014 EA ÖA','3-25-014 EA ÖA','EA','Leistungen extern','2025-01-01','2025-12-31',2025,'2026-02-09',null,544.17,19.00,null,647.56,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',5,'C3-26-005','00 convis-MKT','00 convis-MKT','convis GmbH','Pauschalleistungen Februar','2026-02-01','2026-02-28',2026,'2026-03-03',null,6666.67,19.00,null,7933.34,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',6,'C3-26-006','3-24-007-PM','3-24-007-PM','ZfAM','Plan ZfAM 1Q 2026 PM','2026-01-01','2026-03-31',2026,'2026-04-01',null,5024.35,19.00,null,5978.98,'open',null,'MAN#01 seed C3; Zahlungsstatus aus Screenshot zu prüfen'),
  ('c3',2026,'invoice',7,'C3-26-007','3-24-007-ÖA','3-24-007-ÖA','ZfAM','Plan ZfAM 1Q 2026 ÖA','2026-01-01','2026-03-31',2026,'2026-04-01',null,3981.10,19.00,null,4737.51,'open',null,'MAN#01 seed C3; Zahlungsstatus aus Screenshot zu prüfen'),
  ('c3',2026,'invoice',8,'C3-26-008','00 convis-MKT','00 convis-MKT','convis GmbH','Pauschalleistungen März','2026-03-01','2026-03-31',2026,'2026-04-01',null,6666.67,19.00,null,7933.34,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',9,'C3-26-009','3-25-014 EA ÖA','3-25-014 EA ÖA','EA','ÖA Leistungen 1Q26','2026-01-01','2026-03-31',2026,'2026-04-03',null,10323.04,19.00,null,12284.42,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',10,'C3-26-010','3-21-013 EA CB','3-21-013 EA CB','EA','Chatbot Betrieb März 2026','2026-03-01','2026-03-31',2026,'2026-05-08',null,1269.38,19.00,null,1510.56,'paid',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',11,'C3-26-011','00 convis-MKT','00 convis-MKT','convis GmbH','Pauschalleistungen April','2026-04-01','2026-04-30',2026,'2026-05-04',null,6666.67,19.00,null,7933.34,'open',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',12,'C3-26-012','3-21-013 EA CB','3-21-013 EA CB','EA','Chatbot Betrieb April 2026','2026-04-01','2026-04-30',2026,'2026-05-20',null,8072.02,19.00,null,9605.70,'open',null,'MAN#01 seed C3'),
  ('c3',2026,'invoice',13,'C3-26-013','00 convis-MKT','00 convis-MKT','convis GmbH','Pauschalleistungen Mai','2026-05-01','2026-05-31',2026,'2026-06-02',null,6666.67,19.00,null,7933.34,'open',null,'MAN#01 seed C3'),
  ('c4',2025,'invoice',1205,'C4-25-1205','RATP MOP direct',null,'Berthon','Conseil mop apporteur affaire',null,null,2025,'2025-01-02','2025-01-15',607.50,20.00,null,729.00,'paid','2025-02-06','MAN#01 seed C4'),
  ('c4',2025,'invoice',1206,'C4-25-1206','SODEXO',null,'Le Moal','Veille reglementaire',null,null,2025,'2025-02-12','2025-02-28',2550.00,20.00,null,3060.00,'paid','2025-12-01','MAN#01 seed C4; erwartetes Datum im Screenshot 29.2.2025 normalisiert'),
  ('c4',2025,'invoice',1207,'C4-25-1207','RATP CAP',null,'RATP CAP','SMI RATP CAP 21.2.2025',null,null,2025,'2025-03-05','2025-04-01',900.00,20.00,null,1080.00,'paid','2025-04-10','MAN#01 seed C4'),
  ('c4',2025,'invoice',1208,'C4-25-1208','4-16-DQS-Loyer',null,'DQS','DQS Loyer 2T25 1.04.2025 - 30.06.2025','2025-04-01','2025-06-30',2025,'2025-04-01','2024-12-01',7988.70,20.00,null,9586.44,'paid','2025-04-08','MAN#01 seed C4'),
  ('c4',2025,'invoice',1209,'C4-25-1209','RATP CAP',null,'RATP CAP','SMI RATP CAP 17.4.25',null,null,2025,'2025-04-17','2025-06-17',900.00,20.00,null,1080.00,'paid','2025-07-31','MAN#01 seed C4'),
  ('c4',2025,'invoice',1210,'C4-25-1210','RATP CAP',null,'RATP CAP','SMI RATP CAP 26.5.25',null,null,2025,'2025-05-26','2025-08-26',900.00,20.00,null,1080.00,'paid','2025-06-26','MAN#01 seed C4'),
  ('c4',2025,'invoice',1211,'C4-25-1211','RATP CAP',null,'RATP CAP','SMI RATP CAP 25.7.25',null,null,2025,'2025-09-02','2025-11-02',900.00,20.00,null,1080.00,'paid','2025-10-15','MAN#01 seed C4'),
  ('c4',2025,'invoice',1212,'C4-25-1212','4-16-DQS-Loyer',null,'DQS','DQS Loyer 3T25 1.07.F52825 - 30.09.2025','2025-07-01','2025-09-30',2025,'2025-10-23','2025-11-23',7988.70,20.00,null,9586.44,'paid','2026-01-12','MAN#01 seed C4'),
  ('c4',2025,'invoice',1213,'C4-25-1213','RATP CAP',null,'RATP CAP','SMI RATP CAP 26.5.2531.10.25',null,null,2025,'2025-11-12','2025-12-15',900.00,20.00,null,1080.00,'paid','2025-12-15','MAN#01 seed C4'),
  ('c4',2025,'invoice',1214,'C4-25-1214','4-25-002',null,'RATP MOP','Audit interne MOP',null,null,2025,'2025-12-31','2026-03-10',15750.00,20.00,null,18900.00,'open',null,'MAN#01 seed C4'),
  ('c4',2025,'invoice',1215,'C4-25-1215','RATP CAP',null,'RATP CAP','SMI RATP CAP 5.12.25',null,null,2025,'2025-12-31','2026-03-06',900.00,20.00,null,1080.00,'paid','2026-01-30','MAN#01 seed C4')
on conflict (entity, fiscal_year, document_kind, running_no) do update set
  invoice_number_full=excluded.invoice_number_full,
  project_ref=excluded.project_ref,
  project_no=excluded.project_no,
  customer_name=excluded.customer_name,
  title=excluded.title,
  service_period_start=excluded.service_period_start,
  service_period_end=excluded.service_period_end,
  recognition_year=excluded.recognition_year,
  invoice_date=excluded.invoice_date,
  expected_payment_date=excluded.expected_payment_date,
  net_amount=excluded.net_amount,
  vat_rate=excluded.vat_rate,
  discount_amount=excluded.discount_amount,
  expected_payment_amount=excluded.expected_payment_amount,
  payment_status=excluded.payment_status,
  paid_at=excluded.paid_at,
  notes=excluded.notes,
  updated_at=now();

update public.invoice_number_sequences set next_sequence_no=14, updated_at=now()
where entity='c3' and fiscal_year=2026 and document_kind='invoice' and next_sequence_no < 14;
update public.invoice_number_sequences set next_sequence_no=1216, updated_at=now()
where entity='c4' and fiscal_year=2026 and document_kind='invoice' and next_sequence_no < 1216;

