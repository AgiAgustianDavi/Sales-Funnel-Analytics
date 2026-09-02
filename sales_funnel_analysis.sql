-- ============================================================================
-- SALES FUNNEL ANALYSIS - PostgreSQL Script
-- Divisi Sales - B2B Distribution Company
-- ============================================================================
-- Berisi views untuk menjawab 5 business questions:
--   1. Funnel drop-off & conversion rate per stage
--   2. Win rate per sales rep
--   3. Kualitas lead per lead source
--   4. Sales cycle length (overall & per region)
--   5. Alasan utama Closed Lost
--
-- CATATAN DATA QUALITY (berlaku di seluruh script):
--   - region, lead_source, sales_rep, deal_value, lost_reason mengandung NULL
--     signifikan (lihat laporan analisis untuk persentase detail)
--   - current_stage adalah SNAPSHOT (stage terakhir/terjauh yang dicapai lead),
--     bukan log historis tiap perpindahan stage. Sehingga "drop-off per stage"
--     di sini adalah PROXY (cumulative funnel), bukan tracking pasti titik
--     lead tersebut mati.
--   - Beberapa region punya sample size kecil untuk deal closed (n<15) -
--     interpretasi harus hati-hati (lihat vw_cycle_length_by_region).
-- ============================================================================


-- ============================================================================
-- 0. DDL - Struktur tabel sumber (referensi, sesuaikan dg proses load data)
-- ============================================================================
DROP TABLE IF EXISTS sales_funnel_leads CASCADE;

CREATE TABLE sales_funnel_leads (
    lead_id             VARCHAR(20)     PRIMARY KEY,
    company_name        VARCHAR(255),
    industry            VARCHAR(100),
    lead_source         VARCHAR(50),
    sales_rep           VARCHAR(100),
    region              VARCHAR(50),
    created_date        DATE            NOT NULL,
    current_stage       VARCHAR(30)     NOT NULL,
    stage_last_updated  DATE            NOT NULL,
    last_contact_date   DATE,
    deal_value          NUMERIC(15,2),
    lost_reason         VARCHAR(100),
    notes               TEXT
);

-- Load data, contoh (sesuaikan path):
-- \copy sales_funnel_leads FROM 'sales_funnel_leads_clean.csv' WITH (FORMAT csv, HEADER true);


-- ============================================================================
-- HELPER VIEW: stage_rank
-- Memberi urutan numerik pada current_stage agar bisa dihitung secara
-- cumulative. Closed Won & Closed Lost disatukan sebagai stage "Closed"
-- (rank tertinggi) karena keduanya = leads yang sudah melewati seluruh
-- tahap funnel aktif.
-- ============================================================================
CREATE OR REPLACE VIEW vw_leads_with_stage_rank AS
SELECT
    *,
    CASE current_stage
        WHEN 'Lead In'        THEN 0
        WHEN 'Contacted'      THEN 1
        WHEN 'Qualified'      THEN 2
        WHEN 'Proposal Sent'  THEN 3
        WHEN 'Negotiation'    THEN 4
        WHEN 'Closed Won'     THEN 5
        WHEN 'Closed Lost'    THEN 5
        ELSE NULL
    END AS stage_rank
FROM sales_funnel_leads;


-- ============================================================================
-- Q1a. FUNNEL CUMULATIVE CONVERSION PER STAGE
-- Menjawab: di tahap mana leads paling banyak gugur / conversion rate tiap
-- tahap (cumulative: leads yang mencapai stage X atau lebih jauh)
-- ============================================================================
CREATE OR REPLACE VIEW vw_funnel_stage_conversion AS
WITH stage_labels(stage_rank, stage_name) AS (
    VALUES (0,'Lead In'), (1,'Contacted'), (2,'Qualified'),
           (3,'Proposal Sent'), (4,'Negotiation'), (5,'Closed')
),
total_leads AS (
    SELECT COUNT(*)::NUMERIC AS n FROM vw_leads_with_stage_rank
),
cumulative_counts AS (
    SELECT
        sl.stage_rank,
        sl.stage_name,
        COUNT(l.lead_id) AS leads_reached_or_beyond
    FROM stage_labels sl
    LEFT JOIN vw_leads_with_stage_rank l
        ON l.stage_rank >= sl.stage_rank
    GROUP BY sl.stage_rank, sl.stage_name
)
SELECT
    stage_rank,
    stage_name,
    leads_reached_or_beyond,
    ROUND(leads_reached_or_beyond * 100.0 / (SELECT n FROM total_leads), 1)
        AS pct_of_total_leads,
    ROUND(
        leads_reached_or_beyond * 100.0
        / NULLIF(LAG(leads_reached_or_beyond) OVER (ORDER BY stage_rank), 0)
    , 1) AS conversion_from_prev_stage_pct
FROM cumulative_counts
ORDER BY stage_rank;


-- ============================================================================
-- Q1b. DISTRIBUSI LEADS AKTIF (BELUM CLOSED) PER STAGE
-- Menjawab: di stage mana leads yang MASIH AKTIF paling banyak menumpuk/stalled
-- ============================================================================
CREATE OR REPLACE VIEW vw_active_stage_distribution AS
SELECT
    current_stage,
    COUNT(*) AS n_active_leads,
    ROUND(AVG(CURRENT_DATE - stage_last_updated), 1) AS avg_days_since_last_update,
    ROUND(
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1
    ) AS pct_of_active_leads
FROM sales_funnel_leads
WHERE current_stage NOT IN ('Closed Won', 'Closed Lost')
GROUP BY current_stage
ORDER BY n_active_leads DESC;


-- ============================================================================
-- Q2a. WIN RATE PER SALES REP
-- Menjawab: sales rep dengan win rate tertinggi vs terendah
-- (win rate dihitung dari leads yang sudah closed / decided saja)
-- ============================================================================
CREATE OR REPLACE VIEW vw_winrate_per_rep AS
SELECT
    sales_rep,
    COUNT(*) FILTER (WHERE current_stage = 'Closed Won')  AS closed_won,
    COUNT(*) FILTER (WHERE current_stage = 'Closed Lost') AS closed_lost,
    COUNT(*) FILTER (WHERE current_stage IN ('Closed Won','Closed Lost')) AS total_closed,
    ROUND(
        COUNT(*) FILTER (WHERE current_stage = 'Closed Won') * 100.0
        / NULLIF(COUNT(*) FILTER (WHERE current_stage IN ('Closed Won','Closed Lost')), 0)
    , 1) AS win_rate_pct,
    ROUND(AVG(deal_value) FILTER (WHERE current_stage = 'Closed Won'), 0)
        AS avg_won_deal_value
FROM sales_funnel_leads
WHERE sales_rep IS NOT NULL
GROUP BY sales_rep
ORDER BY win_rate_pct DESC NULLS LAST;


-- ============================================================================
-- Q2b. POLA KERJA / DISIPLIN FOLLOW-UP PER REP
-- Menjawab: perbedaan pola kerja antar rep - proxy via leads aktif yang
-- belum pernah/tidak ada catatan kontak (last_contact_date NULL)
-- ============================================================================
CREATE OR REPLACE VIEW vw_rep_followup_discipline AS
SELECT
    sales_rep,
    COUNT(*) AS n_active_leads,
    COUNT(*) FILTER (WHERE last_contact_date IS NULL) AS n_no_contact_record,
    ROUND(
        COUNT(*) FILTER (WHERE last_contact_date IS NULL) * 100.0 / COUNT(*)
    , 1) AS pct_no_contact_record,
    ROUND(AVG(CURRENT_DATE - stage_last_updated), 1) AS avg_days_stalled
FROM sales_funnel_leads
WHERE current_stage NOT IN ('Closed Won', 'Closed Lost')
  AND sales_rep IS NOT NULL
GROUP BY sales_rep
ORDER BY pct_no_contact_record ASC;


-- ============================================================================
-- Q3. KUALITAS LEAD PER LEAD SOURCE
-- Menjawab: lead source mana yang menghasilkan leads paling berkualitas
-- (paling banyak jadi Closed Won), plus avg deal value
-- ============================================================================
CREATE OR REPLACE VIEW vw_leadsource_quality AS
SELECT
    lead_source,
    COUNT(*) AS total_leads,
    COUNT(*) FILTER (WHERE current_stage = 'Closed Won')  AS closed_won,
    COUNT(*) FILTER (WHERE current_stage = 'Closed Lost') AS closed_lost,
    ROUND(
        COUNT(*) FILTER (WHERE current_stage = 'Closed Won') * 100.0 / COUNT(*)
    , 1) AS won_rate_of_total_pct,
    ROUND(
        COUNT(*) FILTER (WHERE current_stage = 'Closed Won') * 100.0
        / NULLIF(COUNT(*) FILTER (WHERE current_stage IN ('Closed Won','Closed Lost')), 0)
    , 1) AS win_rate_of_closed_pct,
    ROUND(AVG(deal_value) FILTER (WHERE current_stage = 'Closed Won'), 0)
        AS avg_won_deal_value
FROM sales_funnel_leads
WHERE lead_source IS NOT NULL
GROUP BY lead_source
ORDER BY won_rate_of_total_pct DESC;


-- ============================================================================
-- Q4a. SALES CYCLE LENGTH - OVERALL (WON vs LOST)
-- Menjawab: rata-rata waktu dari Lead In sampai Closed Won/Lost
-- ============================================================================
CREATE OR REPLACE VIEW vw_cycle_length_overall AS
SELECT
    current_stage AS outcome,
    COUNT(*) AS n_deals,
    ROUND(AVG(stage_last_updated - created_date), 1) AS avg_cycle_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (stage_last_updated - created_date))
        AS median_cycle_days
FROM sales_funnel_leads
WHERE current_stage IN ('Closed Won', 'Closed Lost')
GROUP BY current_stage;


-- ============================================================================
-- Q4b. SALES CYCLE LENGTH PER REGION
-- Menjawab: apakah ada perbedaan signifikan sales cycle antar wilayah
-- CATATAN: beberapa region n<15, interpretasi hati-hati (lihat kolom n_deals)
-- ============================================================================
CREATE OR REPLACE VIEW vw_cycle_length_by_region AS
SELECT
    region,
    COUNT(*) AS n_deals,
    ROUND(AVG(stage_last_updated - created_date), 1) AS avg_cycle_days,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY (stage_last_updated - created_date))
        AS median_cycle_days
FROM sales_funnel_leads
WHERE current_stage IN ('Closed Won', 'Closed Lost')
  AND region IS NOT NULL
GROUP BY region
ORDER BY avg_cycle_days DESC;


-- ============================================================================
-- Q5a. DISTRIBUSI ALASAN CLOSED LOST
-- Menjawab: apa alasan utama leads menjadi Closed Lost
-- ============================================================================
CREATE OR REPLACE VIEW vw_lost_reason_distribution AS
SELECT
    COALESCE(lost_reason, '(Tidak tercatat)') AS lost_reason,
    COUNT(*) AS n_leads,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_all_lost
FROM sales_funnel_leads
WHERE current_stage = 'Closed Lost'
GROUP BY lost_reason
ORDER BY n_leads DESC;


-- ============================================================================
-- Q5b. LOST REASON x REGION (crosstab sederhana)
-- Menjawab: apakah alasan lost bervariasi per wilayah
-- ============================================================================
CREATE OR REPLACE VIEW vw_lost_reason_by_region AS
SELECT
    COALESCE(lost_reason, '(Tidak tercatat)') AS lost_reason,
    region,
    COUNT(*) AS n_leads
FROM sales_funnel_leads
WHERE current_stage = 'Closed Lost'
  AND region IS NOT NULL
GROUP BY lost_reason, region
ORDER BY lost_reason, n_leads DESC;


-- ============================================================================
-- Q5c. LOST REASON x LEAD SOURCE (crosstab sederhana)
-- Menjawab: apakah alasan lost bervariasi per sumber lead
-- ============================================================================
CREATE OR REPLACE VIEW vw_lost_reason_by_source AS
SELECT
    COALESCE(lost_reason, '(Tidak tercatat)') AS lost_reason,
    lead_source,
    COUNT(*) AS n_leads
FROM sales_funnel_leads
WHERE current_stage = 'Closed Lost'
  AND lead_source IS NOT NULL
GROUP BY lost_reason, lead_source
ORDER BY lost_reason, n_leads DESC;


-- ============================================================================
-- CONTOH PEMANGGILAN VIEWS
-- ============================================================================
-- SELECT * FROM vw_funnel_stage_conversion;
-- SELECT * FROM vw_active_stage_distribution;
-- SELECT * FROM vw_winrate_per_rep;
-- SELECT * FROM vw_rep_followup_discipline;
-- SELECT * FROM vw_leadsource_quality;
-- SELECT * FROM vw_cycle_length_overall;
-- SELECT * FROM vw_cycle_length_by_region;
-- SELECT * FROM vw_lost_reason_distribution;
-- SELECT * FROM vw_lost_reason_by_region;
-- SELECT * FROM vw_lost_reason_by_source;
-- ============================================================================
