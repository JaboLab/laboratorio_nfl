import math

import pytest

from labnfl.market import (
    american_to_decimal,
    clv,
    decimal_to_american,
    devig,
    edge_vs_market,
    expected_value,
    fair_cashout,
    implied_probability,
    overround,
)


@pytest.mark.parametrize(
    "american,decimal",
    [(-110, 1.909091), (150, 2.5), (-481, 1.207900), (110, 2.1), (100, 2.0), (-100, 2.0)],
)
def test_american_to_decimal(american, decimal):
    assert american_to_decimal(american) == pytest.approx(decimal, abs=1e-6)


@pytest.mark.parametrize("american", [-110, 150, -481, 685, -345])
def test_roundtrip(american):
    assert decimal_to_american(american_to_decimal(american)) == pytest.approx(american)


def test_implied():
    assert implied_probability(-110) == pytest.approx(0.523810, abs=1e-6)
    assert implied_probability(150) == pytest.approx(0.4)
    assert overround([implied_probability(-110)] * 2) == pytest.approx(1.047619, abs=1e-6)


@pytest.mark.parametrize("bad", [0, 50, -99.9, float("nan")])
def test_invalid_american(bad):
    with pytest.raises(ValueError):
        implied_probability(bad)


@pytest.mark.parametrize("method", ["proportional", "power", "shin"])
def test_devig_symmetric_is_half(method):
    p = devig([-110, -110], method=method)
    assert p == pytest.approx([0.5, 0.5], abs=1e-9)
    assert sum(p) == pytest.approx(1.0, abs=1e-9)


@pytest.mark.parametrize("method", ["proportional", "power", "shin"])
def test_devig_favorite(method):
    # Playdoit 18:29, NYJ @ KC: KC −527 / NYJ +421
    p_kc, p_nyj = devig([-527, 421], method=method)
    assert sum([p_kc, p_nyj]) == pytest.approx(1.0, abs=1e-9)
    assert 0.80 < p_kc < 0.85


def test_power_and_shin_shade_longshot_more_than_proportional():
    prop = devig([-527, 421], "proportional")[1]
    assert devig([-527, 421], "power")[1] < prop
    assert devig([-527, 421], "shin")[1] < prop


def test_devig_one_sided_is_not_found():
    with pytest.raises(ValueError, match="NO_ENCONTRADO"):
        devig([-270])


def test_unknown_method():
    with pytest.raises(ValueError):
        devig([-110, -110], method="magic")


def test_expected_value_and_edge():
    assert expected_value(0.5, -110) == pytest.approx(-0.045455, abs=1e-6)
    assert expected_value(0.55, -110) == pytest.approx(0.05, abs=1e-6)
    assert edge_vs_market(0.55, 0.53) == pytest.approx(0.02)


def test_edge_vs_m0_is_not_enough():
    # Favorito con M0 = 80.8% y precio tomado −481 (implícita 82.8%).
    # Una ventaja de 1.5 pts sobre M0 sigue siendo EV negativo (PRD sección 8).
    p_m0 = 0.808
    assert edge_vs_market(p_m0 + 0.015, p_m0) > 0
    assert expected_value(p_m0 + 0.015, -481) < 0


def test_clv():
    assert clv(-110, 0.5) == pytest.approx(-0.045455, abs=1e-6)
    assert clv(100, 0.52) == pytest.approx(0.04)


def test_fair_cashout_week9():
    # Caso de referencia: tres boletos con sus probabilidades sin margen por pata
    cob1 = fair_cashout(1436.61, [0.609, 0.808, 0.669])
    cob2 = fair_cashout(1205.88, [0.634, 0.714, 0.800])
    risk = fair_cashout(5981.63, [0.669, 0.675, 0.720, 0.724, 0.423])
    assert cob1 == pytest.approx(472.93, abs=0.01)
    assert cob2 == pytest.approx(436.70, abs=0.01)
    assert risk == pytest.approx(595.61, abs=0.01)
    assert 415.04 / cob1 == pytest.approx(0.878, abs=0.001)
    assert 457.98 / risk == pytest.approx(0.769, abs=0.001)


def test_fair_cashout_validation():
    with pytest.raises(ValueError):
        fair_cashout(100, [1.2])
    assert fair_cashout(100, []) == 100
    assert math.isclose(fair_cashout(0, [0.5]), 0)
