"""M0 — conversión de momios, probabilidad sin margen, valor esperado, CLV y valor justo.

Definiciones: PRD v1.0, sección 6.2. Toda probabilidad es una fracción en [0, 1];
el formato "% con un decimal" es solo de presentación.
"""
from __future__ import annotations

import math
from collections.abc import Iterable, Sequence

__all__ = [
    "american_to_decimal",
    "clv",
    "decimal_to_american",
    "devig",
    "devig_power",
    "devig_proportional",
    "devig_shin",
    "edge_vs_market",
    "expected_value",
    "fair_cashout",
    "implied_probability",
    "overround",
]


def _check_american(american: float) -> None:
    if not isinstance(american, (int, float)) or math.isnan(american):
        raise ValueError(f"Momio inválido: {american!r}")
    if -100 < american < 100:
        raise ValueError(f"Un momio americano debe ser <= -100 o >= +100: {american}")


def american_to_decimal(american: float) -> float:
    """−110 → 1.9091 · +150 → 2.5."""
    _check_american(american)
    if american > 0:
        return 1.0 + american / 100.0
    return 1.0 + 100.0 / abs(american)


def decimal_to_american(decimal: float) -> float:
    if decimal <= 1.0:
        raise ValueError(f"Momio decimal inválido: {decimal}")
    if decimal >= 2.0:
        return (decimal - 1.0) * 100.0
    return -100.0 / (decimal - 1.0)


def implied_probability(american: float) -> float:
    """Probabilidad implícita con margen: |m|/(|m|+100) si m<0; 100/(m+100) si m>0."""
    _check_american(american)
    if american < 0:
        return abs(american) / (abs(american) + 100.0)
    return 100.0 / (american + 100.0)


def overround(implied: Iterable[float]) -> float:
    """Suma de implícitas (1.0476 en un −110/−110)."""
    return float(sum(implied))


def _validate_book(implied: Sequence[float]) -> None:
    if len(implied) < 2:
        raise ValueError("Se necesitan al menos dos lados para quitar el margen (PRD 6.2: un solo lado = NO_ENCONTRADO)")
    if any(not 0 < q < 1 for q in implied):
        raise ValueError(f"Implícitas fuera de (0, 1): {implied}")


def devig_proportional(implied: Sequence[float]) -> list[float]:
    """Método por defecto: cada implícita entre la suma."""
    _validate_book(implied)
    s = sum(implied)
    return [q / s for q in implied]


def _bisect(f, lo: float, hi: float, tol: float = 1e-12, max_iter: int = 200) -> float:
    flo = f(lo)
    for _ in range(max_iter):
        mid = (lo + hi) / 2.0
        fmid = f(mid)
        if abs(fmid) < tol or (hi - lo) < tol:
            return mid
        if (fmid > 0) == (flo > 0):
            lo, flo = mid, fmid
        else:
            hi = mid
    return (lo + hi) / 2.0


def devig_power(implied: Sequence[float]) -> list[float]:
    """Método de potencia: p_i = q_i^k con k tal que Σ p_i = 1 (sensibilidad)."""
    _validate_book(implied)
    if abs(sum(implied) - 1.0) < 1e-12:
        return list(implied)
    k = _bisect(lambda k: sum(q**k for q in implied) - 1.0, 1e-6, 50.0)
    return [q**k for q in implied]


def devig_shin(implied: Sequence[float]) -> list[float]:
    """Método de Shin (Jullien–Salanié) con z ∈ [0, 0.5) tal que Σ p_i = 1 (sensibilidad)."""
    _validate_book(implied)
    s = sum(implied)
    if s <= 1.0:
        return devig_proportional(implied)

    def probs(z: float) -> list[float]:
        return [
            (math.sqrt(z * z + 4.0 * (1.0 - z) * q * q / s) - z) / (2.0 * (1.0 - z))
            for q in implied
        ]

    z = _bisect(lambda z: sum(probs(z)) - 1.0, 0.0, 0.499999)
    return probs(z)


_METHODS = {"proportional": devig_proportional, "power": devig_power, "shin": devig_shin}


def devig(prices_american: Sequence[float], method: str = "proportional") -> list[float]:
    """Probabilidades sin margen a partir de los momios americanos de todos los lados del mercado."""
    try:
        fn = _METHODS[method]
    except KeyError as exc:
        raise ValueError(f"Método desconocido: {method}. Usa {sorted(_METHODS)}") from exc
    return fn([implied_probability(m) for m in prices_american])


def expected_value(p_model: float, price_american_taken: float) -> float:
    """EV por unidad apostada = p_modelo × momio_decimal_tomado − 1."""
    _check_prob(p_model)
    return p_model * american_to_decimal(price_american_taken) - 1.0


def edge_vs_market(p_model: float, p_m0: float) -> float:
    """Ventaja contra el mercado, en fracción (0.02 = 2 puntos porcentuales)."""
    _check_prob(p_model)
    _check_prob(p_m0)
    return p_model - p_m0


def clv(price_american_taken: float, p_close_fair: float) -> float:
    """CLV = momio_decimal_tomado / (1 / p_cierre_sin_margen) − 1."""
    _check_prob(p_close_fair)
    return american_to_decimal(price_american_taken) * p_close_fair - 1.0


def fair_cashout(potential_payout: float, p_pending: Iterable[float]) -> float:
    """Pago potencial × probabilidad sin margen de que ganen todas las patas pendientes.

    Supone independencia entre patas; para patas del mismo partido usar el simulador conjunto.
    """
    if potential_payout < 0:
        raise ValueError("El pago potencial no puede ser negativo")
    ps = list(p_pending)
    for p in ps:
        _check_prob(p)
    return potential_payout * math.prod(ps)


def _check_prob(p: float) -> None:
    if not 0.0 <= p <= 1.0:
        raise ValueError(f"Probabilidad fuera de [0, 1]: {p}")
