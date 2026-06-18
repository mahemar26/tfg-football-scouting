-- ============================================================
-- ESQUEMA BRONZE — Capa de persistencia de datos crudos
-- BD: football_scouting (PostgreSQL 15+)
-- ============================================================

-- Crear esquema bronze
CREATE SCHEMA IF NOT EXISTS bronze;

-- ============================================================
-- 1. WYSCOUT: Competiciones
-- ============================================================
DROP TABLE IF EXISTS bronze.wyscout_events CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_matches CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_coaches CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_referees CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_players CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_teams CASCADE;
DROP TABLE IF EXISTS bronze.wyscout_competitions CASCADE;
DROP TABLE IF EXISTS bronze.etl_load_log CASCADE;

CREATE TABLE bronze.wyscout_competitions (
    wy_competition_id   INTEGER PRIMARY KEY,
    name                TEXT NOT NULL,
    area                JSONB,
    format              TEXT,
    type                TEXT,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 2. WYSCOUT: Equipos
-- ============================================================
CREATE TABLE bronze.wyscout_teams (
    wy_team_id          INTEGER PRIMARY KEY,
    name                TEXT NOT NULL,
    official_name       TEXT,
    area                JSONB,
    type                TEXT,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 3. WYSCOUT: Jugadores
-- ============================================================
CREATE TABLE bronze.wyscout_players (
    wy_player_id        INTEGER PRIMARY KEY,
    short_name          TEXT,
    first_name          TEXT,
    last_name           TEXT,
    middle_name         TEXT,
    birth_date          DATE,
    birth_area          JSONB,
    passport_area       JSONB,
    foot                TEXT,
    height              SMALLINT,
    weight              SMALLINT,
    role                JSONB,
    current_team_id     INTEGER,
    current_national_team_id INTEGER,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 4. WYSCOUT: Árbitros
-- ============================================================
CREATE TABLE bronze.wyscout_referees (
    wy_referee_id       INTEGER PRIMARY KEY,
    short_name          TEXT,
    first_name          TEXT,
    last_name           TEXT,
    birth_date          DATE,
    birth_area          JSONB,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 5. WYSCOUT: Entrenadores
-- ============================================================
CREATE TABLE bronze.wyscout_coaches (
    wy_coach_id         INTEGER PRIMARY KEY,
    short_name          TEXT,
    first_name          TEXT,
    last_name           TEXT,
    birth_date          DATE,
    birth_area          JSONB,
    current_team_id     INTEGER,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 6. WYSCOUT: Partidos
-- ============================================================
CREATE TABLE bronze.wyscout_matches (
    wy_match_id         INTEGER PRIMARY KEY,
    competition_id      INTEGER NOT NULL REFERENCES bronze.wyscout_competitions(wy_competition_id),
    season_id           INTEGER,
    round_id            INTEGER,
    gameweek            SMALLINT,
    date_utc            TIMESTAMPTZ,
    status              TEXT,
    duration            TEXT,
    home_team_id        INTEGER REFERENCES bronze.wyscout_teams(wy_team_id),
    away_team_id        INTEGER REFERENCES bronze.wyscout_teams(wy_team_id),
    home_score          SMALLINT,
    away_score          SMALLINT,
    venue               TEXT,
    referee_id          INTEGER,
    home_lineup         JSONB,
    away_lineup         JSONB,
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_matches_competition ON bronze.wyscout_matches(competition_id);

-- ============================================================
-- 7. WYSCOUT: Eventos (TABLA PRINCIPAL — ~3.2M filas)
-- ============================================================
CREATE TABLE bronze.wyscout_events (
    wy_event_id         BIGINT PRIMARY KEY,
    match_id            INTEGER NOT NULL REFERENCES bronze.wyscout_matches(wy_match_id),
    player_id           INTEGER,
    team_id             INTEGER,
    match_period        TEXT NOT NULL,
    event_sec           NUMERIC(10,4),
    event_name          TEXT NOT NULL,
    event_id            INTEGER not null, 
    sub_event_id        INTEGER, 
    sub_event_name      TEXT,
    pos_orig_x          SMALLINT,
    pos_orig_y          SMALLINT,
    pos_dest_x          SMALLINT,
    pos_dest_y          SMALLINT,
    tags                INTEGER[],
    raw_json            JSONB NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_match     ON bronze.wyscout_events(match_id);
CREATE INDEX idx_events_player    ON bronze.wyscout_events(player_id);
CREATE INDEX idx_events_type      ON bronze.wyscout_events(event_name);
CREATE INDEX idx_events_match_sec ON bronze.wyscout_events(match_id, event_sec);
CREATE INDEX idx_events_shots     ON bronze.wyscout_events(match_id, player_id, event_sec) 
    WHERE event_name = 'Shot';


-- ============================================================
-- 8. CONTROL ETL: Registro de cargas
-- ============================================================
CREATE TABLE bronze.etl_load_log (
    load_id             SERIAL PRIMARY KEY,
    source              TEXT NOT NULL,
    file_name           TEXT,
    records_loaded      INTEGER,
    records_skipped     INTEGER DEFAULT 0,
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at         TIMESTAMPTZ,
    status              TEXT DEFAULT 'running',
    error_message       TEXT
);

-- ============================================================
-- VISTAS DE VALIDACIÓN
-- ============================================================

-- Conteo de eventos por competición (validar vs paper)
CREATE OR REPLACE VIEW bronze.v_event_counts AS
SELECT 
    c.name AS competition,
    COUNT(DISTINCT e.match_id) AS matches,
    COUNT(*) AS events,
    COUNT(DISTINCT e.player_id) AS players
FROM bronze.wyscout_events e
JOIN bronze.wyscout_matches m ON e.match_id = m.wy_match_id
JOIN bronze.wyscout_competitions c ON m.competition_id = c.wy_competition_id
GROUP BY c.name
ORDER BY events DESC;

-- Distribución de tipos de evento
CREATE OR REPLACE VIEW bronze.v_event_type_distribution AS
SELECT 
    event_name,
    sub_event_name,
    COUNT(*) AS count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS pct
FROM bronze.wyscout_events
GROUP BY event_name, sub_event_name
ORDER BY count DESC;

-- Eventos huérfanos (sin jugador o partido válido)
CREATE OR REPLACE VIEW bronze.v_orphan_events AS
SELECT 'missing_player' AS issue, COUNT(*) AS count
FROM bronze.wyscout_events e
LEFT JOIN bronze.wyscout_players p ON e.player_id = p.wy_player_id
WHERE e.player_id IS NOT NULL AND p.wy_player_id IS NULL
UNION ALL
SELECT 'missing_match', COUNT(*)
FROM bronze.wyscout_events e
LEFT JOIN bronze.wyscout_matches m ON e.match_id = m.wy_match_id
WHERE m.wy_match_id IS NULL;

-- ============================================================
-- VERIFICACIÓN RÁPIDA
-- ============================================================
-- Ejecuta esto al final para confirmar que todo se creó:
SELECT schemaname, tablename 
FROM pg_tables 
WHERE schemaname = 'bronze'
ORDER BY tablename;

COMMENT ON SCHEMA bronze IS 
'Capa de datos crudos de Wyscout (Pappalardo 2019). Sin transformaciones.';
