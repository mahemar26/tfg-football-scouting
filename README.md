# Sistema de scouting de futbolistas basado en datos

Clasificación de estilos de juego y predicción de rendimiento mediante aprendizaje automático.

Trabajo de Fin de Grado — Grado en Ciencia de Datos, Universitat de València.
Autor: Mario Herranz Martínez.

## Qué hace

El sistema combina dos piezas de aprendizaje automático sobre los datos de evento de la temporada 2017/18 de las cinco grandes ligas europeas:

1. **Motor de similitud por estilo de juego** (aprendizaje no supervisado): agrupa a los jugadores en arquetipos por bloque posicional (porteros, defensas, mediocampistas, delanteros) mediante PCA y K-Means, y permite recuperar, dado un jugador de referencia, los más parecidos en estilo a través de similitud del coseno.

2. **Predictor de revalorización de mercado** (aprendizaje supervisado): estima el cambio de valor de mercado de cada jugador a uno y dos años vista mediante modelos XGBoost entrenados por bloque posicional, con interpretabilidad SHAP.

La integración de ambas piezas convierte una lista de jugadores parecidos en una herramienta de scouting: dado un referente, devuelve perfiles de estilo análogo ordenados por revalorización esperada.

El sistema se construye sobre una arquitectura Medallion en PostgreSQL (Bronze → Silver → Gold).

## Estructura del repositorio

- `src/` — código fuente reutilizable. `etl/` para la carga de los datos crudos, `features/` para la ingeniería de variables, `models/` con la lógica del motor de similitud (`similarity.py`) y el modelo de xG persistido, `utils/` para utilidades comunes.
- `sql/` — esquemas de las capas de la base de datos (`schema_bronze.sql`, `schema_silver.sql`).
- `notebooks/` — el pipeline analítico, ejecutable en orden:
  - `01_data_validation` — validación de los datos crudos.
  - `02_EDA_events` — análisis exploratorio de los eventos.
  - `03_xGModel` — modelo de goles esperados (XGBoost con calibración isotónica).
  - `04_Golden_layer` — construcción de la capa Gold de estadísticas por 90 minutos.
  - `Transfermarkt_market_value` — emparejamiento de jugadores con sus valores de mercado.
  - `05_player_style_clustering` — clustering de estilos y motor de similitud.
  - `06_value_prediction` — predicción de revalorización e integración de scouting.
- `models/` — artefactos entrenados (motor de similitud).
- `data/processed/` — el dataset abierto publicado por este proyecto.
- `tests/` — pruebas.

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

El repositorio publica los notebooks ya ejecutados (con su salida visible), el dataset abierto resultante y los artefactos entrenados, de modo que los resultados son auditables sin necesidad de reconstruir el pipeline.

Para reconstruir el sistema completo desde cero es necesario disponer de los datos crudos (que no se redistribuyen) y de una base de datos PostgreSQL local. Los pasos son:

1. Crear un entorno con las dependencias del proyecto.
2. Descargar los datos de las fuentes oficiales indicadas arriba y colocarlos en `data/raw/`.
3. Copiar `.env.example` a `.env` y rellenarlo con las credenciales de tu PostgreSQL local.
4. Ejecutar los esquemas SQL de `sql/` para crear las capas Bronze y Silver.
5. Ejecutar los notebooks en el orden numerado.

## Tecnologías

Python 3.11, PostgreSQL, pandas, scikit-learn, XGBoost, SHAP, SQLAlchemy, RapidFuzz, mplsoccer.
