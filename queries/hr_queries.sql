-- ============================================================
-- HR Analytics Portfolio — Requêtes SQL
-- Dialecte   : SQLite
-- Auteur      : Ilham | Data Analyste
-- Mise à jour : 2024-12-01
-- Données     : employees, performance, absences, salaries
-- ============================================================


-- ============================================================
-- Q1 — TAUX DE TURNOVER PAR DÉPARTEMENT ET PAR ANNÉE
-- ============================================================
-- Calcule pour chaque département le taux de turnover annuel
-- (nb départs / effectif début de période × 100).
-- Les employés "Inactif" sont considérés comme ayant quitté
-- l'entreprise au cours de l'année de leur dernière présence.
-- ============================================================

WITH annees AS (
    SELECT 2022 AS annee UNION ALL
    SELECT 2023          UNION ALL
    SELECT 2024
),
effectif_debut AS (
    -- Employés présents au 1er janvier de chaque année
    SELECT
        a.annee,
        e.departement,
        COUNT(*) AS effectif_debut
    FROM annees a
    JOIN employees e
        ON strftime('%Y', e.date_embauche) < CAST(a.annee AS TEXT)
    WHERE e.statut = 'Actif'
    GROUP BY a.annee, e.departement
),
departs AS (
    -- Employés inactifs embauchés avant ou pendant l'année
    SELECT
        a.annee,
        e.departement,
        COUNT(*) AS nb_departs
    FROM annees a
    JOIN employees e
        ON strftime('%Y', e.date_embauche) <= CAST(a.annee AS TEXT)
       AND e.statut = 'Inactif'
    GROUP BY a.annee, e.departement
)
SELECT
    ed.annee,
    ed.departement,
    ed.effectif_debut,
    COALESCE(d.nb_departs, 0)                                             AS nb_departs,
    ROUND(
        COALESCE(d.nb_departs, 0) * 100.0 / NULLIF(ed.effectif_debut, 0),
        1
    )                                                                      AS taux_turnover_pct
FROM effectif_debut ed
LEFT JOIN departs d
    ON ed.annee = d.annee AND ed.departement = d.departement
ORDER BY ed.annee, taux_turnover_pct DESC;


-- ============================================================
-- Q2 — CORRÉLATION SCORE PERFORMANCE / ÉVOLUTION SALAIRE
-- ============================================================
-- Groupe les employés actifs par bucket de score, puis compare
-- l'évolution salariale moyenne, le salaire de base et le
-- nombre d'éligibles à une promotion dans chaque bucket.
-- ============================================================

WITH perf_sal AS (
    SELECT
        p.employee_id,
        e.departement,
        e.genre,
        p.score_performance,
        p.eligible_promotion,
        s."évolution_%"                              AS evolution_salaire_pct,
        s.salaire_base,
        s.bonus,
        CASE
            WHEN p.score_performance < 3.0 THEN '1 — < 3.0 (Insuffisant)'
            WHEN p.score_performance < 3.5 THEN '2 — 3.0–3.4 (En dessous)'
            WHEN p.score_performance < 4.0 THEN '3 — 3.5–3.9 (Satisfaisant)'
            WHEN p.score_performance < 4.5 THEN '4 — 4.0–4.4 (Bien)'
            ELSE                                '5 — ≥ 4.5 (Excellent)'
        END                                          AS bucket_score
    FROM performance p
    JOIN employees   e ON p.employee_id = e.employee_id
    JOIN salaries    s ON p.employee_id = s.employee_id
    WHERE e.statut = 'Actif'
)
SELECT
    bucket_score,
    COUNT(*)                                                        AS nb_employes,
    ROUND(AVG(score_performance), 2)                                AS score_moyen,
    ROUND(AVG(evolution_salaire_pct), 2)                            AS evolution_sal_moy_pct,
    ROUND(MIN(evolution_salaire_pct), 1)                            AS evolution_min,
    ROUND(MAX(evolution_salaire_pct), 1)                            AS evolution_max,
    ROUND(AVG(salaire_base), 0)                                     AS salaire_base_moyen,
    COUNT(CASE WHEN eligible_promotion = 'Oui' THEN 1 END)          AS nb_eligibles_promotion
FROM perf_sal
GROUP BY bucket_score
ORDER BY bucket_score;


-- ============================================================
-- Q3 — TOP 10 EMPLOYÉS LES PLUS ABSENTS vs PERFORMANCE
-- ============================================================
-- Agrège les absences par employé et les croise avec leur score
-- de performance. Calcule un niveau de risque combiné basé sur
-- les absences injustifiées et le score de performance.
-- ============================================================

WITH absences_par_emp AS (
    SELECT
        employee_id,
        COUNT(*)                                             AS nb_episodes,
        SUM(durée_jours)                                     AS total_jours_absents,
        COUNT(CASE WHEN justifiée = 'Non'         THEN 1 END) AS absences_injustifiees,
        COUNT(CASE WHEN type_absence = 'Maladie'  THEN 1 END) AS absences_maladie,
        COUNT(CASE WHEN type_absence = 'Formation' THEN 1 END) AS formations
    FROM absences
    GROUP BY employee_id
),
classement AS (
    SELECT
        e.employee_id,
        e.prenom || ' ' || e.nom             AS nom_complet,
        e.departement,
        e.poste,
        e.statut,
        COALESCE(a.nb_episodes, 0)           AS nb_episodes,
        COALESCE(a.total_jours_absents, 0)   AS total_jours_absents,
        COALESCE(a.absences_injustifiees, 0) AS absences_injustifiees,
        COALESCE(a.absences_maladie, 0)      AS absences_maladie,
        p.score_performance,
        p.eligible_promotion,
        -- Niveau de risque RH combiné
        CASE
            WHEN COALESCE(a.absences_injustifiees, 0) >= 2
                 AND p.score_performance < 3.5         THEN '🔴 Risque élevé'
            WHEN COALESCE(a.total_jours_absents, 0) > 10
                 OR COALESCE(a.absences_injustifiees, 0) >= 1 THEN '🟡 À surveiller'
            ELSE                                             '🟢 Normal'
        END                                  AS niveau_risque
    FROM employees   e
    JOIN performance p ON e.employee_id = p.employee_id
    LEFT JOIN absences_par_emp a ON e.employee_id = a.employee_id
)
SELECT *
FROM classement
ORDER BY total_jours_absents DESC, absences_injustifiees DESC
LIMIT 10;


-- ============================================================
-- Q4 — DISTRIBUTION DES PROMOTIONS PAR GENRE ET ANCIENNETÉ
-- ============================================================
-- Croise l'éligibilité à la promotion avec le genre et la
-- tranche d'ancienneté pour détecter d'éventuels biais.
-- ============================================================

WITH profil_employe AS (
    SELECT
        e.employee_id,
        e.genre,
        e.departement,
        CAST(
            (julianday('2024-12-31') - julianday(e.date_embauche)) / 365.25
        AS INTEGER)                          AS anciennete_annees,
        CASE
            WHEN (julianday('2024-12-31') - julianday(e.date_embauche)) / 365.25 < 2
                THEN '1 — 0–2 ans'
            WHEN (julianday('2024-12-31') - julianday(e.date_embauche)) / 365.25 < 4
                THEN '2 — 2–4 ans'
            WHEN (julianday('2024-12-31') - julianday(e.date_embauche)) / 365.25 < 6
                THEN '3 — 4–6 ans'
            ELSE '4 — 6 ans et +'
        END                                  AS tranche_anciennete,
        p.score_performance,
        p.eligible_promotion
    FROM employees   e
    JOIN performance p ON e.employee_id = p.employee_id
    WHERE e.statut = 'Actif'
)
SELECT
    genre,
    tranche_anciennete,
    COUNT(*)                                                                  AS total_employes,
    COUNT(CASE WHEN eligible_promotion = 'Oui' THEN 1 END)                    AS nb_eligibles,
    ROUND(
        COUNT(CASE WHEN eligible_promotion = 'Oui' THEN 1 END) * 100.0
        / COUNT(*), 1
    )                                                                          AS taux_eligibilite_pct,
    ROUND(AVG(score_performance), 2)                                           AS score_moyen,
    ROUND(AVG(anciennete_annees), 1)                                           AS anciennete_moy
FROM profil_employe
GROUP BY genre, tranche_anciennete
ORDER BY genre, tranche_anciennete;


-- ============================================================
-- Q5 — COÛT MOYEN PAR DÉPARTEMENT (SALAIRES + BONUS + CHARGES)
-- ============================================================
-- Calcule la rémunération totale et le coût employeur réel
-- (charges patronales ≈ 45 % du brut, secteur tech France)
-- par département, avec la part dans le budget total.
-- ============================================================

WITH cout_par_emp AS (
    SELECT
        e.employee_id,
        e.departement,
        e.genre,
        e.type_contrat,
        s.salaire_base,
        s.bonus,
        s.salaire_base + s.bonus                          AS remuneration_totale,
        -- Charges patronales estimées à 45 % du brut
        ROUND((s.salaire_base + s.bonus) * 0.45, 0)      AS charges_patronales,
        ROUND((s.salaire_base + s.bonus) * 1.45, 0)      AS cout_total_employeur
    FROM employees e
    JOIN salaries  s ON e.employee_id = s.employee_id
    WHERE e.statut = 'Actif'
),
budget_total AS (
    SELECT SUM(cout_total_employeur) AS total_entreprise
    FROM cout_par_emp
)
SELECT
    c.departement,
    COUNT(*)                                              AS nb_employes,
    ROUND(MIN(c.remuneration_totale), 0)                  AS remun_min,
    ROUND(MAX(c.remuneration_totale), 0)                  AS remun_max,
    ROUND(AVG(c.remuneration_totale), 0)                  AS remun_moyenne,
    SUM(c.remuneration_totale)                            AS masse_salariale_brute,
    ROUND(AVG(c.cout_total_employeur), 0)                 AS cout_moyen_employeur,
    SUM(c.cout_total_employeur)                           AS cout_total_dept,
    ROUND(
        SUM(c.cout_total_employeur) * 100.0
        / bt.total_entreprise,
        1
    )                                                     AS pct_budget_total
FROM cout_par_emp c
CROSS JOIN budget_total bt
GROUP BY c.departement, bt.total_entreprise
ORDER BY cout_total_dept DESC;
