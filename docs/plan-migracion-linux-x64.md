# Plan de Migración Red/System a Linux x86-64

**Fecha:** 26 abril 2026  
**Modelo de IA utilizado:** GLM-5.1 (cloud) via Ollama  
**Rama analizada:** `rsc2-x64` (commit `983df73ff` — idéntica a `upstream/rsc2`)  
**Autor del análisis:** Asistente IA (GLM-5.1) con revisión de equipo Anlaco  

---

## 1. Contexto

Nos han encargado subir Red a 64 bits en Linux. El equipo principal (Nenad/Xie Qingtian) se ocupa de Windows. Necesitamos entender cómo están haciendo la migración para replicar su enfoque en Linux.

---

## 2. Descubrimientos

### 2.1 Estrategia del equipo: compilador nuevo desde cero

El equipo NO está adaptando el compilador viejo (`system/`). Está construyendo **un compilador completamente nuevo** (`system2/`) con arquitectura multi-paso moderna. La rama `rsc2-x64` contiene 172 commits (julio 2024 — julio 2025), prácticamente todos de Xie Qingtian.

**Pipeline viejo (32-bit solo):**
```
Source → Rebol Preprocessor → Compilador monolítico → Emisión directa x86 bytes → PE/ELF Linker
```

**Pipeline nuevo (32-bit Y 64-bit):**
```
Source → Loader → RST Parser → Type Checker
  → SSA IR Graph → IR Lowering → Machine IR
  → Register Allocation (Simple o Graph-Coloring Global)
  → Code Generation (x86 o x64)
  → Binary Assembly (con REX prefixes para x64)
  → PE/ELF Linker
```

Arquitectura del nuevo compilador (~32.700 líneas):

| Componente | Archivo | Líneas | Propósito |
|---|---|---|---|
| Parser | `rst/parser.reds` | 3.592 | Parsea Red/System a AST |
| Type Checker | `rst/type-checker.reds` | 1.339 | Análisis semántico |
| Type System | `type-system.reds` | 825 | Definiciones de tipos, tamaños |
| IR SSA | `ir/ir-graph.reds` | 2.542 | Representación intermedia SSA |
| IR Lowering | `ir/lowering.reds` | 879 | Baja SSA IR a machine IR |
| Optimizer | `ir/optimizer.reds` | 408 | Constant folding, dead code |
| Backend | `backend.reds` | 1.998 | Infraestructura backend |
| Simple Reg Alloc | `simple-reg-alloc.reds` | 796 | Allocator naive |
| Global Reg Alloc | `global-reg-alloc.reds` | 3.056 | Graph-coloring (último trabajo) |
| x86 Codegen | `x86/codegen.reds` | 2.789 | Generación código x86 Y x64 |
| x86 Assembler | `x86/assembler.reds` | 2.489 | Encoding binario con REX |
| Compiler Driver | `compiler.reds` | 1.121 | Orquestación, selección de target |
| Linker | `linker.red` | 312 | Resolución de símbolos |
| Loader | `loader.red` | 444 | Carga de fuentes |
| Config | `config.red` | 263 | Definiciones de targets |
| PE Format | `formats/PE.red` | 1.319 | PE32 y PE32+ (64-bit Windows) |
| ELF Format | `formats/ELF.red` | 1.297 | **Solo 32-bit** |
| Runtime | `runtime/*.reds` | ~2.700 | OS-specific runtime |

### 2.2 Qué tiene el equipo para x86-64

El compilador nuevo tiene **soporte dual x86/x64** en el backend compartido:

| Componente | Estado | Detalle |
|---|---|---|
| Registros x64 (RAX-R15, XMM0-15) | ✅ Completo | `codegen.reds:36-76` |
| Assembler con REX prefixes | ✅ Completo | `assembler.reds` maneja REX_W/R/X/B |
| Calling Convention Windows x64 | ✅ Completo | `x64-win-cc` (RCX, RDX, R8, R9 + shadow) |
| Calling Convention interna x64 | ✅ Completo | `x64-internal-cc` (RSI, RDX, RCX, R8, R9) |
| PE32+ (Windows 64-bit) | ✅ Completo | `formats/PE.red` con `optional_header64` |
| Target MSDOS-64/AMD64 | ✅ Completo | `config.red:52-58` |
| Init target x86-64 | ✅ Completo | `compiler.reds:1064-1091` (addr-width=64, addr-size=8, rex-byte=REX_W) |

### 2.3 Qué FALTA para Linux x64

| Componente | Estado | Archivo:Línea | Detalle |
|---|---|---|---|
| **Calling Convention SysV** | ❌ Faltante | `codegen.reds` | Linux usa RDI,RSI,RDX,RCX,R8,R9; el equipo solo hizo Windows x64 |
| **ELF64** | ❌ Faltante | `formats/ELF.red` | Solo existe `elfclass32`; no hay `Elf64_Ehdr`, `EM_X86_64`, relocalizaciones x64 |
| **Linker ELF** | ❌ Stub | `linker.red:13` | `ELF: context [build: func [job][]]` — código real comentado |
| **Target Linux-64** | ❌ Faltante | `config.red` | Solo existe `MSDOS-64`; Linux usa `ld-linux.so.2` (32-bit) |
| **Runtime Linux x64** | ❌ Faltante | `runtime/linux.reds` | Syscalls 32-bit (write=4, exit=1); x64 necesita (write=1, exit=60) con `syscall` |
| **Startup code x64** | ❌ Faltante | `runtime/start.reds` | Usa `pop` para argc (i386 ABI); x64 necesita `%rsp` parsing |
| **Type system: punteros** | ❌ Bug | `type-system.reds:392` | `RST_TYPE_PTR` hardcodeado a 4 bytes, debería usar `addr-size` |
| **Inmediatos 64-bit** | ❌ Incompleto | `codegen.reds:2778` | Comentario `;TBD handle 64bit value` |
| **PIC** | ❌ Faltante | — | Necesario para .so en Linux x64 |
| **CI x64** | ❌ Faltante | `.github/` | Solo i386/ubuntu:18.04 |

### 2.4 Detalle del bug en type-system.reds

El puntero está hardcodeado a 4 bytes independientemente del target:

```reds
; type-system.reds línea ~392
#define RST_TYPE_PTR [4]   ; ← SIEMPRE 4, debería ser target/addr-size
```

Esto hace que en 64-bit los punteros se traten como si ocuparan 4 bytes cuando realmente ocupan 8.

### 2.5 Detalle del linker ELF

El linker tiene el módulo ELF desactivado:

```reds
; linker.red:13-14
ELF: context [build: func [job][]]     ; ← stub vacío
;ELF: #include %ELF.red               ; ← código real comentado
```

PE está activo y funcional (`PE: #include %formats/PE.red`).

### 2.6 Detalle del runtime Linux 32-bit vs 64-bit

Syscalls actuales (32-bit):
```reds
; runtime/linux.reds
#syscall [
    write: 4 [          ; ← x86: write=4
        fd      [integer!]
        buffer  [c-string!]
        count   [integer!]
        return: [integer!]
    ]
    quit: 1 [           ; ← x86: exit=1
        status [integer!]
    ]
]
```

En x86-64 Linux los números son diferentes y se usa `syscall` en vez de `int 80h`:
- write = 1, exit = 60
- Argumentos en RDI, RSI, RDX, R10, R8, R9 (no en la pila)

### 2.7 Startup code

`start.reds` usa `pop` para obtener argc del stack, que es la convención i386 del kernel al entry point. En x86-64, el kernel coloca argc en `(%rsp)` y argv en `8(%rsp)`.

### 2.8 Línea temporal del equipo

| Período | Trabajo |
|---|---|
| Jul-Ago 2024 | Parser, type checker, SSA IR |
| Ago-Sep 2024 | IR lowering, machine IR, simple reg alloc, x86 emission |
| Oct 2024 | x86 backend, linking, C calls, #import, system/ parsing |
| **Oct-Nov 2024** | **REX prefix, PE32+, x86-64 code generation** (milestone clave) |
| Dic 2024 | Struct values, switch/case, catch/throw |
| Ene-Mar 2025 | Parse completo, runtime extraction, CI |
| Abr-Jun 2025 | Float32, enum, atomic ops, system/cpu, function pointers, subroutine! |
| Jul 2025 | Global register allocator (trabajo más reciente, posiblemente activo) |

El equipo implementó Windows x64 hace ~8 meses (oct-nov 2024) y desde entonces se ha centrado en completar el compilador. Linux x64 no ha sido prioridad para ellos.

---

## 3. Plan Propuesto

### Fase 0: Bug fixes críticos del type system

**Prioridad:** CRÍTICA — todo lo demás depende de esto

1. Corregir `RST_TYPE_PTR` en `system2/type-system.reds:392` para que use `target/addr-size` en vez del valor hardcodeado 4
2. Verificar que los cálculos de tamaño de struct funcionan correctamente cuando `addr-size = 8`
3. Verificar que `type-system/init` propaga correctamente `addr-size` al type system

**Archivos:** `type-system.reds`  
**Complejidad:** Baja

### Fase 1: Calling Convention SysV AMD64 ABI

**Prioridad:** Alta — necesaria para cualquier código Linux x64

4. Crear `x64-sysv-cc` context en `system2/x86/codegen.reds` (después de `x64-internal-cc:449`):
   - Parámetros enteros: RDI, RSI, RDX, RCX, R8, R9 (6 registros)
   - Parámetros float: XMM0-XMM7 (8 registros)
   - Retorno entero: RAX (+ RDX para valores de 128-bit)
   - Retorno float: XMM0 (+ XMM1)
   - Callee-saved: RBX, RBP, R12-R15
   - Sin shadow space (diferencia clave con Windows)

5. Modificar `x64-cc/make` en `codegen.reds:468-600` para seleccionar entre:
   - `x64-win-cc` cuando OS = Windows
   - `x64-sysv-cc` cuando OS = Linux/FreeBSD/NetBSD/Syllable

6. Modificar `compiler.reds:init-target:1064-1091` para:
   - Inicializar `x64-sysv-cc` además de `x64-win-cc`
   - Pasar info del OS al code generation para seleccionar la convención correcta

**Archivos:** `x86/codegen.reds`, `compiler.reds`  
**Complejidad:** Media

### Fase 2: Formato ELF64

**Prioridad:** Alta — sin esto no se pueden generar binarios Linux x64

7. Añadir a `system2/formats/ELF.red`:
   - Constantes: `elfclass64 = 2`, `EM_X86_64 = 62 (0x3E)`
   - Struct `Elf64_Ehdr`: e_ident(16) + e_type(2) + e_machine(2) + e_version(4) + e_entry(**8**) + e_phoff(**8**) + e_shoff(**8**) + e_flags(4) + e_ehsize(2) + e_phentsize(2) + e_phnum(2) + e_shentsize(2) + e_shnum(2) + e_shstrndx(2) = 64 bytes
   - Struct `Elf64_Phdr`: p_type(4) + p_flags(4) + p_offset(**8**) + p_vaddr(**8**) + p_paddr(**8**) + p_filesz(**8**) + p_memsz(**8**) + p_align(**8**) = 56 bytes
   - Relocalizaciones x86-64: `R_X86_64_32`, `R_X86_64_32S`, `R_X86_64_64`, `R_X86_64_PC32`, `R_X86_64_PLT32`, `R_X86_64_GOTPCREL`
   - Lógica condicional para usar estructuras 32-bit o 64-bit según target

8. Descomentar `ELF: #include %ELF.red` en `system2/linker.red:14` y eliminar el stub de la línea 13

9. Adaptar el linker para relocalizaciones ELF64:
   - Los campos de dirección en ELF64 son de 8 bytes (no 4)
   - Tipos de relocalización diferentes para x86-64

**Archivos:** `formats/ELF.red`, `linker.red`  
**Complejidad:** **Alta** — la fase más pesada del plan

### Fase 3: Runtime Linux x64

**Prioridad:** Alta — necesaria para ejecución

10. Parametrizar `system2/runtime/linux.reds` o crear `linux64.reds`:
    - Syscalls x86-64: usar instrucción `syscall` en vez de `int 80h`
    - Números: write=1, exit=60, read=0, mmap=9, writev=20, etc.
    - Convención: RAX=syscall#, RDI=arg1, RSI=arg2, RDX=arg3, R10=arg4, R8=arg5, R9=arg6

11. Parametrizar `system2/runtime/start.reds` o crear `start64.reds`:
    - Entry point `_start` para ELF64
    - argc en `(%rsp)`, argv en `8(%rsp)` (no `pop`)
    - Alineación de stack a 16 bytes (requerido por SysV ABI antes de `call`)
    - Llamada a `__libc_start_main` con 7 argumentos (main, argc, argv, init, fini, rtld_fini, stack_end)

12. Actualizar `rs-runtime.red` para incluir el runtime de 64 bits cuando el target sea AMD64

**Archivos:** `runtime/linux.reds`, `runtime/start.reds`, `rs-runtime.red`  
**Complejidad:** Media

### Fase 4: Configuración de targets Linux x64

**Prioridad:** Media — agrupa todo lo anterior

13. Añadir a `system2/config.red`:

```reds
Linux-64 [
    OS: 'Linux
    format: 'ELF
    type: 'exe
    target: 'AMD64
    dynamic-linker: "/lib64/ld-linux-x86-64.so.2"
    stack-align-16?: yes
]
Linux-64-GTK [
    OS: 'Linux
    format: 'ELF
    type: 'exe
    target: 'AMD64
    dynamic-linker: "/lib64/ld-linux-x86-64.so.2"
    stack-align-16?: yes
    sub-system: 'GUI
]
Linux-64-musl [
    OS: 'Linux
    format: 'ELF
    type: 'exe
    target: 'AMD64
    dynamic-linker: "/lib/ld-musl-x86_64.so.1"
    stack-align-16?: yes
]
```

**Archivos:** `config.red`  
**Complejidad:** Baja

### Fase 5: Huecos en code generation

**Prioridad:** Media — se puede trabajar en paralelo con Fases 1-3

14. Implementar handling de inmediatos 64-bit en `codegen.reds:2778`:
    - `movabs` (REX.W + B8+rd + imm64) para valores full 64-bit
    - Sign-extension con `mov reg, imm32` cuando el inmediato cabe en 32 bits con signo

15. Implementar `integer64!` en targets de 32-bit en `lowering.reds:401,438` (marcados como TBD)

16. PIC (Position-Independent Code) para Linux x64:
    - RIP-relative addressing para acceso a datos globales
    - GOT (Global Offset Table) para acceso a símbolos externos
    - Necesario para shared libraries (.so)

**Archivos:** `x86/codegen.reds`, `ir/lowering.reds`  
**Complejidad:** Media-Alta

### Fase 6: Testing e integración

**Prioridad:** Final — validación

17. Compilar un "hello world" en Red/System con target `Linux-64`
18. Verificar el binario con `readelf -h`, `readelf -l`, `readelf -S`, `objdump -d`
19. Ejecutar el binario en un sistema Linux x64
20. Añadir build de CI para x64 en `.github/workflows/`
21. Tests de regresión para asegurar que 32-bit sigue funcionando
22. Compilar el compilador mismo en modo 64-bit como prueba de fuego

---

## 4. Dependencias entre fases

```
Fase 0 (Type system fix) ← PRERREQUISITO
   │
   ├→ Fase 1 (SysV ABI)      ─┐
   ├→ Fase 2 (ELF64)          ├→ Fase 4 (Config targets) → Fase 6 (Testing)
   └→ Fase 3 (Runtime x64)   ─┘
                  │
                  └→ Fase 5 (Codegen gaps) → Fase 6 (Testing)
```

- **Fases 1, 2, 3 son independientes** entre sí — se pueden trabajar en paralelo
- **Fase 0** es prerrequisito de todas
- **Fase 4** necesita las Fases 1-3 para poder probar nada
- **Fase 5** se puede empezar en paralelo con 1-3 pero completa huecos del codegen
- **Fase 6** es validación final

---

## 5. Estimación de esfuerzo

| Fase | Archivos a modificar/crear | Complejidad | Impacto |
|---|---|---|---|
| 0 — Type system fix | 1 archivo | Baja | Crítico |
| 1 — SysV ABI | 1-2 archivos | Media | Alto |
| 2 — ELF64 | 2 archivos | **Alta** | Alto |
| 3 — Runtime x64 | 2-3 archivos | Media | Alto |
| 4 — Config targets | 1 archivo | Baja | Medio |
| 5 — Codegen gaps | 2 archivos | Media-Alta | Medio |
| 6 — Testing | CI + tests | Media | Validación |

**Fase 2 (ELF64) es la tarea más pesada** — el archivo `ELF.red` actual tiene ~1300 líneas solo para 32-bit. Duplicar eso para 64-bit con las estructuras y relocalizaciones apropiadas es la mayor carga de trabajo.

---

## 6. Riesgos

1. **El linker ELF está completamente desactivado** — no sabemos si funciona siquiera en 32-bit en system2. Necesitamos verificar primero que el linker ELF 32-bit funciona antes de añadir ELF64.
2. **El type system bug** puede tener implicaciones más amplias de las que parecen a primera vista — un cambio en el tamaño de punteros afecta a toda la generación de código.
3. **El equipo puede estar trabajando activamente** en partes de este plan (especialmente el register allocator global). Necesitamos coordinar para evitar conflictos.
4. **El runtime embebido** (`rs-runtime.red`) es un blob binario comprimido — modificarlo requiere regenerarlo con `merge-runtime.red`.

---

## 7. Notas de coordinación con el equipo principal

- El equipo principal (Xie Qingtian) ha hecho toda la infraestructura x64 pero solo para Windows
- Nuestra aportación es: SysV ABI, ELF64, runtime Linux x64, y el fix del type system
- Las Fases 0, 1, 2 son las que más valor aportan al proyecto upstream
- La Fase 5 (PIC) es interesante para todo el proyecto pero especialmente crítica para Linux
- Recomendamos hacer PRs incrementales por fase en vez de un mega-PR