-- ============================================================
-- ESQUEMA SILVER — Datos de evento enriquecidos
-- BD: football_scouting (PostgreSQL 15+)
-- ============================================================
-- Transforma los eventos crudos de Bronze a un formato listo
-- para análisis. Los 3,2M de eventos se enriquecen con campos
-- derivados.
--
-- Referencias:
--   - Soccermatics (readthedocs): modelo de xG con coordenadas Wyscout
--   - Dato Futbol: cálculo de distance_to_goal + ángulo visible
--   - Karun Singh (2018): Expected Threat con rejilla 12×8
--   - Pappalardo et al. (2019): extracción de features PlayeRank
--
-- Sistema de coordenadas (Wyscout):
--   x: 0 = portería propia, 100 = portería rival (siempre atacando I→D)
--   y: 0 = banda izquierda, 100 = banda derecha
--   Campo estándar: 105m × 68m
--   Portería: 7,32m de ancho, centrada en (105, 34)
--   Postes en y = 30,34m e y = 37,66m
-- ============================================================

CREATE SCHEMA IF NOT EXISTS silver;

DROP TABLE IF EXISTS silver.event_enriched CASCADE;

-- ============================================================
-- 1. EVENTOS ENRIQUECIDOS — Tabla principal de Silver
-- ============================================================
-- Es la tabla analítica central. Cada evento de Bronze se
-- enriquece con campos espaciales y contextuales derivados.
-- ============================================================

CREATE TABLE silver.event_enriched AS
SELECT
    -- ── Identidad (desde Bronze) ────────────────────────────
    e.wy_event_id,
    e.match_id,
    e.player_id,
    e.team_id,
    e.match_period,
    e.event_sec,
    e.event_id,
    e.event_name,
    e.sub_event_id, 
    e.sub_event_name,

    -- ── Coordenadas originales (escala 0-100) ───────────────
    e.pos_orig_x,
    e.pos_orig_y,
    e.pos_dest_x,
    e.pos_dest_y,

    -- ── Coordenadas en metros (campo 105×68) ────────────────
    -- Wyscout 0-100 → metros: x * 1.05, y * 0.68
    ROUND((e.pos_orig_x * 1.05)::numeric, 2)  AS x_m,
    ROUND((e.pos_orig_y * 0.68)::numeric, 2)  AS y_m,
    ROUND((e.pos_dest_x * 1.05)::numeric, 2)  AS x_end_m,
    ROUND((e.pos_dest_y * 0.68)::numeric, 2)  AS y_end_m,

    -- ── Distancia al centro de la portería (105, 34) en metros ─
    -- Usada para el modelo de xG y el análisis de tiro
    ROUND(
        SQRT(
            POWER(105.0 - e.pos_orig_x * 1.05, 2) +
            POWER(34.0  - e.pos_orig_y * 0.68, 2)
        )::numeric, 2
    ) AS dist_to_goal_m,

    -- ── Ángulo a la portería (ángulo visible entre postes) ──
    -- Postes en (105, 30.34) y (105, 37.66)
    -- Fórmula atan2: angle = atan2(goal_width * x_dist,
    --   x_dist² + y_near * y_far)
    -- Donde y_near/y_far = distancia al poste cercano/lejano
    -- Resultado en grados
    CASE 
        WHEN e.pos_orig_x IS NOT NULL THEN
            ROUND(
                DEGREES(
                    ATAN2(
                        7.32 * (105.0 - e.pos_orig_x * 1.05),
                        POWER(105.0 - e.pos_orig_x * 1.05, 2) 
                        + (e.pos_orig_y * 0.68 - 30.34) * (e.pos_orig_y * 0.68 - 37.66)
                    )
                )::numeric, 2
            )
        ELSE NULL
    END AS angle_to_goal_deg,

    -- ── Rejilla de zonas (12 columnas × 8 filas = 96 zonas) ─
    -- Rejilla estándar para modelos de Expected Threat (xT)
    -- zone_x: 0-11 (izquierda a derecha), zone_y: 0-7 (arriba a abajo)
    LEAST(FLOOR(e.pos_orig_x / 8.334)::int, 11)  AS zone_x,
    LEAST(FLOOR(e.pos_orig_y / 12.5)::int, 7)     AS zone_y,

    -- ── ID de zona (entero único 0-95 para agrupar más fácil) ─
    LEAST(FLOOR(e.pos_orig_x / 8.334)::int, 11) * 8 
    + LEAST(FLOOR(e.pos_orig_y / 12.5)::int, 7)   AS zone_id,

    -- ── Distancia y dirección de pase (solo para pases) ─────
    CASE 
        WHEN e.event_name = 'Pass' AND e.pos_dest_x IS NOT NULL THEN
            ROUND(
                SQRT(
                    POWER((e.pos_dest_x - e.pos_orig_x) * 1.05, 2) +
                    POWER((e.pos_dest_y - e.pos_orig_y) * 0.68, 2)
                )::numeric, 2
            )
        ELSE NULL
    END AS pass_distance_m,

    -- El pase es progresivo si el destino está ≥10m más cerca de la portería
    CASE
        WHEN e.event_name = 'Pass' AND e.pos_dest_x IS NOT NULL THEN
            (
                SQRT(POWER(105.0 - e.pos_orig_x * 1.05, 2) + POWER(34.0 - e.pos_orig_y * 0.68, 2))
                - SQRT(POWER(105.0 - e.pos_dest_x * 1.05, 2) + POWER(34.0 - e.pos_dest_y * 0.68, 2))
            ) >= 10.0
        ELSE FALSE
    END AS is_progressive_pass,
    -- Distancia que se avanza a portería con cada pase
    CASE
    WHEN e.event_name = 'Pass' AND e.pos_dest_x IS NOT NULL THEN
        ROUND((
            SQRT(POWER(105.0 - e.pos_orig_x * 1.05, 2) + POWER(34.0 - e.pos_orig_y * 0.68, 2))
          - SQRT(POWER(105.0 - e.pos_dest_x * 1.05, 2) + POWER(34.0 - e.pos_dest_y * 0.68, 2))
        )::numeric, 2)
    ELSE NULL
        END AS pass_goal_distance_delta_m,

    -- ── Tags descompuestos en flags booleanos ───────────────
        -- Goles y anotación
        (101 = ANY(e.tags))  AS is_goal,
        (102 = ANY(e.tags))  AS is_own_goal,
        (301 = ANY(e.tags))  AS is_assist,
        (302 = ANY(e.tags))  AS is_key_pass,

        -- Parte del cuerpo
        (401 = ANY(e.tags))  AS is_left_foot,
        (402 = ANY(e.tags))  AS is_right_foot,
        (403 = ANY(e.tags))  AS is_head_body,
        CASE
            WHEN 401 = ANY(e.tags) THEN 'left'
            WHEN 402 = ANY(e.tags) THEN 'right'
            WHEN 403 = ANY(e.tags) THEN 'head_body'
            ELSE NULL
        END AS body_part,

        -- Contexto
        (501 = ANY(e.tags))  AS is_free_space_right,
        (502 = ANY(e.tags))  AS is_free_space_left,
        ((501 = ANY(e.tags)) OR (502 = ANY(e.tags))) AS is_free_space,
        (1901 = ANY(e.tags)) AS is_counterattack,

        -- Resultado de balón / tiro
        (2001 = ANY(e.tags)) AS is_dangerous_ball_lost,
        (2101 = ANY(e.tags)) AS is_blocked,
        (201 = ANY(e.tags))  AS is_opportunity,
        (1101 = ANY(e.tags)) AS is_direct,
        (1102 = ANY(e.tags)) AS is_indirect,

        -- Precisión
        (1801 = ANY(e.tags)) AS is_accurate,
        (1802 = ANY(e.tags)) AS is_not_accurate,

        -- Disciplina
        (1702 = ANY(e.tags)) AS is_yellow_card,
        (1701 = ANY(e.tags)) AS is_red_card,
        (1703 = ANY(e.tags)) AS is_second_yellow,

        -- Acciones defensivas
        (1401 = ANY(e.tags)) AS is_interception,
        (1501 = ANY(e.tags)) AS is_clearance,
        (1601 = ANY(e.tags)) AS is_sliding_tackle,

        -- Colocación del tiro (tags oficiales)
        (1201 = ANY(e.tags)) AS is_goal_low_center,
        (1202 = ANY(e.tags)) AS is_goal_low_right,
        (1203 = ANY(e.tags)) AS is_goal_center,
        (1204 = ANY(e.tags)) AS is_goal_center_left,
        (1205 = ANY(e.tags)) AS is_goal_low_left,
        (1206 = ANY(e.tags)) AS is_goal_center_right,
        (1207 = ANY(e.tags)) AS is_goal_high_center,
        (1208 = ANY(e.tags)) AS is_goal_high_left,
        (1209 = ANY(e.tags)) AS is_goal_high_right,
        (e.event_name = 'Free Kick' AND e.sub_event_name = 'Penalty') AS is_penalty_shot,
        (e.event_name = 'Free Kick' AND e.sub_event_name = 'Free kick shot') AS is_free_kick_shot,

    -- Grupos de colocación derivados
    ((1201 = ANY(e.tags)) OR (1202 = ANY(e.tags)) OR (1205 = ANY(e.tags))) AS is_goal_low,
    ((1203 = ANY(e.tags)) OR (1204 = ANY(e.tags)) OR (1206 = ANY(e.tags))) AS is_goal_mid,
    ((1207 = ANY(e.tags)) OR (1208 = ANY(e.tags)) OR (1209 = ANY(e.tags))) AS is_goal_high,

    -- Features temporales básicas
    FLOOR(e.event_sec / 60.0)::int AS minute_in_period,
    CASE
        WHEN e.match_period = '1H' THEN FLOOR(e.event_sec / 60.0)::int
        WHEN e.match_period = '2H' THEN FLOOR(e.event_sec / 60.0)::int + 45
        WHEN e.match_period = 'E1' THEN FLOOR(e.event_sec / 60.0)::int + 90
        WHEN e.match_period = 'E2' THEN FLOOR(e.event_sec / 60.0)::int + 105
        ELSE NULL
    END AS minute_match,
    CASE
        WHEN e.match_period = '1H' THEN e.event_sec
        WHEN e.match_period = '2H' THEN e.event_sec + 45*60
        WHEN e.match_period = 'E1' THEN e.event_sec + 90*60
        WHEN e.match_period = 'E2' THEN e.event_sec + 105*60
        ELSE NULL
    END AS second_match,
    (e.match_period = '1H') AS is_first_half,
    (e.match_period = '2H') AS is_second_half,
    (e.match_period IN ('E1','E2')) AS is_extra_time,
    (e.match_period = 'P') AS is_penalties,

    -- Contexto del partido
    m.competition_id,
    m.home_team_id,
    m.away_team_id,
    CASE WHEN e.team_id = m.home_team_id THEN 'home' ELSE 'away' END AS venue,

    -- Tags crudos
    e.tags

FROM bronze.wyscout_events e
JOIN bronze.wyscout_matches m
  ON e.match_id = m.wy_match_id;

-----------------------------------------------------

-- ============================================================
-- ÍNDICES para patrones de consulta habituales
-- ============================================================
CREATE INDEX idx_silver_match     ON silver.event_enriched(match_id);
CREATE INDEX idx_silver_player    ON silver.event_enriched(player_id);
CREATE INDEX idx_silver_type      ON silver.event_enriched(event_name);
CREATE INDEX idx_silver_comp      ON silver.event_enriched(competition_id);
CREATE INDEX idx_silver_zone      ON silver.event_enriched(zone_id);

-- Índice parcial: solo tiros (alimenta el modelo de xG)
CREATE INDEX idx_silver_shots ON silver.event_enriched(player_id, dist_to_goal_m, angle_to_goal_deg)
    WHERE event_name = 'Shot';

-- ============================================================
-- 2. VISTAS DE VALIDACIÓN
-- ============================================================

-- El conteo de filas debe coincidir con Bronze (3.251.294)
CREATE OR REPLACE VIEW silver.v_row_count AS
SELECT 
    (SELECT COUNT(*) FROM bronze.wyscout_events) AS bronze_events,
    (SELECT COUNT(*) FROM silver.event_enriched) AS silver_events;

-- Rangos de coordenadas: x_m debe ser 0-105, y_m debe ser 0-68
CREATE OR REPLACE VIEW silver.v_coordinate_ranges AS
SELECT
    MIN(x_m) AS min_x_m, MAX(x_m) AS max_x_m,
    MIN(y_m) AS min_y_m, MAX(y_m) AS max_y_m,
    MIN(dist_to_goal_m) AS min_dist, MAX(dist_to_goal_m) AS max_dist,
    MIN(angle_to_goal_deg) AS min_angle, MAX(angle_to_goal_deg) AS max_angle
FROM silver.event_enriched;

-- Estadísticas de tiro (sanity check para el modelo de xG)
CREATE OR REPLACE VIEW silver.v_shot_stats AS
SELECT
    COUNT(*) AS total_shots,
    COUNT(*) FILTER (WHERE is_goal) AS goals,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_goal) / COUNT(*), 2) AS goal_pct,
    ROUND(AVG(dist_to_goal_m)::numeric, 1) AS avg_dist_m,
    ROUND(AVG(angle_to_goal_deg)::numeric, 1) AS avg_angle_deg,
    COUNT(*) FILTER (WHERE is_head_body) AS headers,
    COUNT(*) FILTER (WHERE is_right_foot) AS right_foot,
    COUNT(*) FILTER (WHERE is_left_foot) AS left_foot,
    COUNT(*) FILTER (WHERE is_opportunity) AS opportunities,
    COUNT(*) FILTER (WHERE is_blocked) AS blocked,
    COUNT(*) FILTER (WHERE is_counterattack) AS counterattacks,
    COUNT(*) FILTER (where event_name = 'Free Kick' AND sub_event_name = 'Free kick shot') AS free_kicks,
    COUNT(*) FILTER (where event_name = 'Free Kick' AND sub_event_name = 'Penalty') AS penalties
FROM silver.event_enriched
where event_name = 'Shot';

-- Precisión de pase por tipo
CREATE OR REPLACE VIEW silver.v_pass_accuracy AS
SELECT
    sub_event_name,
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE is_accurate) AS accurate,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_accurate) / COUNT(*), 1) AS accuracy_pct,
    ROUND(AVG(pass_distance_m)::numeric, 1) AS avg_distance_m,
    COUNT(*) FILTER (WHERE is_progressive_pass) AS progressive
FROM silver.event_enriched
WHERE event_name = 'Pass'
GROUP BY sub_event_name
ORDER BY total DESC;

-- Datos del mapa de calor por zona (96 zonas)
CREATE OR REPLACE VIEW silver.v_zone_heatmap AS
SELECT
    zone_x, zone_y, zone_id,
    event_name,
    COUNT(*) AS events,
    COUNT(*) FILTER (WHERE is_goal) AS goals
FROM silver.event_enriched
WHERE player_id IS NOT NULL
GROUP BY zone_x, zone_y, zone_id, event_name
ORDER BY zone_x, zone_y;


-- Validación de consistencia (vista)
CREATE OR REPLACE VIEW silver.v_flag_consistency AS
SELECT
    COUNT(*) FILTER (WHERE is_accurate AND is_not_accurate) AS both_accurate_and_not,
    COUNT(*) FILTER (
        WHERE (is_left_foot::int + is_right_foot::int + is_head_body::int) > 1
    ) AS multiple_body_parts,
    COUNT(*) FILTER (
        WHERE (is_goal_low_center OR is_goal_low_right OR is_goal_center OR
               is_goal_center_left OR is_goal_low_left OR is_goal_center_right OR
               is_goal_high_center OR is_goal_high_left OR is_goal_high_right)
          AND event_name <> 'Shot'
    ) AS placement_tags_outside_shots,
    COUNT(*) FILTER (
        WHERE (is_yellow_card OR is_red_card OR is_second_yellow)
          AND event_name <> 'Foul'
    ) AS cards_outside_fouls
FROM silver.event_enriched;

-- Consistencia entre los id de evento
CREATE OR REPLACE VIEW silver.v_event_id_name_consistency AS
SELECT
    event_id,
    event_name,
    sub_event_id,
    sub_event_name,
    COUNT(*) AS n
FROM silver.event_enriched
GROUP BY event_id, event_name, sub_event_id, sub_event_name
ORDER BY n DESC;


-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT COUNT(*) AS rows
FROM silver.event_enriched where competition_id in (364, 795, 426, 524, 412);



WITH feat AS (
    SELECT player_id FROM silver.player_pass_stats
    UNION
    SELECT player_id FROM silver.player_action_stats
)
SELECT
    f.player_id,
    p.short_name,
    ps.total_passes_count,
    pa.total_events,
    EXISTS (SELECT 1 FROM silver.player_match_minutes m
            WHERE m.player_id = f.player_id) AS aparece_en_minutos_match
FROM feat f
LEFT JOIN silver.player_season_minutes sm ON sm.player_id = f.player_id
LEFT JOIN bronze.wyscout_players      p  ON p.wy_player_id = f.player_id
LEFT JOIN silver.player_pass_stats    ps ON ps.player_id  = f.player_id
LEFT JOIN silver.player_action_stats  pa ON pa.player_id  = f.player_id
WHERE sm.player_id IS NULL          -- en features, ausente del pivote
ORDER BY pa.total_events DESC NULLS LAST;
