# Analizador de Comandos Seriales — Protocolos de Dispensarios I-Gas

Documento de referencia para continuar el desarrollo de la herramienta de análisis
de tramas seriales entre I-Gas (servicios `PDISPENSARIOS`) y las consolas de
dispensarios de combustible. Generado a partir del análisis del código fuente
Delphi de los drivers reales de I-Gas.

- **Fuentes analizadas:** `UIGASBENNETT.pas`, `UIGASWAYNE2W.pas`, `UIGASPAM.pas`, `UIGASWAYNE.pas` (consola), `UIGASGILBARCO.pas`
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

## 4. Protocolo PAM 1000 (ASCII)

### 4.1 Trama física

```
<STX> payload <ETX> BCC
```

| Elemento | Valor |
|---|---|
| STX | `#2` (02h) |
| ETX | `#3` (03h) |
| BCC | **XOR** encadenado de todos los bytes de `payload + ETX` — a diferencia de Bennett (suma + complemento) |
| ACK / NAK | `#6` / `#21`, respuestas de un solo byte sin trama |

La versión de consola se controla con la variable `VersionPam1000` (default
`3`): cambia el setup (`D0…`), el preset (`P` vs `@02`) y los totales (`C` vs
`@10`).

### 4.2 Comandos TX (Consola I-Gas → PAM)

Posición de carga siempre en **2 dígitos ASCII**.

| Cmd | Formato | Función | Notas |
|---|---|---|---|
| `B` | `B00` | Poll de estatus de TODAS las posiciones | Cada ciclo del Timer1 |
| `A` | `A` + pos(2) | Solicita lectura de venta de una posición | |
| `T` | `T` + pos(2) + nivel(1) | Nivel de precios activo | `1`=cash (único usado). El PAM responde **ACK** (`swnivelprec`) |
| `D` | `D0` + setup | Setup de la consola | Con v3 el default es `D06222` (`SetUpPAM1000`) |
| `L` | `L` + pos(2) | OPEN PUMP | Abre una posición en estatus `6` (cerrada) |
| `G` | `G` + pos(2) | RESTART | Reanuda posición detenida |
| `E` | `E` + pos(2) | STOP / desautorizar | `E00` = **PARO TOTAL** |
| `S` | `S` + pos(2) | Autorizar sin límite | I-Gas registra $999 como preset simbólico |
| `R` | `R` + pos(2) | VENTA COMPLETA | Enviado por `FINV` con la posición en estatus 3 |
| `X` | `X00` + comb(1) + nivel(1) + `00` + precio(4) | Cambio de precio (centavos) | Se envía 2 veces: nivel `1` (contado) y `2` (crédito) con el mismo precio |
| `P` | importe: `P`+pos(2)+`0`+nivel+`000`+valor(5)+`0` · litros: `P`+pos(2)+`1`+nivel+`00`+valor(5)+`0`+grado | PRESET (versiones ≠ 3) | valor con 2 dec. implícitos (`FormatFloat 000.00`) |
| `@02` | `@02`+`0`+pos(2)+tipo+nivel+valor(6)+prodauto(6) | PRESET v3 | tipo `0`=importe/`1`=litros; valor `FormatFloat 0000.00`; prodauto = 6 banderas `0/1` de productos autorizados |
| `@10` | `@10`+`0`+pos(2) | Solicita totalizadores (v3) | |
| `C` | `C`+pos(2)+comb(1)+`1` | Total de una pistola (versiones ≠ 3) | |

### 4.3 Respuestas RX (PAM → Consola)

| Resp | Layout (índices 1-based del payload) | Interpretación |
|---|---|---|
| `B00` + dígitos | **UN dígito de estatus por posición** desde [4] | Núm. de posiciones = len−3 |
| `A` (cargando) | [2..3]=pos, [4]=`0`, [14..21]=importe parcial | [5..13] no leídos |
| `A` (concluida) | [2..3]=pos, [4]=grado, [6..13]=volumen, [14..21]=importe, [22..26]=precio | [5] no leído |
| `A` (sin mapa) | [4]=`\` | La posición perdió el mapeo; I-Gas lo reenvía |
| `C` | [2..3]=pos, [4]=producto, [6..15]=total | ÷100 |
| `@` (totales v3) | [5..6]=pos; grado/total en [8]/[9..18], [37]/[38..47], [66]/[67..76], [95]/[96..105] | total 10 dígitos ÷100; hasta 4 productos |
| ACK/NAK | un byte | Aceptación / rechazo |

**Divisores** (variables de `INITIALIZE`): `DigitosVolumen=2` → vol÷1000,
`DigitosImporte=2` → importe÷1000, `DigitosPrecio=1` → precio÷100 (cada
dígito n implica ÷10^(n+1)).

**Estatus PAM** (dígito por posición): `0`=offline, `1`=idle, `2`=busy,
`3`=fin de venta (EOT), `5`=llamando (call), `6`=**cerrada** (I-Gas envía
`L..` para abrirla), `8`=detenida, `9`=autorizada.

**Validaciones del driver dignas de nota:** si `2·vol·precio < importe`
divide el importe entre 10; si `2·importe < vol·precio` lo multiplica por 10;
con `AjustePAM=Si` recalcula `importe = vol·precio` cuando difieren ≥ $0.015.

### 4.4 Ejemplos verificados (BCC XOR calculado con el algoritmo real)

```
B00                                        poll (TX sin envoltura en el combo)
<STX>B0011253980<ETX><BCC=$44>             estatus de 8 posiciones
<STX>A0220000255000054825002150<ETX><BCC=$78>  venta: 25.500L $548.25 @$21.50
<STX>A010000000000000125500<ETX><BCC=$70>  cargando: importe parcial $125.50
<STX>A03\<ETX><BCC=$1D>                    posición no mapeada
T011 <BCC=$67>                             nivel de precios cash
D06222 <BCC=$73>                           setup v3
P0901000250750 <BCC=$6E>                   preset importe $250.75 pos 9
P1011000500002 <BCC=$65>                   preset 50.00 L grado 2 pos 10
@0201101040000100000 <BCC=$75>             preset v3 $400.00 producto 1
@100120 <BCC=$41>                          solicita totales v3 pos 12
<STX>@1001201000123456700000000000000000020000876543<ETX><BCC=$49>  totales v3
C1221 <BCC=$40>                            solicita total pistola
<STX>C12200001234567<ETX><BCC=$41>         total pistola 12,345.67 L
X0011002050 <BCC=$5C>                      precio contado $20.50
<STX>P0901000250750<ETX><BCC=$6F>          BCC INCORRECTO a propósito (real $6E)
```

---

## 5. Protocolo WAYNE CONSOLA (ASCII)

**No confundir con Wayne 2W** (§3, binario byte+complemento): este es el
protocolo ASCII de la consola Wayne / Wayne Fusion (`UIGASWAYNE.pas`).

### 5.1 Trama física

Mismo empaque que PAM: `<STX> payload <ETX> BCC` con **BCC = XOR** de
`payload + ETX`, ACK `#6` / NAK `#21`. Particularidad de la recepción: si el
BCC recibido no coincide, **el driver convierte la trama en NAK** y la
descarta.

### 5.2 Comandos TX (Consola I-Gas → Wayne)

| Cmd | Formato | Función | Notas |
|---|---|---|---|
| `B` | `B00` | Poll de estatus de TODAS las posiciones | Cada ciclo del Timer1 |
| `A` | `A` + pos(2) + `00` | Solicita lectura de venta | |
| `C` | `C` + pos(2) + prod(1) + `0` | Solicita totalizador de un producto | |
| `N` | `N` + maxpos(2) + modo(1) | Inicialización | modo = `ModoPrecioWayne` (def. `1`). Solo con `WayneFusion=No` o `MapeoFusion=Si` |
| `l` | `l1` | Enlace/handshake | La respuesta `l1` arranca el Timer del ciclo |
| `h` | `h` + pos(2) + `00` | Desenllave paso 1 | Refresco de enllavados de posición inactiva |
| `k` | `k` + pos(2) + `00` | Desenllave paso 2 | Sigue a `h..00` |
| `g` | `g` + pos(2) + mapa | Mapeo de productos | Un dígito de combustible por grado, relleno con `0` hasta 10 chars |
| `a` | `a` + prod(1) + tier(1) + nivel(1) + `0` + precio(4) [+ `0`] | Cambio de precio (centavos) | tier = `TierLavelWayne` (def. `0`); nivel `1`=contado / `0`=crédito; se envían ambos con 250 ms; sufijo `0` extra si `WayneFusion=Si` |
| `S` | `S` + pos(2) + `00` | Autorizar sin límite | |
| `P` | `P` + pos(2) + tipo(1) + `0` + valor(8) + grado(1) | PRESET | tipo `0`=importe (`DecimalesPresetWayne=-1` → `FormatFloat 000000.00`) / `1`=litros (`DecimalesPresetWayneLitros=3` → `00000.000`); grado `0`=todos (grado ≠ 0 requiere `SoportaSeleccionProducto=Si`) |
| `E` | `E` + pos(2) | STOP / desautorizar | También al pasar de Cargando a Autorizada inesperadamente |
| `G` | `G` + pos(2) | Reanudar | Tras varios reintentos I-Gas cambia a `R..` |
| `R` | `R` + pos(2) + `0` · `R` + pos(2) | Venta completa (`FINV`) · liberar detenida | Se distinguen por longitud |

### 5.3 Respuestas RX (Wayne → Consola)

| Resp | Layout (índices 1-based del payload) | Interpretación |
|---|---|---|
| `l1` | — | Confirma el enlace; otro valor = "Error en comunicación con CONSOLA" |
| `B00` + dígitos | UN dígito de estatus por posición desde [4] | |
| `A` | [2..3]=pos, [4]=grado activo, **[5]=no leído por el driver (hipótesis: nivel de precio, sin confirmar)**, [6..13]=volumen, [14+n..21+n]=importe, [22+n..26]=precio | n = `DigitosImporteA` (def. 0). vol÷1000, importe÷1000, precio÷1000 |
| `C` | [2..3]=pos, [4]=producto, **[5]=no leído por el driver (hipótesis: eco del "0" fijo del TX, sin confirmar)**, [6..14]=total | ÷100 (÷10 con `WayneFusion=Si` y `TDigvol=1`) |
| ACK/NAK | un byte | NAK también resulta de BCC inválido en RX |

**Estatus Wayne consola:** `0`=sin comunicación, `1`=inactivo, `2`=cargando,
`3`=fin de carga, `5`=llamando, `8`=detenida, `9`=autorizada (`7`=deshabilitada
es interno de I-Gas). Con estatus 3 y carga en curso, I-Gas sigue reportando
`2` al Bridge hasta obtener la lectura final.

**Validaciones del driver dignas de nota:** `WayneAjusteImporte` multiplica el
importe ×10; si `2·vol·precio < importe` divide entre 10; si
`importe < vol·precio·0.9` recalcula `importe = vol·precio`; en otro caso
reconcilia `volumen = importe/precio` (`AjusteWayne/2/3` modifican la lógica).

### 5.4 Ejemplos verificados (BCC XOR calculado con el algoritmo real)

```
B00                                        poll
<STX>B0012305980<ETX><BCC=$45>             estatus de 8 posiciones
A0100 <BCC=$43>                            solicita lectura pos 1
<STX>A012000025500005482502150<ETX><BCC=$4B>  lectura: 25.500L $548.25 @$21.50
C0110 <BCC=$40>                            solicita totalizador
<STX>C0110000123456<ETX><BCC=$77>          total 1,234.56 L
l1 <BCC=$5E>                               enlace
N161 <BCC=$7B>                             init 16 posiciones, modo 1
h0100 <BCC=$6A>  k0100 <BCC=$69>           desenllave
g0112000000 <BCC=$66>                      mapeo grados 1,2 pos 1
a10102050 <BCC=$65>                        precio contado $20.50
a10002050 <BCC=$64>                        precio crédito $20.50
S0100 <BCC=$51>                            autorizar sin límite
P050000250000 <BCC=$51>                    preset importe $250.00 pos 5
P0610000400002 <BCC=$62>                   preset 40.000 L grado 2 pos 6
E07 <BCC=$41>   G08 <BCC=$4C>              stop / reanudar
R090 <BCC=$68>  R10 <BCC=$50>              venta completa / liberar detenida
<STX>A0100<ETX><BCC=$44>                   BCC INCORRECTO a propósito (real $43)
```

---

## 6. Protocolo GILBARCO 2W (binario de nibbles)

Gilbarco Two-Wire clásico (`UIGASGILBARCO.pas`). Protocolo **binario**: los
datos viajan en el **nibble bajo** de cada carácter; no hay STX/ETX.

### 6.1 Byte de comando

Cada transacción inicia con **un solo byte**: `comando + posición` (la
posición 16 viaja como 0). `GtwTimeout=1000` ms, `GtwTiempoCmnd=100` ms.

| Byte | Función | Respuesta |
|---|---|---|
| `$0p` | Solicitar ESTATUS | 1 byte: nibble alto = estatus, nibble bajo = eco de la posición |
| `$1p` | AUTORIZAR / REANUDAR | sin respuesta |
| `$2p` | Anuncio de DATA BLOCK | 1 byte con nibble alto `$D` = listo; entonces I-Gas transmite el bloque carácter por carácter y confirma con un poll `$0p` |
| `$3p` | DETENER (stop) | sin respuesta |
| `$4p` | LEER VENTA en tiempo real | data block (mín. 33 bytes en 6 díg / 39 en 8 díg); reintentos por LRC: 3 |
| `$5p` | LEER TOTALIZADORES | byte de posición + registros de 30 bytes (6 díg) / 42 (8 díg); validación `(len−4) mod tam = 0` |
| `$6p` | VENTA EN PROCESO (importe) | 6/8 chars BCD **sin LRC** |
| `$F0` | PARO GENERAL (all stop) | sin respuesta |

**Estatus (nibble alto, `DameEstatus`):** `$6/$E`=Inactiva(1),
`$9/$1`=Despachando(2), `$A/$B/$3`=FinDeVenta(3), `$0`=SinCom(0),
`$7`=PistolaLevantada(5), `$C/$F`=Detenida(8), `$8`=Autorizada(9),
`$D`=lista para recibir data block.

### 6.2 Data block (TX tras `$2p`, y cuerpo de las respuestas `$4p`)

```
FF  DL  <palabras de control>  FB  LRC  F0
```

| Elemento | Cálculo (algoritmo real) |
|---|---|
| `DL` | `$E0 +` complemento a 2 del nibble bajo de `(longitud + 2)` — `DLChar` |
| `LRC` | `$E0 + ((Σ nibbles bajos XOR $F) + 1) and $F`, sobre todo lo anterior (`FF..FB`) — `LrcCheckChar`/`ValidaLRC` |
| `F0` | fin de transmisión (EOT); en RX el driver valida F0 al final y el LRC en la penúltima posición |

**Palabras de control** (identificador + datos):

| Id | Significado |
|---|---|
| `F1` / `F2` | Tipo de preset: VOLUMEN / IMPORTE |
| `F4` / `F5` | Nivel de precio 1 (contado) / 2 (crédito) |
| `F6` + `($E0+g−1)` | Grado/manguera g |
| `F7` + BCD | Precio (4 díg en 6 dígitos / 6 en 8 dígitos) |
| `F8` + BCD | Monto del preset (5/6 díg u 8) |
| `F9` + BCD | Litros (lectura o total) |
| `FA` + BCD | Importe (lectura o total) |
| `FB` | Fin de datos |

**BCD Gilbarco:** cada dígito viaja en un carácter `$E0 + dígito`, el **menos
significativo primero** (`BcdToStr` invierte; `BcdToInt` multiplica el nibble
bajo del char i por 10^(i−1)).

### 6.3 Respuestas largas (no se auto-describen → combo "Interpretar como")

- **`$4p` lectura:** I-Gas localiza las palabras `F6` (manguera = valor+1),
  `F7` (precio), `F9` (litros) y `FA` (importe) **por búsqueda**
  (`DataControlWordValue`), sin importar el offset; el resto se ignora.
  Divisores: todo ÷100 en 6 dígitos; en 8 dígitos litros e importe ÷1000.
- **`$5p` totales:** tras eliminar el byte de posición, registros de 30/42
  bytes: nibble bajo del 2º byte + 1 = manguera; `F9`+8/12 = total litros;
  `FA`+8/12 = total pesos (÷100). Hasta 3 mangueras.
- **`$6p`:** 6/8 chars BCD = importe en proceso (÷100 / ÷1000); solo se valida
  la longitud exacta.

### 6.4 Ejemplos verificados (DL y LRC calculados con el algoritmo real)

```
01 / 12 / 33 / 44 / 55 / 66 / F0           bytes de comando sueltos (TX)
23 FF E2 F2 F4 F6 E1 F8 E0 E0 E0 E5 E2 E0 FB E8 F0   preset IMPORTE $250.00 grado 2 pos 3
23 FF E3 F1 F4 F6 E1 F8 E0 E0 E0 E4 E0 FB EB F0      preset LITROS 40.00 L grado 2 pos 3
24 FF E5 F4 F6 E0 F7 E0 E5 E1 E2 FB E8 F0            precio $21.50 nivel 1 manguera 1 pos 4
24 FF E5 F5 F6 E0 F7 E0 E5 E1 E2 FB E7 F0            precio $21.50 nivel 2 manguera 1 pos 4
25 FF EC F4 FB E6 F0                                  nivel de precio contado pos 5
63 / 91 / 75 / 82 / A4 / C2 / 06 / D3     estatus RX de 1 byte (inactiva pos 3,
                                           despachando pos 1, llamando pos 5,
                                           autorizada pos 2, fin de venta pos 4,
                                           detenida pos 2, sin com pos 6,
                                           lista para data block pos 3)
A1 F6 E1 F7 E0 E5 E1 E2 F9 E0 E5 E5 E2 E0 E0 FA E5 E2 E8 E4 E5 E0 ... E2 F0
        RX $4p 6 díg (33 bytes): manguera 2, $21.50, 25.50 L, $548.25
E1 E0 E0 F9 E6 E5 E4 E3 E2 E1 E0 E0 FA E1 E2 E3 E4 E5 E6 E2 E0 ... E0 F0
        RX $5p 6 díg (34 bytes): manguera 1, 1,234.56 L, $26,543.21
E0 E5 E2 E1 E0 E0                          RX $6p 6 díg: $12.50 en proceso
23 FF E2 F2 F4 F6 E1 F8 E0 E0 E0 E5 E2 E0 FB E9 F0   LRC INCORRECTO a propósito (real E8)
```

---

## 7. Arquitectura de la herramienta (Delphi 7)

### 7.1 Archivos del proyecto `AnalizadorProtocolos`

| Archivo | Contenido |
|---|---|
| `AnalizadorProtocolos.dpr` | Proyecto |
| `UAnalizadorBase.pas` | `TParte` (Texto/Nombre/Descripcion), clase abstracta `TAnalizadorBase` y el **render común** al `TRichEdit`: encabezado (tipo + dirección TX/RX), trama con **cada parte en un color** (paleta `ColoresParte[0..7]`, fuente Courier 14 bold; prefijo/sufijo de trama en gris), desglose línea por línea en el mismo color, línea de validación (verde/rojo) y nota en naranja |
| `UProtoBennett.pas` | `TAnalizadorBennett`: normaliza entrada (tokens `<STX>/<ETX>/<ACK>/<NAK>` y hexdump con bytes de control), extrae payload, interpreta B/A/1/N/U/K/L/E/S/P/5/F/J y valida el BCC (suma) |
| `UProtoWayne2W.pas` | `TAnalizadorWayne2W`: parsea hex (con o sin espacios), detecta tramas empacadas 00 00…FF de 5/13 bytes o datos crudos de 1/5 bytes, valida los pares byte+complemento, interpreta TX por byte de control y RX según el combo "Interpretar como" (Estatus/Precio/Importe/Volumen/Totalizador) |
| `UProtoPam.pas` | `TAnalizadorPam` (**PAM 1000**): misma normalización ASCII que Bennett pero con **BCC XOR**; interpreta B/A/C/T/D/L/G/E/S/R/X/P/`@02`/`@10` y las respuestas de venta (cargando `0` / concluida / no mapeada `\`), totales v1 (`C`) y v3 (`@`); sin combo de contexto |
| `UProtoWayneCns.pas` | `TAnalizadorWayneCns` (**Wayne Consola**): mismo empaque XOR; interpreta B/A/C/l/N/h/k/g/a/S/P/E/G/R distinguiendo TX de RX por longitud; sin combo de contexto |
| `UProtoGilbarco.pas` | `TAnalizadorGilbarco` (**Gilbarco 2W**): entrada solo hexadecimal; interpreta el byte de comando suelto, el byte de comando + data block `FF..F0` (validando DL, LRC y EOT con los algoritmos reales) y decodifica las palabras de control F1..FB con BCD LSB-primero; **combo de contexto de 9 opciones** para las respuestas ($0p, $2p, $4p/$5p/$6p en 6 u 8 dígitos) |
| `UPrincipal.pas/.dfm` | Formulario con un `TPageControl`; **las pestañas y sus controles se crean en runtime** a partir de los analizadores registrados. La pestaña toma su Caption de `Analizador.Nombre`. El combo de comando es `TComboComando` (descendiente de `TComboBox`): si `Analizador.EsHexPuro=True` (Wayne 2W, Gilbarco, HongYang, Team), al **pegar** (`WM_PASTE`) o al presionar Analizar, un hex continuo sin espacios (`0106010F0000E9`) se reformatea a pares (`01 06 01 0F 00 00 E9`) vía `FormateaHexContinuo`. En protocolos ASCII/mixtos (Bennett/PAM/Wayne Consola) no se autoespacia, porque ahí un texto "todo hex" puede ser un comando ASCII real (`a101020500`, `D06222`) |

### 7.2 Contrato de la clase base

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
define contextos. Bennett, PAM y Wayne Consola no lo necesitan (sus tramas
ASCII se auto-describen); Wayne 2W y Gilbarco sí, porque una respuesta binaria
no indica a qué comando responde.

### 7.3 Cómo agregar una MARCA NUEVA (checklist para futuros chats)

1. Analizar la unidad `UIGAS<MARCA>.pas` del driver: ubicar el armado de la
   trama TX (buscar `PutString`/`PutChar`/`TransmiteComando`), la recepción
   (`TriggerAvail`/`ProcesaLinea`), el checksum, y catalogar los comandos con
   sus campos y las respuestas con sus offsets/decodificación.
2. Crear `UProto<Marca>.pas` heredando de `TAnalizadorBase` (usar
   `UProtoBennett`/`UProtoPam` como plantilla para protocolos ASCII y
   `UProtoWayne2W`/`UProtoGilbarco` para binarios).
3. Agregar la unidad al `uses` de `UPrincipal` y del `.dpr`, y una línea en
   `TfrmPrincipal.FormCreate`:
   `RegistraAnalizador(TAnalizador<Marca>.Create);`
   — la pestaña, el combo de ejemplos, el combo de contexto (si aplica), el
   botón y el RichEdit se generan solos.
4. Precargar ejemplos con checksum/empacado **calculado con el algoritmo real**
   (verificado por script), incluyendo un caso corrupto y uno no reconocido
   para probar la validación.
5. Documentar el protocolo en este MD (sección nueva al estilo de las §2–§6).

### 7.4 Formatos de entrada aceptados

- **Bennett / PAM / Wayne Consola:** texto plano (`P01005000`), tokens
  (`<STX>...<ETX>`), o hexdump con espacios (`02 50 30 ... 03 A7`; se reconoce
  como hex solo si contiene 02/03/06/15 para no confundir payloads de puros
  dígitos).
- **Wayne 2W:** hexadecimal con espacios/comas o continuo; trama empacada
  completa (5/13 bytes) o bytes de datos crudos (1/5 bytes).
- **Gilbarco 2W:** hexadecimal con espacios/comas o continuo; byte de comando
  suelto, byte de comando + data block, data block solo, o respuestas largas
  (con el combo de contexto).

### 7.5 Decisiones de diseño

- Delphi 7 / VCL estándar únicamente (`StdCtrls`, `ComCtrls`, `ExtCtrls`);
  sin DevExpress ni terceros para que compile en cualquier instalación.
- `TRichEdit` con `SelAttributes` para el coloreado; `Lines.BeginUpdate` para
  evitar parpadeo; el comando analizado se agrega al historial del combo.
- Colores reciclados con `mod 8`; prefijo/sufijo de trama (STX/ETX/BCC,
  `00 00`/`FF`) siempre en gris para distinguir envoltura de datos.
- La validación de integridad usa exactamente los algoritmos del driver
  (`CalculaBCC` suma en Bennett; **XOR** en PAM/Wayne Consola; pares
  complemento `DesEmpacaWayne`; `DLChar`/`LrcCheckChar`/`ValidaLRC` en
  Gilbarco).

---

## 8. Pendientes y siguientes pasos

- [ ] Confirmar con capturas reales el byte [4] de las respuestas Bennett `A`/`1`.
- [ ] Confirmar en campo el layout de los bytes D1..D4 de las respuestas Wayne 2W
      (I-Gas solo lee los campos documentados; el resto se muestra como
      "no interpretado").
- [x] El analizador ya no etiqueta los bytes que el driver no lee como un
      simple "No leído": cada uno trae ahora una hipótesis razonada (por
      posición, por analogía con otro comando de la misma marca, o por el
      valor fijo del TX que originó la respuesta), marcada explícitamente
      como **sin confirmar**. Aplica a PAM ([5..13] al cargar, [5] en la
      lectura final, [7] y huecos entre productos en `@10` v3), Wayne Consola
      ([5] de `A`/`C`), Wayne 2W (byte 1 y bytes 2-4 de estatus) y Gilbarco
      (tag no reconocido y bytes finales de la trama).
- [ ] Confirmar en campo (o con documentación del fabricante) el significado
      real de todos los campos anteriores; las hipótesis del punto anterior
      son solo la mejor conjetura a partir del código y los ejemplos, no un
      hecho verificado. Si se confirma o descarta alguna, actualizar tanto el
      analizador (`UProtoXxx.pas`) como este documento.
- [ ] Confirmar en campo el encabezado real de las respuestas Gilbarco `$4p`
      y `$5p` (I-Gas localiza las palabras de control por búsqueda, así que el
      analizador tolera cualquier relleno, pero el layout exacto del
      dispensario no está documentado).
- [ ] Posible mejora: modo "sesión" que recuerde el último comando TX enviado
      para auto-seleccionar el contexto de la respuesta Wayne 2W / Gilbarco.
- [ ] Posible mejora: pegar un log completo del espía y analizar trama por trama.
- [ ] Marcas candidatas a agregar (drivers existentes en I-Gas): TEAM
      (`UIGASTEAM.pas`, ya analizado parcialmente en otra sesión: comandos A1,
      totalizadores por diferencia, precisión /1000), etc.
