# Sistema de scouting de futbolistas basado en datos

Clasificación de estilos de juego y predicción de rentabilidad mediante aprendizaje automático.

Trabajo de Fin de Grado - Grado en Ciencia de Datos, Universitat de València.
Autor: Mario Herranz Martínez.

## Qué hace

El sistema combina dos piezas de aprendizaje automático sobre los datos de evento de la temporada 2017/18 de las cinco grandes ligas europeas:

1. **Motor de similitud por estilo de juego** (aprendizaje no supervisado): agrupa a los jugadores en arquetipos por bloque posicional (porteros, defensas, mediocampistas, delanteros) mediante PCA y K-Means, y permite recuperar, dado un jugador de referencia, los más parecidos en estilo a través de similitud del coseno.

2. **Predictor de revalorización de mercado** (aprendizaje supervisado): estima el cambio de valor de mercado de cada jugador a uno y dos años vista mediante modelos XGBoost entrenados por bloque posicional, con interpretabilidad SHAP.

La integración de ambas piezas convierte una lista de jugadores parecidos en una herramienta de scouting: dado un referente, devuelve perfiles de estilo análogo ordenados por revalorización esperada.

El sistema se construye sobre una arquitectura Medallion en PostgreSQL (Bronze → Silver → Gold).

## Estructura del repositorio

* `src/` - código fuente reutilizable. `etl/` para la carga de los datos crudos (`load_wyscout.py`) y `models/` con la lógica del motor de similitud (`similarity.py`) y el modelo de xG persistido (`.joblib`).
* `sql/` - esquemas de las capas de la base de datos: `schema_bronze.sql`, `schema_silver.sql` y `schema_gold.sql`.
* `notebooks/` - el pipeline analítico, ejecutable en orden. Cada notebook se publica ya ejecutado y acompañado de una exportación `.html` autocontenida que reproduce su salida (código, tablas y figuras) sin necesidad de un entorno:

  * `01_data_validation` - validación de los datos crudos.
  * `02_EDA_events` - análisis exploratorio de los eventos.
  * `03_xGModel` - modelo de goles esperados (XGBoost con calibración isotónica).
  * `04_Golden_layer` - construcción de la capa Gold de estadísticas por 90 minutos.
  * `Transfermarkt_market_value` - emparejamiento de jugadores con sus valores de mercado.
  * `05_player_style_clustering` - clustering de estilos y motor de similitud.
  * `06_value_prediction` - predicción de revalorización e integración de scouting.
* `models/clustering/` - artefactos entrenados del motor de similitud por estilo.
* `data/processed/` - el dataset abierto publicado por este proyecto (`scouting_dataset.csv`).
* `requirements.txt` - dependencias del proyecto.
* `.env.example` - plantilla de configuración de la conexión a PostgreSQL.
* `LICENSE` - licencia MIT.

## Datos

Este proyecto utiliza dos fuentes de datos públicas que **no se redistribuyen** en este repositorio. Deben descargarse de su fuente oficial y colocarse en `data/raw/`.

### Datos de evento (Wyscout / Pappalardo et al.)

Los datos de evento de partidos proceden de la colección pública de Pappalardo et al., recogidos y cedidos por Wyscout. Se descargan de figshare:

- **Paper:** Pappalardo, L., Cintia, P., Rossi, A. et al. *A public data set of spatio-temporal match events in soccer competitions.* Scientific Data 6, 236 (2019). https://doi.org/10.1038/s41597-019-0247-7
- **Dataset:** Pappalardo, L., Massucco, E. (2019). *Soccer match event dataset.* figshare Collection. https://doi.org/10.6084/m9.figshare.c.4415000.v5

Los soccer-logs fueron recogidos y proporcionados por Wyscout (https://wyscout.com).

### Valores de mercado (Transfermarkt vía Kaggle)

Los valores de mercado proceden del dataset abierto *Football Data from Transfermarkt* de David Cariboo en Kaggle:

- https://www.kaggle.com/datasets/davidcariboo/player-scores

## Reproducción

El repositorio publica los notebooks ya ejecutados, una exportación `.html` navegable de cada uno, el dataset abierto resultante y los artefactos entrenados, de modo que los resultados son auditables sin reconstruir el pipeline. La vía más rápida para inspeccionar el trabajo es abrir los `.html` de `notebooks/` en cualquier navegador.

Reconstruir el sistema completo desde cero requiere los datos crudos (que no se redistribuyen) y una base de datos PostgreSQL local.

### Requisitos previos

* PostgreSQL 15 o superior en local.
* Python 3.11.
* Una cuenta de Kaggle con el token de API configurado (`~/.kaggle/kaggle.json`), necesaria para la descarga automática del dataset de Transfermarkt.

### 1. Entorno de Python

    pip install -r requirements.txt

### 2. Base de datos y credenciales

    createdb football_scouting
    cp .env.example .env

Edita `.env` con las credenciales de tu PostgreSQL local (`PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`).

### 3. Datos crudos de Wyscout

Descarga el dataset de eventos de figshare (ver sección *Datos*) y coloca los JSON en `data/raw/wyscout/` con la estructura que espera el cargador: `competitions.json`, `teams.json`, `players.json`, `referees.json`, `coaches.json`, `matches/matches_{comp}.json` y `events/events_{comp}.json`. El dataset de Transfermarkt no se descarga a mano: lo baja el notebook correspondiente con `kagglehub`.

### 4. Capa Bronze

    psql -d football_scouting -f sql/schema_bronze.sql
    python src/etl/load_wyscout.py --data-dir data/raw/wyscout

El cargador es idempotente y registra cada ejecución en `bronze.etl_load_log`. Al terminar imprime un informe que valida los conteos de eventos contra Pappalardo et al. (2019).

### 5. Capa Silver

    psql -d football_scouting -f sql/schema_silver.sql

Construye `silver.event_enriched` por transformación de Bronze. Las tablas agregadas de Silver (minutos, pases, acciones y xG por jugador) se construyen más adelante, dentro del notebook de la capa Gold.

### 6. Capa Gold (esquema)

    psql -d football_scouting -f sql/schema_gold.sql

Crea los esquemas de las tablas Gold. Su contenido lo generan los notebooks: `04_Golden_layer` puebla `gold.player_stats_per90` y `Transfermarkt_market_value` puebla `gold.player_market_values`.

### 7. Pipeline analítico

Ejecuta los notebooks en este orden:

1. `01_data_validation` - valida Bronze y Silver.
2. `02_EDA_events` - análisis exploratorio.
3. `03_xGModel` - entrena el modelo de goles esperados y lo persiste en `src/models/xg_model_v1.joblib` (ya incluido).
4. `04_Golden_layer` - construye las tablas agregadas de Silver, puntúa los tiros con el modelo xG y puebla `gold.player_stats_per90`.
5. `Transfermarkt_market_value` - descarga los valores de Kaggle, los empareja con el universo y puebla `gold.player_market_values`.
6. `05_player_style_clustering` - clustering de estilos y motor de similitud; persiste los artefactos en `models/clustering/`.
7. `06_value_prediction` - predictor de revalorización e integración de scouting; genera `data/processed/scouting_dataset.csv`.

## Tecnologías

Python 3.11, PostgreSQL, pandas, scikit-learn, XGBoost, SHAP, SQLAlchemy, RapidFuzz, mplsoccer.