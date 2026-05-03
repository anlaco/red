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
