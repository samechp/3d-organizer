"""
calculos.py - Las cuentas de un pedido, sin base de datos.

Van aparte de las rutas para poder probarlas con numeros sueltos, y porque la
app del iPhone repite la misma logica: si cambia una, hay que cambiar la otra.
"""

from datetime import date, timedelta
from math import ceil


# Dos tandas iguales separadas por mas que esto se consideran distintas.
VENTANA_PARECIDA = timedelta(hours=3)


def avance(modelos: list[tuple[int, int]]) -> dict:
    """Resume el avance de un pedido a partir de (hechas, meta) de cada modelo.

    Cada modelo aporta como maximo su meta: si el dragon va en 1.012 de 1.000,
    esas 12 de mas no pueden tapar lo que le falta al zooki. Por eso `contadas`
    no es lo mismo que `hechas_total`.
    """
    hechas_total = sum(hechas for hechas, _ in modelos)
    meta_total = sum(meta for _, meta in modelos)
    contadas = sum(min(hechas, meta) for hechas, meta in modelos)
    return {
        "hechas_total": hechas_total,
        "meta_total": meta_total,
        "contadas": contadas,
        "faltan": meta_total - contadas,
        # Division entera (floor) y no redondeo: 99,6 % no puede mostrarse como
        # 100 % mientras todavia falta una pieza. Sin metas no hay nada que medir.
        "porcentaje": contadas * 100 // meta_total if meta_total else 0,
    }


def ritmo(faltan: int, entrega: date | None, hoy: date) -> dict | None:
    """Cuantas piezas por dia hay que hacer para llegar a la entrega.

    El dia de la entrega cuenta como dia de trabajo (entrega hoy = 1 dia), por
    eso el +1. Con la fecha ya pasada no se divide: dias queda en 0 o negativo
    y lo que se informa es cuantos dias lleva vencido.
    """
    if entrega is None:
        return None
    if faltan <= 0:
        # Gana sobre "vencido": un pedido terminado no debe salir en rojo
        # solo porque su fecha ya paso.
        return {"completo": True}
    dias = (entrega - hoy).days + 1
    if dias >= 1:
        return {"dias": dias, "por_dia": ceil(faltan / dias), "vencido": False}
    return {"dias": dias, "por_dia": None, "vencido": True, "vencido_hace": 1 - dias}


def es_parecida(nueva_cant: int, nueva_cuando, previa_cant: int, previa_cuando,
                ventana: timedelta = VENTANA_PARECIDA) -> bool:
    """True si una tanda se parece a otra: misma cantidad y muy cerca en el tiempo.

    Es el aviso de "¿ya la anotaste?": tocar dos veces el boton o anotar desde
    el iPhone y desde la web da dos tandas casi identicas. La distancia se mide
    en valor absoluto porque la tanda nueva puede llevar una hora pasada.
    """
    return nueva_cant == previa_cant and abs(nueva_cuando - previa_cuando) <= ventana
