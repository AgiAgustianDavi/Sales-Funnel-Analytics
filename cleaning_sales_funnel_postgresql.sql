/* =====================================================================
   CLEANING SCRIPT - Sales Funnel Leads (PostgreSQL)
   Sumber : dbo.sales_funnel_leads_raw (semua kolom TEXT, hasil import CSV mentah)
   Output : dbo.sales_funnel_leads_clean
   Prinsip: pakai fungsi bawaan PostgreSQL (to_date, split_part, length) -
   tidak ada custom function, tidak ada regex untuk parsing tanggal.
   Aturan tanggal ambigu (disepakati): default DD/DD-first, kecuali komponen
   pertama >12 (pasti hari) atau komponen kedua >12 (berarti bulan tak mungkin >12,
   jadi format terpaksa MM-first).
   ===================================================================== */

-- 0. Struktur tabel staging (raw) - sesuaikan nama jika berbeda di environment Anda
/*
CREATE TABLE sales_funnel_leads_raw (
    lead_id             TEXT, company_name TEXT, industry TEXT, lead_source TEXT,
    sales_rep           TEXT, region TEXT, created_date TEXT, current_stage TEXT,
    stage_last_updated  TEXT, last_contact_date TEXT, deal_value_raw TEXT,
    lost_reason         TEXT, notes TEXT
);
*/

DROP TABLE IF EXISTS sales_funnel_leads_clean;

/* ---------------------------------------------------------------------
   STEP 1: Trim whitespace + ubah string kosong jadi NULL untuk semua kolom teks
   --------------------------------------------------------------------- */
WITH trimmed AS (
    SELECT
        NULLIF(TRIM(lead_id), '')              AS lead_id,
        NULLIF(TRIM(company_name), '')         AS company_name,
        NULLIF(TRIM(industry), '')             AS industry,
        NULLIF(TRIM(lead_source), '')          AS lead_source,
        NULLIF(TRIM(sales_rep), '')            AS sales_rep,
        NULLIF(TRIM(region), '')               AS region,
        NULLIF(TRIM(created_date), '')         AS created_date,
        NULLIF(TRIM(current_stage), '')        AS current_stage,
        NULLIF(TRIM(stage_last_updated), '')   AS stage_last_updated,
        NULLIF(TRIM(last_contact_date), '')    AS last_contact_date,
        NULLIF(TRIM(deal_value_raw), '')       AS deal_value_raw,
        NULLIF(TRIM(lost_reason), '')          AS lost_reason,
        NULLIF(TRIM(notes), '')                AS notes
    FROM sales_funnel_leads_raw
),

/* ---------------------------------------------------------------------
   STEP 2: Standardisasi kategori via mapping table (bukan CASE berulang).
   Tinggal tambah baris di VALUES kalau ada kategori baru - tidak perlu ubah query.
   --------------------------------------------------------------------- */
category_map (raw_value, clean_value, field) AS (
    VALUES
        ('construction','Construction','industry'), ('education','Education','industry'),
        ('f&b','F&B','industry'), ('finance','Finance','industry'),
        ('healthcare','Healthcare','industry'), ('logistics','Logistics','industry'),
        ('manufacturing','Manufacturing','industry'), ('retail','Retail','industry'),
        ('technology','Technology','industry'),
        ('cold call','Cold Call','lead_source'), ('email campaign','Email Campaign','lead_source'),
        ('inbound call','Inbound Call','lead_source'), ('linkedin','LinkedIn','lead_source'),
        ('partner','Partner','lead_source'), ('referral','Referral','lead_source'),
        ('social media','Social Media','lead_source'), ('trade show','Trade Show','lead_source'),
        ('website','Website','lead_source'),
        ('ahmad fauzi','Ahmad Fauzi','sales_rep'), ('andi wijaya','Andi Wijaya','sales_rep'),
        ('budi santoso','Budi Santoso','sales_rep'), ('dewi lestari','Dewi Lestari','sales_rep'),
        ('rina marlina','Rina Marlina','sales_rep'), ('rudi hartono','Rudi Hartono','sales_rep'),
        ('siti nurhaliza','Siti Nurhaliza','sales_rep'), ('yuni shara','Yuni Shara','sales_rep'),
        ('bandung','Bandung','region'), ('denpasar','Denpasar','region'),
        ('jakarta','Jakarta','region'), ('makassar','Makassar','region'),
        ('medan','Medan','region'), ('palembang','Palembang','region'),
        ('semarang','Semarang','region'), ('surabaya','Surabaya','region'),
        ('yogyakarta','Yogyakarta','region')
),

standardized AS (
    SELECT
        t.lead_id, t.company_name,
        COALESCE(mi.clean_value, t.industry)     AS industry,
        COALESCE(ms.clean_value, t.lead_source)  AS lead_source,
        COALESCE(mr.clean_value, t.sales_rep)    AS sales_rep,
        COALESCE(mg.clean_value, t.region)       AS region,
        t.created_date, t.current_stage, t.stage_last_updated,
        t.last_contact_date, t.deal_value_raw, t.lost_reason, t.notes
    FROM trimmed t
    LEFT JOIN category_map mi ON mi.field = 'industry'    AND mi.raw_value = LOWER(t.industry)
    LEFT JOIN category_map ms ON ms.field = 'lead_source' AND ms.raw_value = LOWER(t.lead_source)
    LEFT JOIN category_map mr ON mr.field = 'sales_rep'   AND mr.raw_value = LOWER(t.sales_rep)
    LEFT JOIN category_map mg ON mg.field = 'region'      AND mg.raw_value = LOWER(t.region)
),

/* ---------------------------------------------------------------------
   STEP 3: Parsing tanggal multi-format pakai to_date() bawaan PostgreSQL.
   split_part() dipakai hanya untuk MENENTUKAN format mask yang tepat per baris
   (bukan untuk membangun tanggal manual) - parsing sesungguhnya tetap oleh to_date().
   - length(part) = 3   -> pasti nama bulan (Jan/Feb/... selalu 3 huruf)   -> DD-Mon-YYYY
   - length(part1) = 4  -> pasti tahun di depan                           -> YYYY-MM-DD / YYYY/MM/DD
   - part1 > 12         -> pasti hari duluan (bulan max 12)               -> DD-first
   - part2 > 12         -> pasti bulan duluan (hari di posisi 2 > 12)     -> MM-first
   - selain itu (ambigu)-> default DD-first (sesuai kesepakatan)
   --------------------------------------------------------------------- */
dated AS (
    SELECT
        s.*,
        cd.parsed AS created_date_clean,
        su.parsed AS stage_last_updated_clean,
        lc.parsed AS last_contact_date_clean
    FROM standardized s
    CROSS JOIN LATERAL (
        SELECT val, CASE WHEN val LIKE '%/%' THEN '/' ELSE '-' END AS sep
        FROM (SELECT s.created_date AS val) x
    ) c
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN c.val IS NULL THEN NULL
            WHEN length(split_part(c.val, c.sep, 2)) = 3       THEN to_date(c.val, 'DD-Mon-YYYY')
            WHEN length(split_part(c.val, c.sep, 1)) = 4        THEN to_date(c.val, 'YYYY' || c.sep || 'MM' || c.sep || 'DD')
            WHEN split_part(c.val, c.sep, 1)::int > 12          THEN to_date(c.val, 'DD' || c.sep || 'MM' || c.sep || 'YYYY')
            WHEN split_part(c.val, c.sep, 2)::int > 12          THEN to_date(c.val, 'MM' || c.sep || 'DD' || c.sep || 'YYYY')
            ELSE                                                     to_date(c.val, 'DD' || c.sep || 'MM' || c.sep || 'YYYY')
        END AS parsed
    ) cd ON TRUE
    CROSS JOIN LATERAL (
        SELECT val, CASE WHEN val LIKE '%/%' THEN '/' ELSE '-' END AS sep
        FROM (SELECT s.stage_last_updated AS val) x
    ) u
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN u.val IS NULL THEN NULL
            WHEN length(split_part(u.val, u.sep, 2)) = 3       THEN to_date(u.val, 'DD-Mon-YYYY')
            WHEN length(split_part(u.val, u.sep, 1)) = 4        THEN to_date(u.val, 'YYYY' || u.sep || 'MM' || u.sep || 'DD')
            WHEN split_part(u.val, u.sep, 1)::int > 12          THEN to_date(u.val, 'DD' || u.sep || 'MM' || u.sep || 'YYYY')
            WHEN split_part(u.val, u.sep, 2)::int > 12          THEN to_date(u.val, 'MM' || u.sep || 'DD' || u.sep || 'YYYY')
            ELSE                                                     to_date(u.val, 'DD' || u.sep || 'MM' || u.sep || 'YYYY')
        END AS parsed
    ) su ON TRUE
    CROSS JOIN LATERAL (
        SELECT val, CASE WHEN val LIKE '%/%' THEN '/' ELSE '-' END AS sep
        FROM (SELECT s.last_contact_date AS val) x
    ) l
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN l.val IS NULL THEN NULL
            WHEN length(split_part(l.val, l.sep, 2)) = 3       THEN to_date(l.val, 'DD-Mon-YYYY')
            WHEN length(split_part(l.val, l.sep, 1)) = 4        THEN to_date(l.val, 'YYYY' || l.sep || 'MM' || l.sep || 'DD')
            WHEN split_part(l.val, l.sep, 1)::int > 12          THEN to_date(l.val, 'DD' || l.sep || 'MM' || l.sep || 'YYYY')
            WHEN split_part(l.val, l.sep, 2)::int > 12          THEN to_date(l.val, 'MM' || l.sep || 'DD' || l.sep || 'YYYY')
            ELSE                                                     to_date(l.val, 'DD' || l.sep || 'MM' || l.sep || 'YYYY')
        END AS parsed
    ) lc ON TRUE
),

/* ---------------------------------------------------------------------
   STEP 4: Bersihkan deal_value_raw -> numeric. Cukup 3 kondisi lewat
   replace/length/split_part bawaan, tanpa regex.
   --------------------------------------------------------------------- */
valued AS (
    SELECT
        d.*,
        CASE
            WHEN v IS NULL THEN NULL
            WHEN length(v) - length(replace(v, '.', '')) > 1 THEN replace(v, '.', '')::numeric   -- format "Rp x.xxx.xxx" (>1 titik = ribuan)
            WHEN v LIKE '%.0'                                 THEN split_part(v, '.', 1)::numeric -- artifact "xxxx.0 "
            ELSE v::numeric
        END AS deal_value
    FROM dated d
    CROSS JOIN LATERAL (SELECT replace(replace(d.deal_value_raw, 'Rp', ''), ' ', '') AS v) dv
),

/* ---------------------------------------------------------------------
   STEP 5: Hilangkan duplikat lead_id - window function ROW_NUMBER(),
   simpan baris dengan stage_last_updated paling baru per lead_id.
   --------------------------------------------------------------------- */
deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY lead_id
            ORDER BY stage_last_updated_clean DESC NULLS LAST
        ) AS rn
    FROM valued
)

SELECT
    lead_id, company_name, industry, lead_source, sales_rep, region,
    created_date_clean       AS created_date,
    current_stage,
    stage_last_updated_clean AS stage_last_updated,
    last_contact_date_clean  AS last_contact_date,
    deal_value, lost_reason, notes
INTO sales_funnel_leads_clean
FROM deduped
WHERE rn = 1
ORDER BY lead_id;

-- Sanity check
-- SELECT COUNT(*) FROM sales_funnel_leads_clean;                                    -- ekspektasi: 850
-- SELECT lead_id, COUNT(*) FROM sales_funnel_leads_clean GROUP BY lead_id HAVING COUNT(*) > 1; -- ekspektasi: 0 baris
