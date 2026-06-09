"""Motor de similitud de estilo entre jugadores.

Opera sobre el espacio de componentes principales por bloque posicional
generado en el notebook de clustering (05). La afinidad se mide por distancia
del coseno; los descriptores de calidad, la edad, la liga y el valor de mercado
intervienen solo como filtros posteriores, nunca en el cálculo de afinidad.
"""

import numpy as np
import pandas as pd
from sklearn.metrics.pairwise import cosine_similarity


def bloque_de(sim_index, nombre):
    """Devuelve el bloque posicional ('GK'/'DF'/'MD'/'FW') de un jugador, o None."""
    for b, data in sim_index.items():
        if nombre in data["pos"]:
            return b
    return None


def jugadores_similares(sim_index, nombre, descriptores=None, market_values=None,
                        desc_cols=("age_at_season", "goals_per90", "goals_minus_xg"),
                        top_n=10):
    """Recupera los jugadores más afines en estilo a `nombre`, dentro de su bloque.

    Parameters
    ----------
    sim_index : dict
        Índice de similitud por bloque: {b: {'X', 'meta', 'pos'}}.
    nombre : str
        short_name del jugador objetivo.
    descriptores : pd.DataFrame, opcional
        Tabla con 'player_id' + columnas de desc_cols, para perfilar candidatos.
    market_values : pd.DataFrame, opcional
        Tabla con 'player_id' y 'market_value_eur'.
    desc_cols : tuple
        Descriptores de calidad a anexar (no intervienen en la afinidad).
    top_n : int
        Número de candidatos a devolver.

    Returns
    -------
    pd.DataFrame con player_id, short_name, afinidad (%), archetype, liga,
    descriptores y valor de mercado en millones.
    """
    b = bloque_de(sim_index, nombre)
    if b is None:
        return None

    X, meta = sim_index[b]["X"], sim_index[b]["meta"]
    i = sim_index[b]["pos"][nombre]
    cos = cosine_similarity(X[i:i + 1], X)[0]

    res = meta.copy()
    res["afinidad"] = (cos * 100).round(1)
    res = res[res.index != i].sort_values("afinidad", ascending=False).head(top_n)

    if descriptores is not None:
        res = res.merge(descriptores[["player_id", *desc_cols]], on="player_id", how="left")
    if market_values is not None:
        res = res.merge(market_values, on="player_id", how="left")
        res["valor_M"] = (res["market_value_eur"] / 1e6).round(1)

    return res.reset_index(drop=True)