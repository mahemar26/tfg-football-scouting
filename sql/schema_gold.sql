-- ============================================================================
-- CAPA GOLD — Esquema analítico del sistema de scouting
-- ============================================================================
-- Arquitectura Medallion: Bronze -> Silver -> GOLD
--
-- La capa Gold materializa la tabla analítica final del proyecto, con grano
-- de jugador-temporada (una fila por jugador). Se nutre de las tablas Silver
-- derivadas de los eventos de Wyscout 2017/18.
--
-- Contiene dos tablas:
--   1. gold.player_stats_per90    — vector de estilo de juego (58 features)
--   2. gold.player_market_values  — valores de mercado contemporáneos
--
-- NOTA: este archivo documenta el contrato de la capa Gold. La tabla
-- player_stats_per90 se crea con este DDL explícito en el notebook 04;
-- player_market_values se materializa desde pandas (to_sql) en el notebook
-- Transfermarkt_market_value — el CREATE TABLE de más abajo es su esquema
-- equivalente, reconstruido para documentación y reproducibilidad.
-- ============================================================================


CREATE SCHEMA IF NOT EXISTS gold;


-- ============================================================================
-- gold.player_stats_per90
-- ----------------------------------------------------------------------------
-- Núcleo analítico del sistema. Una fila por jugador con 58 features de estilo
-- normalizadas por 90 minutos, más identidad y metadata. Alimenta el clustering
-- posicional y el motor de similitud (notebook 05).
--
-- Imputación: los counts de acciones inexistentes se fijan a 0 (cero real);
-- los ratios y promedios indefinidos (denominador 0) se preservan como NULL,
-- difiriendo su imputación a la fase de clustering por grupo posicional.
-- ============================================================================

DROP TABLE IF EXISTS gold.player_stats_per90;

CREATE TABLE gold.player_stats_per90 (
    -- Identidad
    player_id                     INTEGER PRIMARY KEY,

    -- Metadata
    short_name                    TEXT    NOT NULL,
    position_group                TEXT    NOT NULL CHECK (position_group IN ('MD','DF','FW','GK')),
    age_at_season                 NUMERIC          CHECK (age_at_season IS NULL OR age_at_season BETWEEN 15 AND 45),
    total_minutes_played          INTEGER NOT NULL CHECK (total_minutes_played > 0),
    matches_started               INTEGER NOT NULL CHECK (matches_started >= 0),
    main_competition_id           INTEGER NOT NULL,
    meets_450min                  BOOLEAN NOT NULL,
    meets_900min                  BOOLEAN NOT NULL,

    -- Pase: volumen, composición de estilo y precisión
    total_passes_per90            NUMERIC NOT NULL CHECK (total_passes_per90 >= 0),
    simple_passes_pct             NUMERIC          CHECK (simple_passes_pct    BETWEEN 0 AND 1),
    high_passes_pct               NUMERIC          CHECK (high_passes_pct       BETWEEN 0 AND 1),
    head_passes_pct               NUMERIC          CHECK (head_passes_pct       BETWEEN 0 AND 1),
    crosses_passes_pct            NUMERIC          CHECK (crosses_passes_pct    BETWEEN 0 AND 1),
    launches_passes_pct           NUMERIC          CHECK (launches_passes_pct   BETWEEN 0 AND 1),
    smart_passes_pct              NUMERIC          CHECK (smart_passes_pct      BETWEEN 0 AND 1),
    pass_acc_pct                  NUMERIC          CHECK (pass_acc_pct          BETWEEN 0 AND 1),
    crosses_acc_pct               NUMERIC          CHECK (crosses_acc_pct       BETWEEN 0 AND 1),
    smart_pass_acc_pct            NUMERIC          CHECK (smart_pass_acc_pct    BETWEEN 0 AND 1),
    key_passes_per90              NUMERIC NOT NULL CHECK (key_passes_per90 >= 0),
    assists_per90                 NUMERIC NOT NULL CHECK (assists_per90 >= 0),
    progressive_passes_per90      NUMERIC NOT NULL CHECK (progressive_passes_per90 >= 0),
    progressive_pass_dist_per90_m NUMERIC NOT NULL CHECK (progressive_pass_dist_per90_m >= 0),
    avg_pass_distance_m           NUMERIC          CHECK (avg_pass_distance_m IS NULL OR avg_pass_distance_m >= 0),

    -- Acción · tiro
    shots_per90                   NUMERIC NOT NULL CHECK (shots_per90 >= 0),
    goals_per90                   NUMERIC NOT NULL CHECK (goals_per90 >= 0),
    shots_on_target_per90         NUMERIC NOT NULL CHECK (shots_on_target_per90 >= 0),
    shots_blocked_per90           NUMERIC NOT NULL CHECK (shots_blocked_per90 >= 0),
    shots_avg_dist_m              NUMERIC          CHECK (shots_avg_dist_m IS NULL OR shots_avg_dist_m >= 0),
    shots_left_foot_pct           NUMERIC          CHECK (shots_left_foot_pct  BETWEEN 0 AND 1),
    shots_right_foot_pct          NUMERIC          CHECK (shots_right_foot_pct BETWEEN 0 AND 1),
    shots_head_pct                NUMERIC          CHECK (shots_head_pct       BETWEEN 0 AND 1),

    -- Acción · duelos
    attacking_duels_per90         NUMERIC NOT NULL CHECK (attacking_duels_per90 >= 0),
    attacking_duels_won_pct       NUMERIC          CHECK (attacking_duels_won_pct   BETWEEN 0 AND 1),
    defending_duels_per90         NUMERIC NOT NULL CHECK (defending_duels_per90 >= 0),
    defending_duels_won_pct       NUMERIC          CHECK (defending_duels_won_pct   BETWEEN 0 AND 1),
    air_duels_per90               NUMERIC NOT NULL CHECK (air_duels_per90 >= 0),
    air_duels_won_pct             NUMERIC          CHECK (air_duels_won_pct         BETWEEN 0 AND 1),
    loose_ball_duels_per90        NUMERIC NOT NULL CHECK (loose_ball_duels_per90 >= 0),
    loose_ball_duels_won_pct      NUMERIC          CHECK (loose_ball_duels_won_pct  BETWEEN 0 AND 1),

    -- Acción · defensa
    interceptions_per90           NUMERIC NOT NULL CHECK (interceptions_per90 >= 0),
    clearances_per90              NUMERIC NOT NULL CHECK (clearances_per90 >= 0),
    sliding_tackles_per90         NUMERIC NOT NULL CHECK (sliding_tackles_per90 >= 0),
    sliding_tackles_won_pct       NUMERIC          CHECK (sliding_tackles_won_pct   BETWEEN 0 AND 1),

    -- Acción · posesión y conducción
    touches_per90                 NUMERIC NOT NULL CHECK (touches_per90 >= 0),
    accelerations_per90           NUMERIC NOT NULL CHECK (accelerations_per90 >= 0),
    avg_action_x_m                NUMERIC,
    avg_action_y_m                NUMERIC,
    actions_attacking_third_pct   NUMERIC          CHECK (actions_attacking_third_pct BETWEEN 0 AND 1),
    actions_defensive_third_pct   NUMERIC          CHECK (actions_defensive_third_pct BETWEEN 0 AND 1),
    counterattack_actions_per90   NUMERIC NOT NULL CHECK (counterattack_actions_per90 >= 0),
    dangerous_ball_losses_per90   NUMERIC NOT NULL CHECK (dangerous_ball_losses_per90 >= 0),

    -- Acción · balón parado
    corners_taken_per90           NUMERIC NOT NULL CHECK (corners_taken_per90 >= 0),
    throw_ins_taken_per90         NUMERIC NOT NULL CHECK (throw_ins_taken_per90 >= 0),
    free_kicks_indirect_per90     NUMERIC NOT NULL CHECK (free_kicks_indirect_per90 >= 0),
    goal_kicks_per90              NUMERIC NOT NULL CHECK (goal_kicks_per90 >= 0),
    penalties_taken_per90         NUMERIC NOT NULL CHECK (penalties_taken_per90 >= 0),

    -- Acción · disciplina
    fouls_committed_per90         NUMERIC NOT NULL CHECK (fouls_committed_per90 >= 0),
    yellow_cards_per90            NUMERIC NOT NULL CHECK (yellow_cards_per90 >= 0),
    red_cards_per90               NUMERIC NOT NULL CHECK (red_cards_per90 >= 0),

    -- Acción · portero
    saves_per90                   NUMERIC NOT NULL CHECK (saves_per90 >= 0),
    reflexes_per90                NUMERIC NOT NULL CHECK (reflexes_per90 >= 0),
    gk_leaving_line_per90         NUMERIC NOT NULL CHECK (gk_leaving_line_per90 >= 0),
    hand_passes_per90             NUMERIC NOT NULL CHECK (hand_passes_per90 >= 0),

    -- xG (cobertura parcial)
    xg_per90                      NUMERIC NOT NULL CHECK (xg_per90 >= 0),
    xg_per_shot                   NUMERIC          CHECK (xg_per_shot IS NULL OR xg_per_shot >= 0),
    goals_minus_xg                NUMERIC NOT NULL
);


-- ============================================================================
-- gold.player_market_values
-- ----------------------------------------------------------------------------
-- Valores de mercado contemporáneos (Transfermarkt), emparejados con el
-- universo Wyscout por fecha de nacimiento en pasadas de matching difuso.
-- Corte temporal: valoración más reciente <= 2018-06-30 (techo honesto del CSV).
--
-- En el pipeline se materializa desde pandas con to_sql(if_exists='replace')
-- en el notebook Transfermarkt_market_value; este CREATE TABLE es su esquema
-- equivalente, para documentación y reproducibilidad.
-- ============================================================================

DROP TABLE IF EXISTS gold.player_market_values;

CREATE TABLE gold.player_market_values (
    player_id          INTEGER NOT NULL,   -- ID interno (universo Wyscout/Gold)
    tm_id              INTEGER,            -- ID de Transfermarkt (clave hacia el CSV de valoraciones)
    market_value_eur   BIGINT  NOT NULL,   -- valor de mercado en euros
    valuation_date     DATE    NOT NULL,   -- fecha de la valoración (<= 2018-06-30)
    match_level        TEXT,               -- nivel de emparejamiento (exacto, difuso, difuso_recup, difuso_recup2)
    match_score        NUMERIC             -- score del matching difuso
);
