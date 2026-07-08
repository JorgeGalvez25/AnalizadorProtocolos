# Analizador de Comandos Seriales — Protocolos de Dispensarios I-Gas

Documento de referencia para continuar el desarrollo de la herramienta de análisis
de tramas seriales entre I-Gas (servicios `PDISPENSARIOS`) y las consolas de
dispensarios de combustible. Generado a partir del análisis del código fuente
Delphi de los drivers reales de I-Gas.

- **Fuentes analizadas:** `UIGASBENNETT.pas`, `UIGASWAYNE2W.pas`
- **Herramienta:** aplicación **Delphi 7** (VCL pura, sin componentes de terceros)
- **Propósito:** pegar tramas capturadas con un espía de puerto serial y obtener
  el desglose de cada parte del comando con un color distinto por parte, una
  indicación breve de cada parte, y validación de integridad (BCC / complementos).

---

## 1. Contexto de los drivers I-Gas

Los drivers son **servicios de Windows Delphi** (`TService`) que se comunican:

- Por **puerto serial** (`TApdComPort` de Async Professional) con la consola o
  cadena de dispensarios de la marca correspondiente.
- Por **socket TCP** (`TClientSocket`, típicamente `127.0.0.1:1004`) con
  `UDISBRIDGE` (el Bridge de la arquitectura de consola nueva), intercambiando
  JSON con `uLkJSON`. Comandos de alto nivel del Bridge: `INITIALIZE`, `PRICES`,
  `AUTHORIZE` (→ genera `OCC`/`OCL` internos), `STOP`, `START`, `PAYMENT`,
  `TRANSACTION`, `STATUS`, `TOTALS`, `RUN`, `HALT`, `SHUTDOWN`, `TERMINATE`, etc.
- Configuración en `PDISPENSARIOS.ini` (RutaLog, ServidorSocket, Licencia,
  MinutosLog, MapeoCombustibles/MapeoMangueras).

Estados internos comunes del ciclo I-Gas por posición de carga: cada driver
mapea el estatus físico del dispensario a una cadena de estado que consume el
Bridge (`0` sin comunicación, `1` inactivo, `2` cargando, `3` fin de carga,
`5` llamando, `7` deshabilitado, `8` detenido, `9` autorizado).

---

## 2. Protocolo BENNETT (ASCII)

### 2.1 Trama física

```
<STX> payload <ETX> BCC
```

| Elemento | Valor |
|---|---|
| STX | `#2` (02h) |
| ETX | `#3` (03h) |
| BCC | `char(256 − (Σ bytes(payload + ETX) mod 256))` — función `CalculaBCC` |
| ACK / NAK | `#6` / `#21`, respuestas de un solo byte sin trama |

El driver arma la trama en `ComandoConsola`: `#2 + ss + #3 + BCC`.
Al recibir (`pSerialTriggerAvail`), acumula hasta ETX+1 byte (el BCC) o hasta
ACK/NAK, y procesa en `ProcesaLinea` descartando basura previa al STX.

### 2.2 Comandos TX (Consola I-Gas → Dispensario)

Posición de carga siempre en **2 dígitos ASCII** (`IntToClaveNum(xpos,2)`).

| Cmd | Formato | Función | Notas |
|---|---|---|---|
| `B` | `B00` | Poll de estatus de TODAS las bombas | Enviado cada ciclo del Timer1; `00` = broadcast |
| `A` | `A` + pos(2) | Solicita venta en curso, formato **6 dígitos** | |
| `1` | `1` + pos(2) | Solicita venta en curso, formato **8 dígitos** | Solo si variable `Bennett8Digitos=Si` |
| `N` | `N` + pos(2) | Solicita totalizadores por manguera | |
| `U` | `U` + pos(2) + nivel(1) + grado(1) + precio | Cambio de precio | nivel: `1`=contado, `2`=crédito; precio en dígitos con 2 decimales implícitos |
| `K` | `K` + pos(2) + modo(1) | Modo de operación | `1`=postpago, `2`=prepago |
| `L` | `L` + pos(2) + nivel(1) | Nivel de precios activo | `1`=contado, `2`=crédito |
| `E` | `E` + pos(2) | DESAUTORIZAR | |
| `S` | `S` + pos(2) [+ grado] | AUTORIZAR | Carácter opcional de selección de producto (si `SoportaSeleccionProducto=Si`): `!`(21h)=grado 1, `"`(22h)=grado 2, `(`(28h)=grado 3, `$`(24h)=grado 4 |
| `P` | `P` + pos(2) + importe(6) | PRESET por importe, 6 dígitos | 2 decimales implícitos. `999900` ($9,999.00) = tope/cancelación |
| `5` | `5` + pos(2) + importe(8) | PRESET por importe, 8 dígitos | `99999900` = tope. Usado con `Bennett8Digitos=Si` |
| `F` | `F` + pos(2) + litros(4) | PRESET por volumen (litros enteros) | `9999` = tope/limpieza tras la venta (`SwCmndF`) |
| `J` | `J` + pos(2) | FIN DE VENTA (cierra/paga la transacción) | Enviado tras `SegundosFinv` o por comando `FINV` |

Secuencia de inicialización por posición (estatus 1 + `SwInicio`):
`K..1` (postpago) → `L..1` (nivel contado) → `E..` (desautorizar).
Secuencia de preset (`EnviaPreset`): `K..2` (prepago) → `P`/`5` (importe) →
`L..1` → `S..`[grado]. Reintentos controlados por `BennetReintentosPreset` (def. 5).

### 2.3 Respuestas RX (Dispensario → Consola)

| Resp | Layout (índices 1-based del payload) | Interpretación |
|---|---|---|
| `B00` + pares | por posición i: char(2i−1)=manguera/grado activo, char(2i)=estatus | Núm. de posiciones = (len−3)/2 |
| `A` | [2..3]=pos, [4]=manguera/grado (no usado por I-Gas), [5..10]=volumen, [11..16]=importe, [17..20]=precio | Todos ÷100 (2 dec. implícitos) |
| `1` | [2..3]=pos, [4]=idem, [5..12]=volumen, [13..20]=importe, [21..25]=precio | ÷100 |
| `N` | [2..3]=pos, [4..13],[14..23],[24..33],[34..43]=totales mangueras 1..4 | ÷1000 (3 dec. implícitos) |
| ACK/NAK | un byte | Aceptación / rechazo del comando anterior |

**Estatus Bennett** (dígito por posición en respuesta `B`):
`0`=sin comunicación, `1`=inactivo, `2`=autorizado, `3`=pistola levantada,
`4`=listo para despachar, `5`=despachando, `6`=detenido, `7`=fin de venta,
`8`=venta pendiente, `9`=error.

**Validaciones del driver dignas de nota:** anti-parpadeo del estatus 0
(`stcero`≤3 conserva el anterior); corrección de importes >$10,000 (si
|vol×precio − importe| ≥ 900 recalcula el importe); reconciliación de volumen
(si |vol − importe/precio| < 0.05 usa el calculado).

**Pendiente de confirmar en campo:** el carácter [4] de las respuestas `A`/`1`
se etiquetó como "manguera/grado activo" por inferencia; I-Gas no lo lee.

### 2.4 Ejemplos verificados (BCC calculado con el algoritmo real)

```
<STX>B0011315217<ETX><BCC=$C6>            poll/estatus 4 posiciones
<STX>A0100125501782501420<ETX><BCC=$00>   venta 6 díg: 125.50L $1,782.50 @$14.20
<STX>1020000887500012500014200<ETX><BCC=$1F>  venta 8 díg
<STX>P04025075<ETX><BCC=$16>              preset $250.75 pos 4
<STX>P04999900<ETX><BCC=$05>              preset tope (cancela)
<STX>50501234500<ETX><BCC=$D4>            preset 8 díg $12,345.00
<STX>F060150<ETX><BCC=$8B>                preset 150 L
<STX>S08"<ETX><BCC=$20>                   autorizar solo grado 2
<STX>K112<ETX><BCC=$1E>                   modo prepago pos 11
<STX>U142301630<ETX><BCC=$E4>             precio crédito grado 3 $16.30
<STX>J15<ETX><BCC=$4D>                    fin de venta
<STX>P16003000<ETX><BCC=$24>              BCC INCORRECTO a propósito (real $23)
```

---

## 3. Protocolo WAYNE 2W (binario, byte + complemento)

### 3.1 Trama física — `EmpacaWayne` / `DesEmpacaWayne`

Cada byte de datos viaja seguido de su **complemento a 255**:

```
00 00  [D1 ~D1] [D2 ~D2] ... [Dn ~Dn]  FF
```

- Comandos de datos: **n=5** → trama de **13 bytes** en el cable.
- Sondeo de estatus: **n=1** → trama de **5 bytes**.
- **Toda respuesta válida mide 13 bytes** (5 bytes de datos). `DesEmpacaWayne`
  valida que cada par sume 255 y extrae los 5 bytes de datos (posiciones crudas
  3,5,7,9,11); si algún par falla, descarta la trama completa.
- No hay ACK/NAK; la confirmación es recibir 13 bytes válidos dentro del
  timeout (`GtwTimeout`, def. 1000 ms; reintento tras `GtwTiempoCmnd`).

### 3.2 Byte de control (D1)

```
ControlByte(pos, cmd) = pos*8 + cmd        (pos ≤ 31, cmd ≤ 7)
bits 7..3 = posición de carga   bits 2..0 = número de comando
```

### 3.3 Comandos TX

| cmd | D2 | D3 | D4 | D5 | Función (función Delphi) |
|---|---|---|---|---|---|
| 1 | — | — | — | — | Solicitar ESTATUS (trama de 1 byte) — `DameEstatus` |
| 0 | `97h` | 0 | 0 | 0 | REANUDAR despacho — `ReanudaDespacho` |
| 0 | `A7h` | 0 | 0 | 0 | DETENER despacho — `DetenerDespacho` |
| 0 | `8Fh` | 0 | 0 | 0 | AUTORIZAR todas las mangueras — `Autoriza` |
| 0 | `88h+n` | 0 | 0 | 0 | AUTORIZAR solo manguera física n+1 — `AutorizaPm` (con xpm=0 usa `96h`) |
| 7 | `00h` | mang−1 | 0 | 0 | LEER PRECIO de manguera — `LeePrecios`/`DameLecturas` |
| 7 | `01h` | mang−1 (nivel 1) ó 16+mang−1 (nivel 2) | LSB | MSB | CAMBIAR PRECIO — `CambiaPrecios` (binario, centavos; envía nivel 1 y luego nivel 2) |
| 7 | `21h` | BCD₁ | BCD₂ | BCD₃ | PRESET por IMPORTE — `EnviaPresetPesosBomba` tipo 1 (valor × DivImporte, `ConvierteBCD` 6 dígitos LSB-first) |
| 7 | `23h` | BCD₁ | BCD₂ | BCD₃ | PRESET por LITROS — tipo 2 (valor × DivLitros) |
| 7 | `2Ah` | 0 | 0 | 0 | LEER IMPORTE de la venta — `DameLecturas` |
| 7 | `26h` | 0 | 0 | 0 | LEER VOLUMEN de la venta — `DameLecturas` |
| 7 | `04h` | `2Fh`+mang | 0 | 0 | TOTALIZADOR parte 1 (dígitos bajos) — `DameTotal` |
| 7 | `02h` | `2Fh`+mang | 0 | 0 | TOTALIZADOR parte 2 (dígitos medios) |
| 7 | `16h` | `2Fh`+mang | 0 | 0 | TOTALIZADOR parte 3 (dígitos altos) |

### 3.4 Respuestas RX (5 bytes de datos; el significado depende del comando previo)

| Respuesta a | Decodificación |
|---|---|
| Estatus (cmd 1) | Byte de estatus = **D5**. Bits: b7=motor/despachando; b3=autorizada; b4=detenida; b0-b2=campo de manguera (`111`=todas colgadas; otro valor+1=manguera física activa/levantada). Lógica derivada: b7 con b0-2=111 → fin de venta (si importe>0) o autorizada; b7 con manguera → despachando; solo b3 → autorizada; solo b4 → detenida en fin de venta (I-Gas manda Reanudar); b0-2≠111 sin b7 → pistola levantada; todo lo demás → inactiva |
| Precio (reg 00h) | **BINARIO**: precio = (256×D5 + D4) / 100 |
| Importe (reg 2Ah) | **BCD** D3..D5 LSB-first (`ExtraeBCD(ss,3,5)`) ÷ `DivImporte` |
| Volumen (reg 26h) | **BCD** D3..D5 LSB-first ÷ `DivLitros` |
| Totalizador | **BCD** D4..D5 LSB-first (`ExtraeBCD(ss,4,5)`, 4 dígitos por parte). Total litros = (p1 + p2×10⁴ + p3×10⁸) / 100 |

**BCD Wayne:** cada byte guarda 2 dígitos decimales en sus nibbles; los bytes
van del menos significativo al más. Ej.: importe $345.67 → 34567 → `67 45 03`.
Ojo: el **precio NO es BCD**, es binario de 16 bits.

**Estatus interno I-Gas Wayne** (¡numeración distinta a Bennett!):
0=sin comunicación, 1=inactiva, **2=despachando**, 3=fin de venta,
**5=pistola levantada**, 8=detenida, **9=autorizada**.

### 3.5 Particularidades del driver Wayne

- **Variables de inicialización** (bloque `variables` del INITIALIZE):
  `WtwDivImporte` (def. 100), `WtwDivLitros` (def. 100), `GtwTimeout` (1000 ms),
  `GtwTiempoCmnd` (1000 ms), `WtwPosIniExt` (posición a partir de la cual se usa
  el 2.º puerto serial), `ModoEmulacion` (Si/No).
- **Dos puertos seriales** (`pSerial`/`pSerial2`, `TransmiteComando1/2`,
  `SegmActual`, `PonPuertoPos`): la cadena de dispensarios puede estar
  segmentada en dos lazos.
- **Modo emulación** (`SwModoEmulacion`/`AvanzaEmulacion`): simula ventas sin
  puerto serial para pruebas del Bridge; no genera tráfico serial.
- `SwLecturaFinalPendiente`: mantiene el estado "cargando" hacia el Bridge
  hasta obtener la lectura final (mismo patrón corregido en UIGASTEAM).

### 3.6 Ejemplos verificados (complementos calculados)

TX:
```
00 00 09 F6 FF                                  poll estatus pos 1 (ctrl 09h = 1*8+1)
00 00 08 F7 8F 70 00 FF 00 FF 00 FF FF          autorizar todas pos 1
00 00 08 F7 89 76 00 FF 00 FF 00 FF FF          autorizar solo manguera física 2 pos 1
00 00 10 EF A7 58 00 FF 00 FF 00 FF FF          detener pos 2
00 00 10 EF 97 68 00 FF 00 FF 00 FF FF          reanudar pos 2
00 00 1F E0 21 DE 00 FF 00 FF 05 FA FF          preset importe $500.00 pos 3 (BCD 00 00 05)
00 00 1F E0 23 DC 00 FF 40 BF 00 FF FF          preset 40.00 L pos 3 (BCD 00 40 00)
00 00 27 D8 00 FF 00 FF 00 FF 00 FF FF          leer precio manguera 1 pos 4
00 00 27 D8 01 FE 01 FE 1E E1 0A F5 FF          cambiar precio m2 pos 4 $25.90 nivel 1
00 00 27 D8 01 FE 11 EE 1E E1 0A F5 FF          ídem nivel 2 (D3 = 16+mang−1)
00 00 2F D0 2A D5 00 FF 00 FF 00 FF FF          leer importe pos 5
00 00 2F D0 26 D9 00 FF 00 FF 00 FF FF          leer volumen pos 5
00 00 37 C8 04 FB 30 CF 00 FF 00 FF FF          totalizador parte 1 manguera 1 pos 6
```

RX (elegir el contexto en la herramienta):
```
00 00 09 F6 00 FF 00 FF 00 FF 80 7F FF          estatus 80h: despachando manguera 1
00 00 09 F6 00 FF 00 FF 00 FF 07 F8 FF          estatus 07h: inactiva (colgadas)
00 00 09 F6 00 FF 00 FF 00 FF 08 F7 FF          estatus 08h: autorizada
00 00 27 D8 00 FF 00 FF CA 35 08 F7 FF          precio: 256*08h + CAh = 2250 → $22.50
00 00 2F D0 2A D5 67 98 45 BA 03 FC FF          importe BCD 67 45 03 → $345.67
00 00 2F D0 26 D9 12 ED 20 DF 00 FF FF          volumen BCD 12 20 00 → 20.12 L
00 00 37 C8 04 FB 30 CF 34 CB 12 ED FF          total parte 1 BCD 34 12 → 1234
```

---

## 4. Arquitectura de la herramienta (Delphi 7)

### 4.1 Archivos del proyecto `AnalizadorProtocolos`

| Archivo | Contenido |
|---|---|
| `AnalizadorProtocolos.dpr` | Proyecto |
| `UAnalizadorBase.pas` | `TParte` (Texto/Nombre/Descripcion), clase abstracta `TAnalizadorBase` y el **render común** al `TRichEdit`: encabezado (tipo + dirección TX/RX), trama con **cada parte en un color** (paleta `ColoresParte[0..7]`, fuente Courier 14 bold; prefijo/sufijo de trama en gris), desglose línea por línea en el mismo color, línea de validación (verde/rojo) y nota en naranja |
| `UProtoBennett.pas` | `TAnalizadorBennett`: normaliza entrada (tokens `<STX>/<ETX>/<ACK>/<NAK>` y hexdump con bytes de control), extrae payload, interpreta B/A/1/N/U/K/L/E/S/P/5/F/J y valida el BCC |
| `UProtoWayne2W.pas` | `TAnalizadorWayne2W`: parsea hex (con o sin espacios), detecta tramas empacadas 00 00…FF de 5/13 bytes o datos crudos de 1/5 bytes, valida los pares byte+complemento, interpreta TX por byte de control y RX según el combo "Interpretar como" (Estatus/Precio/Importe/Volumen/Totalizador) |
| `UPrincipal.pas/.dfm` | Formulario con un `TPageControl`; **las pestañas y sus controles se crean en runtime** a partir de los analizadores registrados. La pestaña toma su Caption de `Analizador.Nombre` |

### 4.2 Contrato de la clase base

```pascal
TAnalizadorBase = class
  function  Nombre: string; virtual; abstract;              // caption de la pestaña
  procedure CargaEjemplos(sl: TStrings); virtual; abstract; // combo de comandos
  procedure CargaContextos(sl: TStrings); virtual;          // vacío = sin combo extra
  procedure Analiza(const AEntrada: string; AContexto: Integer); virtual; abstract;
  procedure Render(re: TRichEdit);                          // común, no se sobreescribe
protected // para llenar en Analiza:
  FTipo, FDireccion, FNota, FPrefijo, FSufijo: string;
  procedure AgregaParte(Texto, Nombre, Descripcion);
  procedure PonValidacion(Texto, Ok);
end;
```

El **combo de contexto** ("Interpretar como") solo aparece si el protocolo
define contextos. Bennett no lo necesita (sus tramas ASCII se auto-describen);
Wayne sí, porque una respuesta binaria de 13 bytes no indica a qué comando
responde.

### 4.3 Cómo agregar una MARCA NUEVA (checklist para futuros chats)

1. Analizar la unidad `UIGAS<MARCA>.pas` del driver: ubicar el armado de la
   trama TX (buscar `PutString`/`PutChar`/`TransmiteComando`), la recepción
   (`TriggerAvail`/`ProcesaLinea`), el checksum, y catalogar los comandos con
   sus campos y las respuestas con sus offsets/decodificación.
2. Crear `UProto<Marca>.pas` heredando de `TAnalizadorBase` (usar
   `UProtoBennett` como plantilla para protocolos ASCII y `UProtoWayne2W`
   para binarios).
3. Agregar la unidad al `uses` de `UPrincipal` y del `.dpr`, y una línea en
   `TfrmPrincipal.FormCreate`:
   `RegistraAnalizador(TAnalizador<Marca>.Create);`
   — la pestaña, el combo de ejemplos, el combo de contexto (si aplica), el
   botón y el RichEdit se generan solos.
4. Precargar ejemplos con checksum/empacado **calculado con el algoritmo real**
   (verificado por script), incluyendo un caso corrupto y uno no reconocido
   para probar la validación.
5. Documentar el protocolo en este MD (sección nueva al estilo de las §2 y §3).

### 4.4 Formatos de entrada aceptados

- **Bennett:** texto plano (`P01005000`), tokens (`<STX>...<ETX>`), o hexdump
  con espacios (`02 50 30 ... 03 A7`; se reconoce como hex solo si contiene
  02/03/06/15 para no confundir payloads de puros dígitos).
- **Wayne 2W:** hexadecimal con espacios/comas o continuo; trama empacada
  completa (5/13 bytes) o bytes de datos crudos (1/5 bytes).

### 4.5 Decisiones de diseño

- Delphi 7 / VCL estándar únicamente (`StdCtrls`, `ComCtrls`, `ExtCtrls`);
  sin DevExpress ni terceros para que compile en cualquier instalación.
- `TRichEdit` con `SelAttributes` para el coloreado; `Lines.BeginUpdate` para
  evitar parpadeo; el comando analizado se agrega al historial del combo.
- Colores reciclados con `mod 8`; prefijo/sufijo de trama (STX/ETX/BCC,
  `00 00`/`FF`) siempre en gris para distinguir envoltura de datos.
- La validación de integridad usa exactamente los algoritmos del driver
  (`CalculaBCC` Bennett; pares complemento `DesEmpacaWayne`).

---

## 5. Pendientes y siguientes pasos

- [ ] Confirmar con capturas reales el byte [4] de las respuestas Bennett `A`/`1`.
- [ ] Confirmar en campo el layout de los bytes D1..D4 de las respuestas Wayne
      (I-Gas solo lee los campos documentados; el resto se muestra como
      "no interpretado").
- [ ] Posible mejora: modo "sesión" que recuerde el último comando TX enviado
      para auto-seleccionar el contexto de la respuesta Wayne.
- [ ] Posible mejora: pegar un log completo del espía y analizar trama por trama.
- [ ] Marcas candidatas a agregar (drivers existentes en I-Gas): TEAM
      (`UIGASTEAM.pas`, ya analizado parcialmente en otra sesión: comandos A1,
      totalizadores por diferencia, precisión /1000), Gilbarco, etc.
