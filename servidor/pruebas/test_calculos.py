from datetime import date, datetime, timedelta

from servidor.app.calculos import avance, es_parecida, ritmo

# Los cuatro modelos de la maqueta: uno pasado de meta (1012/1000).
MAQUETA = [(812, 1000), (645, 1000), (1012, 1000), (380, 1000)]


def test_avance_con_los_numeros_de_la_maqueta():
    r = avance(MAQUETA)
    assert r == {
        "hechas_total": 2849,
        "meta_total": 4000,
        # El modelo que se pasa de meta (1012) solo cuenta 1000: lo de mas no
        # tapa lo que le falta a los otros.
        "contadas": 2837,
        "faltan": 1163,
        # 70,925 % -> 70 (floor), para no mostrar 100 % antes de tiempo.
        "porcentaje": 70,
    }


def test_avance_no_llega_a_100_si_falta_una_pieza():
    assert avance([(999, 1000)])["porcentaje"] == 99
    assert avance([(1000, 1000)])["porcentaje"] == 100


def test_avance_sin_modelos_no_divide_por_cero():
    r = avance([])
    assert r["porcentaje"] == 0 and r["faltan"] == 0 and r["meta_total"] == 0


def test_ritmo_reparte_lo_que_falta_entre_los_dias():
    # Hoy cuenta como un dia: del 23 de octubre al 20 de noviembre son 29.
    assert ritmo(1163, date(2026, 11, 20), date(2026, 10, 23)) == {
        "dias": 29, "por_dia": 41, "vencido": False}  # 1163/29 = 40,1 -> 41


def test_ritmo_entrega_hoy_cuenta_un_dia():
    r = ritmo(22, date(2026, 10, 23), date(2026, 10, 23))
    assert r["dias"] == 1 and r["por_dia"] == 22 and r["vencido"] is False


def test_ritmo_vencido_no_divide_por_cero_ni_por_negativos():
    r = ritmo(5, date(2026, 10, 20), date(2026, 10, 23))
    assert r == {"dias": -2, "por_dia": None, "vencido": True, "vencido_hace": 3}
    # Ayer: dias = 0, el caso que dividiria por cero.
    r = ritmo(5, date(2026, 10, 22), date(2026, 10, 23))
    assert r["vencido"] is True and r["vencido_hace"] == 1 and r["por_dia"] is None


def test_ritmo_completo_y_sin_fecha():
    assert ritmo(0, date(2026, 11, 20), date(2026, 10, 23)) == {"completo": True}
    # Completo gana aunque la fecha ya haya pasado: no hay nada vencido.
    assert ritmo(0, date(2026, 10, 1), date(2026, 10, 23)) == {"completo": True}
    assert ritmo(10, None, date(2026, 10, 23)) is None


def test_es_parecida():
    base = datetime(2026, 10, 23, 15, 2)
    assert es_parecida(50, base, 50, datetime(2026, 10, 23, 15, 42)) is True
    assert es_parecida(50, base, 50, datetime(2026, 10, 23, 19, 0)) is False
    assert es_parecida(50, base, 49, datetime(2026, 10, 23, 15, 42)) is False


def test_es_parecida_el_limite_de_la_ventana_cuenta_y_vale_en_ambos_sentidos():
    base = datetime(2026, 10, 23, 15, 0)
    assert es_parecida(50, base, 50, base + timedelta(hours=3)) is True
    assert es_parecida(50, base, 50, base - timedelta(hours=3)) is True
    assert es_parecida(50, base, 50, base + timedelta(hours=3, seconds=1)) is False
    assert es_parecida(50, base, 50, base + timedelta(hours=1), ventana=timedelta(minutes=30)) is False
