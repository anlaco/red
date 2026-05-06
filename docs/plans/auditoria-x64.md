# Auditoría de Seguridad/Calidad — Migración x86-64

**Rama:** `rsc2-x64`  
**Base:** `master`  
**Fecha:** Mayo 2026  
**Commits divergentes:** 177  
**Archivos modificados:** 214 (~39K líneas añadidas, ~8.6K eliminadas)

---

## 1. Arquitectura de la Migración

Estrategia: **backend completamente nuevo** (`system2/`) coexistente con el compilador antiguo (`system/`), este último sin modificar para 64-bit.

```
system/      → compilador IA-32 original (REBOL2-based, .r files)
system2/     → nuevo compilador x86-64 (Red/System-based, .reds files)
  ├── compiler.reds     → driver de compilación (1135 líneas)
  ├── rst/              → parser + type-checker Red/System
  ├── ir/               → SSA IR: graph, lowering, optimizer
  ├── x86/              → backend x86/x86-64: codegen + assembler
  ├── backend.reds      → framework machine-independent
  ├── global-reg-alloc  → allocador global de registros (3057 líneas)
  ├── simple-reg-alloc  → allocador linear-scan
  ├── linker.red        → linker (ELF32, ELF64, PE)
  ├── loader.red        → preprocessor (#include, #define, #if)
  ├── formats/          → emisores de formato: ELF64.red, PE.red
  └── runtime/          → runtimes OS-specific (linux64.reds, etc.)
```

### Pipeline de Compilación

```
Source → loader (preprocessing) → parser (RST AST)
       → type-checker → IR graph (SSA + phi nodes)
       → lowering → optimizer (peephole)
       → backend (instruction selection → regalloc → frame layout)
       → assembler (binary encoding) → linker (ELF64/PE)
```

---

## 2. Hallazgos de Seguridad

### 2.1 CRÍTICOS (P0)

#### P0-01: Heap overflow por allocate sin +1 + strcpy
**Archivo:** `runtime/simple-io.reds:2016-2017`

```reds
act-str: allocate length? cstr      ; falta +1 para null terminator
strcpy(act-str, cstr)               ; escribe length? cstr + 1 bytes
```

**Impacto:** Overflow de 1 byte en el heap.  
**Fix:** `allocate length? cstr + 1` o usar `memcpy` + null explícito. Además, restaurar `strncpy` en vez de `strcpy`.

#### P0-02: strupr no es POSIX
**Archivo:** `runtime/simple-io.reds:2017`

`strupr` es extensión MSVC, no existe en glibc/musl. El código antiguo usaba `to-upper` propio.  
**Impacto:** Error de compilación/link en Linux-64.

---

### 2.2 ALTOS (P1)

#### P1-01: OOB read en escape-url-chars
**Archivo:** `runtime/datatypes/string.reds:195-213`

La tabla `escape-url-chars` tiene 128 bytes. `decode-url-char` indexa con bytes de URL sin validar `< 128`:
```reds
v1: 1 + as-integer p/2           ; p/2 puede ser 0x00-0xFF
code: escape-url-chars/v1        ; OOB read si v1 > 128
```
URL maliciosa `%FF%FF` lee fuera de la tabla.  
**Fix:** Validar `p/2 <= MAX_URL_CHARS` antes de indexar.

#### P1-02: Buffer subdimensionado en binary/make-at con /dup
**Archivo:** `runtime/datatypes/binary.reds:1135`

```reds
make-at as red-value! buffer cnt  ; debería ser: len * cnt
```
Para inserciones con `/dup`, el buffer se subdimensiona catastróficamente.  
**Impacto:** Corrupción de heap al escribir datos más allá del buffer asignado.

#### P1-03: compare-call repunta offset de serie a memoria externa
**Archivo:** `runtime/datatypes/block.reds:1242-1245`

```reds
s1/offset: value1                 ; repunta a datos externos
s2/offset: value2
```
Si el GC se ejecuta durante la comparación, seguirá un puntero wild. Se depende de que `collector/active? = no`.  
**Fix:** Restaurar `copy-memory` o añadir guarda explícita.

#### P1-04: Integer overflow en alloc-bytes (enbase)
**Archivo:** `runtime/natives.reds:1584-1587`

```reds
; base64: 4 * len / 3 + (2 * (len / 32) + 5)
; base2:  8 * len + (2 * (len / 8) + 4)
```
Para `len` cerca de INT_MAX, `4 * len` o `8 * len` overflow → buffer pequeño → escritura masiva OOB.

#### P1-05: series/size * 2 overflow en expand-series
**Archivo:** `runtime/allocator.reds:788`

```reds
new-sz: series/size * 2
```
En 64-bit, series pueden exceder 2GB. `* 2` overflow → buffer subdimensionado.

#### P1-06: c * width overflow en sort (múltiples ubicaciones)
**Archivos:** `runtime/sort.reds:166,184,419-422`

`grail-search-left`, `grail-search-right`, `mergesort` usan `c * width` con `integer!` (32-bit). Para `width=32` (64-bit cell) y arrays grandes, overflow → puntero wild.

#### P1-07: allocate/free nativos son stubs
**Archivo:** `system2/runtime/lib-natives.reds:14-24`

```reds
allocate: func [size [integer!] return: [byte-ptr!]][;TBD]
free: func [p [byte-ptr!]][;TBD]
```
En modo `use-natives? = yes` (MVP Linux-64 estático), cualquier `allocate`/`free` ejecuta UB.

#### P1-08: Sin null-check tras malloc en todo system2/
**Archivo:** `system2/compiler.reds:61-63` y ubicuo

```reds
#define xmalloc(type) [as type malloc size? type]
```
`malloc` puede retornar NULL → segfault sin mensaje. Ubicuo en ~52 archivos `.reds`.

#### P1-09: Posible regresión en detección de doble apóstrofe
**Archivo:** `runtime/lexer.reds:1486`

```reds
; Antiguo: if all [p/0 = #"'" p/1 = #"'"]  → detecta ''
; Nuevo:   if any [p + 1 = e p/2 = #"'"]  → semántica cambiada
```
`p + 1 = e` (fin de buffer) no tiene equivalente lógico con la detección antigua.

---

### 2.3 MEDIOS (P2)

| ID | Issue | Archivo:Línea |
|----|-------|---------------|
| P2-01 | `as-integer` trunca diffs de punteros 64→32 bits | `allocator.reds:799`, `sort.reds:123` |
| P2-02 | `forall-next?` incrementa head siempre (posible off-by-one) | `natives.reds:3679-3680` |
| P2-03 | `apply?` eliminado en verificación de refinamientos | `interpreter.reds:915` |
| P2-04 | GC toggle no es exception-safe en `enbase` | `natives.reds:1580-1591` |
| P2-05 | `cnt * part` overflow en string/block insert | `string.reds:~2536`, `block.reds:~1504` |
| P2-06 | `int/value <= FFh` sin guarda para negativos | `binary.reds:1122` |
| P2-07 | Sin path traversal protection en `#include` | `system2/loader.red:296-326` |
| P2-08 | Sin allowlist en `merge-runtime.red` | `merge-runtime.red:10-12` |
| P2-09 | Shell injection vía `system()`/`_wsystem()` | `red.r:95,105,128`, `compiler.r:82` |
| P2-10 | `mempool/destroy` es no-op (leak intencionado) | `utils/mempool.reds:51-55` |
| P2-11 | `mach-instr!` variable-length sin validación de `n` | `backend.reds:1052-1058` |
| P2-12 | `align-up` macro: overflow si `i` cerca de MAX_INT | `compiler.reds:91-97` |
| P2-13 | Call relocation: offset 32-bit puede no bastar en x64 | `x86/codegen.reds:2912` |

---

### 2.3-bis Hallazgos específicos en `system2/` (revisión de los 6 commits locales)

Esta subsección complementa los hallazgos previos —que se centran en el runtime legacy— con la revisión independiente de los 6 commits locales sobre `system2/` (rama `rsc2-x64` adelantada vs `upstream/rsc2`):
`580fea394`, `2fed550d0`, `73dd024c1`, `a5bafc5b0`, `7c7256eec`, `5234d30f2`.

#### CRÍTICOS

##### P0-S1: Regresión IA-32 en `mov-r-i` zero-case
**Archivo:** `system2/x86/assembler.reds:714`

```reds
mov-r-i: func [r [integer!] imm [integer!]][
    if zero? imm [
        xor-r-r r r REX_W      ;-- antes: rex-byte
        exit
    ]
    ...
]
```

Forzar `REX_W` literal hace que en IA-32 (`addr-size=4`) se emita el byte `0x48` antes del `xor`. En modo 32-bit `0x48` decodifica como **`dec eax`**, no como prefijo REX → corrompe el código emitido.

Llamadores en rutas IA-32: `assemble-op` para catch/throw/atomic-math/stack-alloc/push-i (asm:1486, 1900, 1934, 2056, 2087).

**Fix:** `xor-r-r r r asm/rex-byte` (variante address-size-aware) o `xor-r-r r r NO_REX` (en x64, `xor eax,eax` ya zero-extiende a RAX, no requiere REX.W).

##### P0-S2: Stubs de float que mienten silenciosamente
**Archivo:** `system2/runtime/lib-natives.reds:165-176`

```reds
sqrt:    func [x [float!] return: [float!]][0.0]
pow:     func [x [float!] y [float!] return: [float!]][x]
log-10:  func [x [float!] return: [float!]][0.0]
log-e:   func [x [float!] return: [float!]][0.0]
fmod:    func [x [float!] y [float!] return: [float!]][x]
floor:   func [x [float!] return: [float!]][x]
ceil:    func [x [float!] return: [float!]][x]
ldexp:   func [x [float!] exp [integer!] return: [float!]][x]
strtod:  func [s [c-string!] endptr [int-ptr!] return: [float!]][0.0]
sprintf: func [s [c-string!] fmt [c-string!] return: [integer!]][0]
sscanf:  func [s [c-string!] fmt [c-string!] return: [integer!]][0]
```

Cualquier programa que toque floats compilará y ejecutará con resultados erróneos sin un solo warning. Para `hello.reds` no afecta, pero estos deberían `prin "FLOAT-STUB"` + `quit 1` (fail-loud) o ser implementados con `fyl2x`/`fsqrt` en x87.

##### P0-S3: `N_STACK_POP_ALL` eliminó el `emit-instr` por error
**Archivo:** `system2/x86/codegen.reds:1768-1770`

```reds
N_STACK_POP_ALL [
    kill cg (either target/addr-size = 8 [x64_REG_ALL][x86_REG_ALL])
    ;; emit-instr cg I_POP_ALL or M_FLAG_FIXED    ← esta línea fue eliminada
]
```

El diff de los commits locales eliminó la línea `emit-instr cg I_POP_ALL or M_FLAG_FIXED` del handler `N_STACK_POP_ALL`. Solo quedó el `kill cg` (bookkeeping del regalloc). Consecuencias:

- Tras un `I_PUSH_ALL` en x64 (que sí guarda R8-R15 manualmente), el `I_POP_ALL` nunca emite las instrucciones de restauración de registros.
- Stack corrupto tras cualquier `call` que use `pusha`/`popa` en x64.
- Crash seguro en cualquier programa que llame funciones externas via `#import` o use `system/cpu/*`.

**Fix:** restaurar la línea `emit-instr cg I_POP_ALL or M_FLAG_FIXED` entre el `kill` y el cierre del bloque.

#### ALTOS

##### P1-S1: `setc` REX-prefix bound incorrecto
**Archivo:** `system2/x86/assembler.reds:652`

```reds
if all [target/addr-size = 8 reg >= 5][rex: rex or REX_BYTE]
```

Debería ser `reg >= 4`. Con `>= 5`, un `setc` a RSP (reg=4) en modo 64-bit codifica el operando como `AH` en vez de `SPL`. RSP raramente recibe `setc` en flujos generados, pero el encoding es incorrecto.

##### P1-S2: Backpatch hardcoded en `I_CATCH` close-branch
**Archivo:** `system2/x86/assembler.reds:1894`

```reds
change-at-32 program/code-buf/data pos + 27 asm/pos - pos - 25
```

Los desplazamientos `27` y `25` cuentan bytes asumiendo encoding IA-32. La rama open-catch ya emite `add-r-i` y `mov-r-i` con prefijos REX para x64, así que la longitud real de la secuencia difiere.

**Impacto:** el `change-at-32` patcheará a un offset incorrecto dentro de la instrucción `add eax, <offset>` del trampolín PIC → catch/throw rotos en x64.

**No detectado por el CI** porque `hello.reds` no usa `catch`/`throw`.

**Fix:** parametrizar 27/25 en función de `target/addr-size`, o `assert target/addr-size = 4` y abrir issue para implementar correctamente x64-catch.

##### P1-S3: `emit-syscall` sin bound-check de argumentos
**Archivo:** `system2/x86/codegen.reds:1542-1549`

```reds
reg: switch n [
    0 [x64_RDI]
    1 [x64_RSI]
    2 [x64_RDX]
    3 [x64_R10]
    4 [x64_R8]
    5 [x64_R9]
]
```

Sin branch `default`. Para `n ≥ 6`, `switch` retorna 0 → `use-reg-fixed cg e/dst 0` (RAX, ya pinned al syscall-num) → corrupción del registro de número de syscall.

Linux limita syscalls a 6 args, así que en práctica no ocurre, pero un `assert n < 6` es trivial y defensivo.

##### P1-S4: `inject-runtime` añade `***_start` como statement con semántica de llamada
**Archivo:** `system2/compiler.red:170`

```reds
inject-runtime: func [src [block!] /local rt-file][
    rt-file: rejoin [rs-runtime-dir %common.reds]
    insert skip src 2 reduce [to-issue "include" rt-file]
    append src [***_start ***-on-quit 0 0]
]
```

En Red/System un identificador suelto **es** una llamada a función (sin paréntesis). Si el toplevel `src` se materializa como cuerpo del entry y el usuario también define `***_start: func [...]` (caso de `tests/x64/hello.reds`), entonces `***_start` aquí lo *llama*.

En `hello.reds` funciona porque ***_start tiene `/local` solamente y no recurse. Pero:
- Si se redefine con argumentos requeridos sin refinements, fallaría en compile-time.
- Si recurse (caso patológico pero válido en Red/System), bucle infinito.

**Fix sugerido:** verificar la intención. Si era anti-DCE para preservar el símbolo `***_start`, debería ser `:***_start` (referencia, no llamada) y comentarlo. Si era llamada explícita, documentar el porqué en el commit y valor por defecto del wrapper.

#### MEDIOS

| ID | Issue | Archivo:Línea |
|----|-------|---------------|
| P2-S1 | `emit-q` sign-extiende siempre (`q < 0` ⇒ high=`-1`); imposible emitir imm64 unsigned `0x80000000..0xFFFFFFFF` zero-extended | `system2/x86/assembler.reds:128` |
| P2-S2 | `linux64.reds` define `quit` solo si `use-natives?=yes`; `start.reds` AMD64 branch lo invoca con la misma guarda — funciona, pero acoplamiento frágil ante refactor | `system2/runtime/linux64.reds:25-29`, `start.reds:148` |
| P2-S3 | `PT_LOAD RX` con `p_filesz=data-offset` mapea padding como ejecutable; ahorrable acotando a `code-offset+code-size` | `system2/formats/ELF64.red:103-106` |
| P2-S4 | `e_shentsize=64` con `e_shnum=0`; algunos verificadores estrictos esperan `e_shentsize=0` cuando no hay sections | `system2/formats/ELF64.red:74` |
| P2-S5 | `emit-syscall` después de `def-vreg cg rax-tmp x64_RAX` hace `kill cg x64_REG_ALL`; orden funciona por contrato del regalloc, pero conviene documentar la invariante "kill no aplica a vregs definidos en el mismo `i`" | `system2/x86/codegen.reds:1521-1526` |
| P2-S6 | `e_entry`/`p_vaddr` se emiten como `to-bin32 (base + offset) + to-bin32 0`; si `base-address` ≥ `0x100000000` la parte alta queda perdida sin error | `system2/formats/ELF64.red:51-58, 78-99` |

#### BAJOS

| ID | Issue | Archivo |
|----|-------|---------|
| P3-S1 | `negate i` reemplazado por `0 - i` en `prin-int` sin justificación en commit; sospecha de workaround no documentado por ausencia de `negate` en modo `use-natives?=yes` | `system2/runtime/lib-natives.reds:117` |
| P3-S2 | Tabla de mapeo `os-type` (1=Windows, 2=Linux/Unix) usa enteros mágicos; preferible enum nombrado | `system2/compiler.reds:533, 1034-1043` |
| P3-S3 | `prin-2hex` documentado como añadido en commit `5234d30f2` pero la implementación reescribe `i` ; el `ret: i` previo al loop preserva el valor de retorno correctamente, no es bug — solo confunde a lectura rápida | `system2/runtime/lib-natives.reds:149-163` |
| P3-S4 | El test `tests/x64/build.sh` no verifica el código de salida ni hace `diff` de output; CI sí lo verifica, pero el script local es trivialmente engañoso | `system2/tests/x64/build.sh` |
| P3-S5 | Asimetría cosmética: `pop-r` pasa `NO_REX` mientras `push-r` pasa `rex-r r REX_B`. **Encoding idéntico** porque `emit-b-r-rex` aplica internamente `rex or rex-r r REX_B` (asm:178), pero la incongruencia confunde a la lectura. Sugerido: alinear ambos a `rex-r r REX_B` | `system2/x86/assembler.reds:550-551` vs `:567-568` |

---

### 2.4 BAJOS (P3)

| ID | Issue | Archivo |
|----|-------|---------|
| P3-01 | `count-chars` cache reset → regresión de rendimiento en parse | `lexer.reds:393` |
| P3-02 | GUI error alert eliminada (intencional para x64 MVP) | `stack.reds` |
| P3-03 | Sin verificación de integridad en rs-runtime.red generado | `merge-runtime.red` |
| P3-04 | CI descarga binarios HTTP sin hash pinning | `build-rsc.yml:17-22` |
| P3-05 | `MAX_INT: 2147483647` no ajustado para 64-bit | `common.reds:99` (ambos) |

---

## 3. Análisis de Madurez por Componente

| Componente | Madurez | Riesgos clave |
|------------|---------|---------------|
| Parser RST | Alta | Bien probado, sin hallazgos mayores |
| Type-checker | Alta | Inferencia correcta, promoción de tipos OK |
| IR SSA | Alta | Phi placement, lowering correctos |
| Optimizer | Media | Constant folding OK, falta más patrones (TBDs) |
| x86 Assembler | Alta | REX encoding correcto, ModR/M/SIB bien |
| x86 Codegen | Alta | Selección de instrucciones correcta |
| Reg Allocator | Media | Global + linear scan, algunos TBDs sin implementar |
| Formato ELF64 | Alta | Headers correctos, padding a página OK |
| Runtime (nuevo) | Media-Baja | linux64.reds funciona, pero allocate/free son stubs |
| Runtime (viejo) | Media | Muchos integer! usados para 64-bit, sort reescrito |
| Linker/Loader | Media | Funciona, falta path traversal protection |

---

## 4. Pruebas de Verificación

### 4.1 CI `linux-x64.yml` — Funcional

- Compila hello.reds con `red-view -c -t Linux-64`
- Verifica salida ELF64 con `file` command
- Ejecuta binario → output esperado: "hello, x64 linux"
- Estado: ✅ PASS

### 4.2 Test Manual `./hello`

- Binario ELF64 pre-compilado existe
- Permisos de ejecución: requiere `chmod +x`
- Output: "hello, x64 linux"
- Estado: ✅ PASS

### 4.3 Áreas sin cobertura de tests

- **Sort 64-bit:** No hay tests con arrays >2GB (integer overflow latente)
- **URL decode/encode:** No hay tests con bytes >127 (OOB en tablas)
- **allocate/free nativos:** No hay tests (son stubs)
- **Regresiones lexer:** Doble apóstrofe sin tests específicos

---

## 5. Recomendaciones

### Inmediatas (esta sesión)
1. ✅ Documentar auditoría → este documento
2. Reconstruir `rs-runtime.red` desde runtime/ → asegurar que linux64.reds esté incluido
3. Compilar `red.red` → validar el toolchain completo
4. Compilar `hello.reds` con el Red recién compilado → validación end-to-end

### Próxima sesión (Issue)
1. Fix `strcpy` → `strncpy` + allocate +1
2. Fix `strupr` → función propia `to-upper`
3. Fix OOB en `escape-url-chars` (bounds check)
4. Fix `binary/make-at` con /dup (allocate len * cnt)
5. Fix `compare-call` (restaurar copy-memory o guarda GC)
6. Implementar stubs `allocate`/`free` nativos
7. Añadir guards anti-overflow en multiplicaciones de tamaños
8. Añadir null checks tras malloc en system2/

### Medio plazo
- Migrar `integer!` para tamaños a un tipo más ancho en el runtime
- Añadir path traversal protection en `#include`
- Firmar/hashear binarios descargados en CI
- Expandir cobertura de tests para edge cases 64-bit

---

## 6. Estado del MVP

El Minimum Viable Product (M3 — ver `plan-mvp-x64.md`) está **funcional pero frágil**:

- ✅ Compilación de Red/System básico a ELF64
- ✅ Syscalls Linux (write, exit)
- ✅ Sin dependencia de libc (MVP estático puro)
- ⚠️ allocate/free no implementados
- ⚠️ Sin GUI (GTK bloque eliminado de definiciones)
- ⚠️ Sin soporte Windows x64 (solo Linux-64 probado)

---

*Documento generado automáticamente por auditoría de agentes — revisar antes de merge.*
