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
DROP TABLE IF EXISTS bronze.transfermarkt_appearances CASCADE;
DROP TABLE IF EXISTS bronze.transfermarkt_valuations CASCADE;
DROP TABLE IF EXISTS bronze.transfermarkt_players CASCADE;
DROP TABLE IF EXISTS bronze.kaggle_fbref_player_season CASCADE;
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
-- 8. TRANSFERMARKT: Jugadores
-- ============================================================
CREATE TABLE bronze.transfermarkt_players (
    tm_player_id        INTEGER PRIMARY KEY,
    name                TEXT,
    pretty_name         TEXT,
    country_of_birth    TEXT,
    city_of_birth       TEXT,
    country_of_citizenship TEXT,
    date_of_birth       DATE,
    position            TEXT,
    sub_position        TEXT,
    foot                TEXT,
    height_in_cm        SMALLINT,
    current_club_id     INTEGER,
    current_club_name   TEXT,
    agent_name          TEXT,
    image_url           TEXT,
    url                 TEXT,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 9. TRANSFERMARKT: Valoraciones
-- ============================================================
CREATE TABLE bronze.transfermarkt_valuations (
    tm_player_id        INTEGER NOT NULL,
    valuation_date      DATE NOT NULL,
    market_value_eur    BIGINT,
    current_club_id     INTEGER,
    player_club_domestic_competition_id TEXT,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tm_player_id, valuation_date)
);

CREATE INDEX idx_tm_val_date ON bronze.transfermarkt_valuations(valuation_date);

-- ============================================================
-- 10. TRANSFERMARKT: Apariciones
-- ============================================================
CREATE TABLE bronze.transfermarkt_appearances (
    tm_player_id        INTEGER NOT NULL,
    game_id             INTEGER NOT NULL,
    competition_id      TEXT,
    date                DATE,
    player_club_id      INTEGER,
    player_current_club_id INTEGER,
    minutes_played      SMALLINT,
    goals               SMALLINT,
    assists             SMALLINT,
    yellow_cards        SMALLINT,
    red_cards           SMALLINT,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tm_player_id, game_id)
);

-- ============================================================
-- 11. KAGGLE FBREF: Estadísticas por jugador-temporada (21/22 + 22/23)
-- ============================================================
CREATE TABLE bronze.kaggle_fbref_player_season (
    player_name         TEXT NOT NULL,
    nation              TEXT,
    pos                 TEXT,
    squad               TEXT NOT NULL,
    comp                TEXT,
    age                 TEXT,
    born                SMALLINT,
    season              TEXT NOT NULL,
    minutes_90s         NUMERIC(6,2),
    matches_played      SMALLINT,
    starts              SMALLINT,
    minutes             INTEGER,
    stats               JSONB NOT NULL,
    source_file         TEXT NOT NULL,
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (player_name, squad, season)
);

CREATE INDEX idx_kaggle_season  ON bronze.kaggle_fbref_player_season(season);
CREATE INDEX idx_kaggle_minutes ON bronze.kaggle_fbref_player_season(minutes);

-- ============================================================
-- 12. CONTROL ETL: Registro de cargas
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

-- Pares temporales Kaggle (predicción t→t+1)
CREATE OR REPLACE VIEW bronze.v_kaggle_temporal_pairs AS
SELECT 
    t1.player_name,
    t1.squad AS squad_2122,
    t2.squad AS squad_2223,
    t1.comp AS comp_2122,
    t2.comp AS comp_2223,
    t1.minutes AS min_2122,
    t2.minutes AS min_2223,
    t1.pos
FROM bronze.kaggle_fbref_player_season t1
JOIN bronze.kaggle_fbref_player_season t2 
    ON t1.player_name = t2.player_name
WHERE t1.season = '2021-2022' 
  AND t2.season = '2022-2023'
  AND t1.minutes >= 900
  AND t2.minutes >= 900;

-- ============================================================
-- VERIFICACIÓN RÁPIDA
-- ============================================================
-- Ejecuta esto al final para confirmar que todo se creó:
SELECT schemaname, tablename 
FROM pg_tables 
WHERE schemaname = 'bronze'
ORDER BY tablename;

COMMENT ON SCHEMA bronze IS 
'Capa de datos crudos. Sin transformaciones. Fuentes: Wyscout (Pappalardo 2019), Transfermarkt (Kaggle), FBref CSVs (Kaggle).';
