# 3D Organizer — pedidos grandes y calculadora de bolsillo

Fecha: 2026-10-23 · Dueño: Juan (PrintoVerse) · Estado: diseño aprobado por Juan (2026-10-23)

Nombre de la app: **pendiente** (Juan no ha elegido; rechazó Tandas, PrintoTaller,
Lote 3D, Cama Llena). Mientras tanto el nombre interno es "3D Organizer".

## Por qué existe

Juan tiene un negocio de impresión 3D (PrintoVerse). Además de los pedidos de la
tienda, le llegan **pedidos grandes por fuera de la página**: por ejemplo 4.000
llaveros, 4 modelos, 1.000 de cada uno. Los imprime en varias impresoras y salen
**tandas de tamaño variable** (una de 50, otra de 37…). Hoy no lleva un registro
fiable: a veces no recuerda si ya anotó una tanda y la anota dos veces, y no sabe
con certeza cuánto lleva y cuánto falta de cada modelo.

Segundo dolor: cuando está fuera del computador (mirando un modelo en MakerWorld,
por ejemplo) quiere hacer un cálculo rápido de costo/precio con **su** calculadora
(la de escritorio, `../calculadora-3d`), que tiene sus filamentos y los datos de
su casa (precio del kWh, consumo, desgaste, margen). En el celular no la tiene.

Es una herramienta **solo para Juan**. Se distribuye por **TestFlight** y **no se
publicará en la App Store**.

## Qué se construye

Tres piezas:

1. **Servidor "sistema"** (API + base de datos) en el VPS de PrintoVerse.
2. **Página web** en `sistema.printoverse.store` (para el computador).
3. **App de iPhone** (SwiftUI).

### 1. Pedidos grandes (en el iPhone y en la web, igual en las dos)

- **Pedido grande**: nombre ("Llaveros empresa X"), cliente (texto libre),
  **fecha de entrega opcional**, estado (abierto / terminado), nota opcional.
- **Modelos del pedido**: nombre, meta en unidades (ej. 1.000), **foto opcional**
  (para reconocerlo rápido en el celular).
- Puede haber **varios pedidos grandes abiertos a la vez**.
- **Tanda**: modelo + cantidad **buena** + fecha y hora (las pone el sistema al
  anotar; editables al corregir). Juan descuenta las defectuosas antes de anotar:
  **no se registran defectuosas** ni la impresora.
- Las tandas se pueden **corregir y borrar**. Historial de tandas por pedido y por
  modelo, ordenado por fecha y hora.
- **Aviso de posible duplicado**: al anotar, si existe otra tanda del **mismo
  modelo y misma cantidad** en las últimas horas, se avisa ("Ya anotaste 50 del
  Modelo A hace 40 min, ¿es otra tanda?") y Juan decide. Nunca bloquea.
  (Ventana de tiempo: decisión del builder; algo como 3 horas.)
- **Avance**: barra por modelo (buenas / meta y cuántas faltan) y del pedido
  completo. Un modelo que llega a la meta se marca completo. **Pasarse de la meta
  se permite y se muestra** (1.012 / 1.000), no se bloquea.
- **Fecha de entrega**: si el pedido la tiene, mostrar cuántas unidades por día
  hacen falta para llegar a tiempo (lo que falta ÷ días que quedan, contando hoy).
  Si ya pasó, decirlo claramente. Los pedidos sin fecha no muestran nada de esto.
- Marcar un pedido como terminado lo saca de la lista principal (queda en un
  apartado de terminados, consultable).

### 2. Calculadora de bolsillo (solo iPhone; NO va en la web)

Calcula **piezas sueltas**. Nada de proyectos ni megaproyectos.

Entradas:
- Horas y minutos de impresión.
- Gramos y **filamento principal** (de la lista de filamentos guardados).
- **Varios filamentos**: filas extra de filamento + gramos.
- **Unidades por cama**.
- **Partes extra** (opcional): cada una con su tiempo y sus filamentos/gramos.
- **Insumos** (opcional): costo de insumos y, si se quiere, lo que se cobra por ellos.
- Margen de ganancia (multiplicador, como en la de escritorio).

**No lleva**: tiempo de preparador / horas invertidas, minutos de operario,
minutos de preparación de máquina. En las fórmulas cuentan como 0.

Resultados: costo y precio a cobrar **por pieza** y **por cama**, ganancia,
tiempo con margen de error, gramos. Con el redondeo que tenga la de escritorio
como opción por defecto (decisión del builder si se expone o no).

**Las fórmulas deben ser las mismas que la de escritorio** para que el número
coincida. Fuente: `../calculadora-3d/web_app/app.js`, función `calculate()`
(≈ línea 714). Resumen, todo por cama, en COP:
- material = Σ gramos × precio_kg_filamento / 1000 (principal + extra + partes)
- luz = (precioKwh × consumoWatts / 1000) × horas
- desgaste = (precioRepuestos / desgasteMaquina) × horas
- error = (material + luz + desgaste) × margenError%
- costoBase = material + luz + desgaste + error
- totalCobrar = costoBase × margenGanancia + insumosACobrar (mano de obra = 0 aquí)
- por pieza = ÷ unidades por cama; ganancia = cobrar − costoBase − insumos
- horas y gramos "con margen" = × (1 + margenError%)
- Partes extra suman horas y gramos a la cama.
El builder porta esta función tal cual (sin la mano de obra) y la verifica con un
par de piezas guardadas en `perfiles.json` (ej. "QR1", "Destapador JK") contra lo
que da la de escritorio.

**Perfiles y filamentos**
- Copia **única** desde `../calculadora-3d/perfiles.json`: el perfil "AD5M Casa"
  (precioKwh, consumoWatts, desgasteMaquina, precioRepuestos, margenError,
  precioDolar…) y la lista `filamentos` (marca, color, tipo, precio, moneda).
  No se copian piezas, proyectos ni megaproyectos. La importación la hace el
  builder con un script una sola vez al montar el servidor.
- **Sin sincronización** con la de escritorio. **La app de escritorio no se toca.**
- En el iPhone se pueden **crear perfiles nuevos** y **agregar/editar filamentos**.
- Perfiles y filamentos se guardan en el servidor (no se pierden al cambiar de
  iPhone). La calculadora debe **funcionar sin internet** con la última copia
  descargada.
- Guardar piezas calculadas: fuera de alcance por ahora.

### 3. Acceso

- Se entra con el **mismo usuario (correo y contraseña) del panel de PrintoVerse**.
- Solo Juan usa el sistema; no hay roles ni permisos dentro de 3D Organizer.
- **Solo entra el correo de Juan** (decisión de Juan). El panel de PrintoVerse
  tiene más usuarios, pero ninguno más entra aquí. El correo permitido va en la
  configuración del servidor (`.env`), no en el código. Además, esa cuenta tiene
  que estar activa y sin contraseña temporal pendiente (`debe_cambiar`).
- En el iPhone la sesión se queda abierta (no pedir la contraseña cada vez).

## Cómo va montado (decisiones mías, Juan las delegó)

- **Mismo VPS de PrintoVerse** (OVH `149.56.129.121`, nginx compartido). Juan
  quiere mejorar el servidor más adelante; eso es otro proyecto.
- **Servicio aparte**, no dentro de la API de PrintoVerse: FastAPI propio con su
  servicio systemd, detrás del mismo nginx, en `sistema.printoverse.store`
  (bloque `server` nuevo + certificado). Mismo estilo que PrintoVerse: Python,
  todo en español (nombres, variables, comentarios), web sin framework ni build.
- **Base de datos propia** en el MySQL del servidor (separada de la de la tienda).
- **Login**: el servicio valida contra la tabla de usuarios de PrintoVerse en solo
  lectura (usuario MySQL con permiso SELECT solo sobre esa tabla) y reutiliza el
  formato de huella scrypt de `../printoverse_web/api/usuarios.py`. Emite su propia
  sesión (cookie en la web, token en el iPhone guardado en el Llavero).
- **iPhone**: SwiftUI, iOS 26 con Liquid Glass y material translúcido como
  alternativa en iOS anteriores (mínimo iOS 17, decisión del builder si baja más).
  **Solo español.** Dynamic Type, VoiceOver y háptica al anotar una tanda.
  Adaptado a cualquier iPhone (isla, notch, SE).
- **Anotar sin señal**: si no hay internet al anotar una tanda, se guarda en el
  teléfono y se envía sola al volver la conexión. Una tanda anotada no se puede
  perder.
- **Compilación**: GitHub Actions (macOS, Xcode 26) → TestFlight, push directo a
  `main`, `paths-ignore` para documentación y para la carpeta del servidor/web
  (solo compila cuando cambia la app). Claves solo en Secrets.
- **Repo PÚBLICO** (decisión de Juan, excepción a su regla general de repos
  privados): en un repo público las compilaciones de GitHub Actions no gastan
  minutos. Como consecuencia, **nunca van al repo**: `.env`, claves, contraseñas,
  la copia de `perfiles.json` ni ningún dato real (pedidos, clientes, precios).
  El script de importación lee `perfiles.json` desde la ruta local y lo manda al
  servidor, sin guardar una copia en el repo. `.gitignore` desde el primer commit.
  La seguridad no puede depender de que el código sea secreto: toda la API exige
  sesión. Cuando la app esté más o menos lista, Juan lo pasa a privado.
- Versión fija (MARKETING_VERSION) mientras se prueba; el número de compilación lo
  pone GitHub.
- Repositorio: esta carpeta (`3D Organizer`) con `ios/` y `servidor/` (API + web),
  subida a un repo público `samechp/3d-organizer`.
- **Identificador permanente de la app**: `store.printoverse.organizador`, que no
  depende del nombre. El nombre que se ve en el iPhone empieza como "3D Organizer"
  y se cambia cuando Juan elija uno, sin reinstalar ni crear otra app.

## Lo que queda fuera (a propósito)

- Impresoras, defectuosas, tiempos por tanda.
- Conexión con los pedidos o la cola de impresión de la tienda (`produccion.py`).
- Calculadora en la web, proyectos y megaproyectos en el iPhone.
- Sincronizar con la calculadora de escritorio o modificarla.
- App Store, inglés, varios usuarios.

## Anti-objetivos (si pasa esto, falló aunque "funcione")

- Que anotar una tanda tome más de unos segundos o varios toques.
- Que se pierda una tanda anotada (sin señal, sesión vencida, error del servidor).
- Que la calculadora del celular dé un número distinto a la de escritorio con los
  mismos datos.
- Que algo toque la tienda PrintoVerse o la app de escritorio.

## Antes de programar

Maqueta interactiva (Artifact tipo Design) de las pantallas del iPhone, con una
versión por tipo de iPhone donde importe, y de la web. Se programa cuando Juan la
apruebe.

## Lo que queda al builder

Estructura de tablas, endpoints, diseño de pantallas (sujeto a la maqueta),
ventana exacta del aviso de duplicado, redondeo, cómo se suben y guardan las fotos
de los modelos, plan de despliegue siguiendo el patrón de `../printoverse_web/despliegue/`.
