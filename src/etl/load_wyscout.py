"""
load_wyscout.py — Load Wyscout JSON dataset into Bronze schema (PostgreSQL)
===========================================================================
TFG: Sistema de scouting de futbolistas basado en datos
Author: Mario Herranz Martínez
Date: 2026-03-22

Usage:
    python src/etl/load_wyscout.py --data-dir data/raw/wyscout

Expects the following JSON files in data-dir:
    competitions.json, teams.json, players.json, matches/matches_{comp}.json,
    events/events_{comp}.json, referees.json, coaches.json

Idempotent: uses INSERT ... ON CONFLICT DO NOTHING.
Logs each run to bronze.etl_load_log.
"""

import json
import os
import time
import logging
import unicodedata
import re
from pathlib import Path
from datetime import datetime, timezone
from typing import Any

import click
import psycopg2
from psycopg2.extras import execute_values, Json
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ----------------------------------------------------------------
# DB connection
# ----------------------------------------------------------------

def clean(val, typ="str"):
    if val is None or val == "null" or val == "":
        return None
    if typ == "int":
        try:
            return int(val)
        except (ValueError, TypeError):
            return None
    if isinstance(val, str):
        # Decodifica secuencias Unicode escapadas literales (\u00e9 → é)
        if "\\u" in val:
            val = re.sub(
                r'\\u([0-9a-fA-F]{4})',
                lambda m: chr(int(m.group(1), 16)),
                val,
            )
        val = unicodedata.normalize("NFKC", val)
        val = "".join(ch for ch in val if unicodedata.category(ch)[0] != "C")
        val = val.strip()
        return val if val else None
    return val

def build_complete_name(first: str | None, middle: str | None, last: str | None) -> str | None:
    """Construye nombre completo normalizado en minúsculas."""
    parts = [p.strip() for p in (first, middle, last) if p and p.strip()]
    if not parts:
        return None
    return " ".join(parts).lower()

def get_conn():
    return psycopg2.connect(
        host=os.getenv("PG_HOST", "localhost"),
        port=os.getenv("PG_PORT", "5432"),
        dbname=os.getenv("PG_DB", "football_scouting"),
        user=os.getenv("PG_USER", "postgres"),
        password=os.getenv("PG_PASSWORD", ""),
    )


# ----------------------------------------------------------------
# ETL logging helper
# ----------------------------------------------------------------
def log_etl_start(cur, source: str, file_name: str) -> int:
    cur.execute(
        """INSERT INTO bronze.etl_load_log (source, file_name) 
           VALUES (%s, %s) RETURNING load_id""",
        (source, file_name),
    )
    return cur.fetchone()[0]


def log_etl_end(cur, load_id: int, records: int, skipped: int = 0, error: str = None):
    status = "failed" if error else "success"
    cur.execute(
        """UPDATE bronze.etl_load_log 
           SET finished_at = now(), records_loaded = %s, records_skipped = %s,
               status = %s, error_message = %s
           WHERE load_id = %s""",
        (records, skipped, status, error, load_id),
    )


# ----------------------------------------------------------------
# Loaders
# ----------------------------------------------------------------
def load_json(filepath: Path) -> list[dict]:
    """Load a JSON file, handling both list and dict-of-dicts formats."""
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        # Some Wyscout files are {id: {...}, id: {...}}
        return list(data.values()) if all(isinstance(v, dict) for v in data.values()) else [data]
    return data


def parse_date(val: Any) -> str | None:
    """Try to parse a date string, return None on failure."""
    if not val:
        return None
    if isinstance(val, str):
        # Handle "1990-05-24" or "1990-05-24T00:00:00"
        return val[:10] if len(val) >= 10 else None
    return None


def load_competitions(cur, data_dir: Path) -> int:
    fp = data_dir / "competitions.json"
    if not fp.exists():
        log.warning(f"File not found: {fp}")
        return 0
    
    data = load_json(fp)
    load_id = log_etl_start(cur, "wyscout_competitions", fp.name)
    
    rows = []
    for c in data:
        rows.append((
            c["wyId"],
            c.get("name", ""),
            Json(c.get("area")),
            c.get("format", ""),
            c.get("type", ""),
            Json(c),
        ))
    
    sql = """
        INSERT INTO bronze.wyscout_competitions 
            (wy_competition_id, name, area, format, type, raw_json)
        VALUES %s
        ON CONFLICT (wy_competition_id) DO NOTHING
    """
    execute_values(cur, sql, rows)
    loaded = len(rows)
    log_etl_end(cur, load_id, loaded)
    log.info(f"Competitions: {loaded} loaded")
    return loaded


def load_teams(cur, data_dir: Path) -> int:
    fp = data_dir / "teams.json"
    if not fp.exists():
        log.warning(f"File not found: {fp}")
        return 0
    
    data = load_json(fp)
    load_id = log_etl_start(cur, "wyscout_teams", fp.name)
    
    rows = []
    for t in data:
        rows.append((
            t["wyId"],
            clean(t.get("name", "")),
            clean(t.get("officialName", "")),
            Json(t.get("area")),
            t.get("type", ""),
            Json(t),
        ))
    
    sql = """
        INSERT INTO bronze.wyscout_teams 
            (wy_team_id, name, official_name, area, type, raw_json)
        VALUES %s
        ON CONFLICT (wy_team_id) DO NOTHING
    """
    execute_values(cur, sql, rows)
    loaded = len(rows)
    log_etl_end(cur, load_id, loaded)
    log.info(f"Teams: {loaded} loaded")
    return loaded


def load_players(cur, data_dir: Path) -> int:
    fp = data_dir / "players.json"
    if not fp.exists():
        log.warning(f"File not found: {fp}")
        return 0
    
    data = load_json(fp)
    load_id = log_etl_start(cur, "wyscout_players", fp.name)
    
    rows = []
    for p in data:
        first = clean(p.get("firstName"))
        middle = clean(p.get("middleName"))
        last = clean(p.get("lastName"))
        complete = build_complete_name(first, middle, last)
        
        rows.append((
            p["wyId"],
            clean(p.get("shortName")),
            first,
            last,
            middle,
            parse_date(p.get("birthDate")),
            Json(p.get("birthArea")),
            Json(p.get("passportArea")),
            clean(p.get("foot")),
            clean(p.get("height"), "int"),
            clean(p.get("weight"), "int"),
            Json(p.get("role")),
            clean(p.get("currentTeamId"), "int"),
            clean(p.get("currentNationalTeamId"), "int"),
            complete,
            Json(p),
        ))
    
    sql = """
        INSERT INTO bronze.wyscout_players 
            (wy_player_id, short_name, first_name, last_name, middle_name,
             birth_date, birth_area, passport_area, foot, height, weight,
             role, current_team_id, current_national_team_id, complete_name, raw_json)
        VALUES %s
        ON CONFLICT (wy_player_id) DO UPDATE SET
            short_name = EXCLUDED.short_name,
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            middle_name = EXCLUDED.middle_name,
            complete_name = EXCLUDED.complete_name
    """
    execute_values(cur, sql, rows, page_size=500)
    loaded = len(rows)
    log_etl_end(cur, load_id, loaded)
    log.info(f"Players: {loaded} loaded")
    return loaded


def load_matches(cur, data_dir: Path) -> int:
    """Load matches from individual files per competition or single file."""
    matches_dir = data_dir / "matches"
    total = 0
    
    if matches_dir.is_dir():
        # Format: matches/matches_{comp_id}.json
        for fp in sorted(matches_dir.glob("*.json")):
            total += _load_matches_file(cur, fp)
    else:
        # Single matches.json
        fp = data_dir / "matches.json"
        if fp.exists():
            total += _load_matches_file(cur, fp)
    
    return total


def _load_matches_file(cur, fp: Path) -> int:
    data = load_json(fp)
    load_id = log_etl_start(cur, "wyscout_matches", fp.name)
    
    rows = []
    for m in data:
        # Extract team IDs from teamsData
        teams_data = m.get("teamsData", {})
        team_ids = list(teams_data.keys())
        home_id = away_id = home_score = away_score = None
        home_lineup = away_lineup = None
        
        for tid, tdata in teams_data.items():
            side = tdata.get("side", "")
            if side == "home":
                home_id = int(tid)
                home_score = tdata.get("score")
                home_lineup = tdata.get("formation", {})
            elif side == "away":
                away_id = int(tid)
                away_score = tdata.get("score")
                away_lineup = tdata.get("formation", {})
        
        rows.append((
            m["wyId"],
            m.get("competitionId"),
            m.get("seasonId"),
            m.get("roundId"),
            m.get("gameweek"),
            m.get("dateutc"),
            m.get("status"),
            m.get("duration"),
            home_id,
            away_id,
            home_score,
            away_score,
            m.get("venue"),
            m.get("refereeId"),
            Json(home_lineup) if home_lineup else None,
            Json(away_lineup) if away_lineup else None,
            Json(m),
        ))
    
    sql = """
        INSERT INTO bronze.wyscout_matches 
            (wy_match_id, competition_id, season_id, round_id, gameweek,
             date_utc, status, duration, home_team_id, away_team_id,
             home_score, away_score, venue, referee_id,
             home_lineup, away_lineup, raw_json)
        VALUES %s
        ON CONFLICT (wy_match_id) DO NOTHING
    """
    execute_values(cur, sql, rows, page_size=200)
    loaded = len(rows)
    log_etl_end(cur, load_id, loaded)
    log.info(f"Matches from {fp.name}: {loaded} loaded")
    return loaded


def load_events(cur, data_dir: Path) -> int:
    """Load events — the core table. ~3.2M rows across all competitions.
    
    Events are loaded per-competition file to manage memory and allow
    progress tracking.
    """
    events_dir = data_dir / "events"
    total = 0
    
    if events_dir.is_dir():
        for fp in sorted(events_dir.glob("*.json")):
            total += _load_events_file(cur, fp)
    else:
        fp = data_dir / "events.json"
        if fp.exists():
            total += _load_events_file(cur, fp)
    
    return total


def _load_events_file(cur, fp: Path) -> int:
    """Load a single events JSON file. Processes in batches of 10,000."""
    log.info(f"Loading events from {fp.name}...")
    t0 = time.time()
    
    data = load_json(fp)
    load_id = log_etl_start(cur, "wyscout_events", fp.name)
    
    BATCH = 10_000
    total_loaded = 0
    batch_rows = []
    
    for ev in data:
        # Parse positions array
        positions = ev.get("positions", [])
        pos_orig_x = pos_orig_y = pos_dest_x = pos_dest_y = None
        if len(positions) >= 1:
            pos_orig_x = positions[0].get("x")
            pos_orig_y = positions[0].get("y")
        if len(positions) >= 2:
            pos_dest_x = positions[1].get("x")
            pos_dest_y = positions[1].get("y")
        
        # Parse tags: [{"id": 701}, {"id": 401}] → [701, 401]
        tags = [tag["id"] for tag in ev.get("tags", []) if "id" in tag]
        
        batch_rows.append((
            clean(ev.get("id"), "int"),
            clean(ev.get("matchId"), "int"),
            clean(ev.get("playerId"), "int"),
            clean(ev.get("teamId"), "int"),
            clean(ev.get("matchPeriod")),
            ev.get("eventSec"),
            clean(ev.get("eventId"), "int"),
            clean(ev.get("eventName")),
            clean(ev.get("subEventId"), "int"),
            clean(ev.get("subEventName")),
            clean(pos_orig_x, "int"),
            clean(pos_orig_y, "int"),
            clean(pos_dest_x, "int"),
            clean(pos_dest_y, "int"),
            tags,
            Json(ev),
        ))
        
        if len(batch_rows) >= BATCH:
            _insert_events_batch(cur, batch_rows)
            total_loaded += len(batch_rows)
            batch_rows = []
    
    # Final batch
    if batch_rows:
        _insert_events_batch(cur, batch_rows)
        total_loaded += len(batch_rows)
    
    elapsed = time.time() - t0
    log.info(f"Events from {fp.name}: {total_loaded} loaded in {elapsed:.1f}s")
    log_etl_end(cur, load_id, total_loaded)
    return total_loaded


def _insert_events_batch(cur, rows: list):
    sql = """
        INSERT INTO bronze.wyscout_events 
            (wy_event_id, match_id, player_id, team_id, match_period,
            event_sec, event_id, event_name, sub_event_id, sub_event_name,
            pos_orig_x, pos_orig_y, pos_dest_x, pos_dest_y,
            tags, raw_json)
        VALUES %s
        ON CONFLICT (wy_event_id) DO NOTHING
    """
    execute_values(cur, sql, rows, page_size=5000)


# ----------------------------------------------------------------
# Data quality checks (run after loading)
# ----------------------------------------------------------------
def run_quality_checks(cur) -> dict:
    """Run basic quality checks and return results."""
    checks = {}
    
    # 1. Total event counts by competition
    cur.execute("SELECT * FROM bronze.v_event_counts")
    checks["event_counts"] = cur.fetchall()
    
    # 2. Orphan events
    cur.execute("SELECT * FROM bronze.v_orphan_events")
    checks["orphans"] = cur.fetchall()
    
    # 3. Events with missing coordinates
    cur.execute("""
        SELECT event_name, 
               COUNT(*) AS total,
               SUM(CASE WHEN pos_orig_x IS NULL THEN 1 ELSE 0 END) AS null_coords,
               ROUND(100.0 * SUM(CASE WHEN pos_orig_x IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2) AS null_pct
        FROM bronze.wyscout_events
        GROUP BY event_name
        ORDER BY null_pct DESC
    """)
    checks["null_coords"] = cur.fetchall()
    
    # 4. Duplicate event IDs (should be 0)
    cur.execute("""
        SELECT COUNT(*) - COUNT(DISTINCT wy_event_id) AS duplicates
        FROM bronze.wyscout_events
    """)
    checks["duplicate_events"] = cur.fetchone()[0]
    
    # 5. Match count validation
    cur.execute("""
        SELECT c.name, COUNT(DISTINCT m.wy_match_id) AS matches
        FROM bronze.wyscout_matches m
        JOIN bronze.wyscout_competitions c ON m.competition_id = c.wy_competition_id
        GROUP BY c.name
        ORDER BY matches DESC
    """)
    checks["match_counts"] = cur.fetchall()
    
    return checks


def print_quality_report(checks: dict):
    """Print a human-readable quality report."""
    log.info("\n" + "=" * 60)
    log.info("DATA QUALITY REPORT — Bronze Layer")
    log.info("=" * 60)
    
    log.info("\n📊 Event counts by competition:")
    log.info(f"{'Competition':<30} {'Matches':>8} {'Events':>10} {'Players':>8}")
    log.info("-" * 60)
    for row in checks["event_counts"]:
        log.info(f"{row[0]:<30} {row[1]:>8} {row[2]:>10} {row[3]:>8}")
    
    log.info(f"\n🔍 Orphan events: {checks['orphans']}")
    log.info(f"🔍 Duplicate events: {checks['duplicate_events']}")
    
    log.info("\n📍 Null coordinates by event type:")
    for row in checks["null_coords"][:10]:
        log.info(f"  {row[0]:<25} total={row[1]:>8}  null_coords={row[2]:>6} ({row[3]}%)")
    
    # Expected values from Pappalardo et al. (2019) paper
    expected = {
        "Spain": (380, 628_659),
        "England": (380, 643_150),
        "Italy": (380, 647_372),
        "Germany": (306, 519_407),
        "France": (380, 632_807),
        "World Cup": (64, 101_759),
        "European Championship": (51, 78_140),
    }
    
    log.info("\n✅ Validation vs. Pappalardo et al. (2019):")
    for row in checks["match_counts"]:
        name = row[0]
        actual_matches = row[1]
        for key, (exp_matches, _) in expected.items():
            if key.lower() in name.lower():
                status = "✅" if actual_matches == exp_matches else "⚠️"
                log.info(f"  {status} {name}: {actual_matches} matches (expected {exp_matches})")
                break


# ----------------------------------------------------------------
# CLI
# ----------------------------------------------------------------
@click.command()
@click.option("--data-dir", type=click.Path(exists=True), required=True,
              help="Path to directory containing Wyscout JSON files")
@click.option("--skip-events", is_flag=True, default=False,
              help="Skip loading events (useful for testing schema)")
@click.option("--quality-only", is_flag=True, default=False,
              help="Only run quality checks (assume data already loaded)")
def main(data_dir: str, skip_events: bool, quality_only: bool):
    """Load Wyscout dataset from JSON files into PostgreSQL Bronze schema."""
    data_path = Path(data_dir)
    
    conn = get_conn()
    conn.autocommit = False
    cur = conn.cursor()
    
    try:
        if not quality_only:
            log.info(f"Loading Wyscout data from {data_path}")
            t0 = time.time()
            
            # Order matters due to foreign keys
            load_competitions(cur, data_path)
            conn.commit()
            
            load_teams(cur, data_path)
            conn.commit()
            
            load_players(cur, data_path)
            conn.commit()
            
            load_matches(cur, data_path)
            conn.commit()
            
            if not skip_events:
                load_events(cur, data_path)
                conn.commit()
            
            elapsed = time.time() - t0
            log.info(f"\nTotal load time: {elapsed:.1f}s")
        
        # Quality checks
        log.info("Running quality checks...")
        checks = run_quality_checks(cur)
        print_quality_report(checks)
        
    except Exception as e:
        conn.rollback()
        log.error(f"Error: {e}")
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    main()
