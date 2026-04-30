# Plan MVP — Red/System a Linux x86-64

**Rama:** `rsc2-x64`
**Objetivo:** Binario ELF64 estatico (`system2/tests/x64/hello.reds`) que imprime
"hello, x64 linux" y retorna 0, sin romper builds 32-bit existentes.
**Ultima revision:** 2026-05-01 (estado verificado en disco)

---

## 1. Estado verificado

### 1.1 Hecho (M0-M2)

| Hito | Detalle |
|------|---------|
| M0 — Bootstrap | `./rebol -qws red.r -r red.red` compila a `red` (ELF 32-bit, 1.97 MB). `pop-r`/`push-r`/`push-m`/`lea` ya no usan refinements `/rex` con tipo; el dispatch 32/64 va por `asm/rex-byte` global. |
| M1 — Bugs F1-F3 | B-ASM2 (atomic ops), B-ASM3 (I_STACK_ALIGN), B-CG1/B-CG2 (scratch hardcoded) corregidos. I_CATCH/I_THROW usan `slot1 = -addr-size`, `slot2 = -2*addr-size`. I_STACK_ALLOC bifurca x64 con `shl 3`/`and -8`/`rep-stosq`. `gen-move-imm-to-loc` emite `I_MOVQ` para x64. Dispatchers Q completos en `assemble-r`/`-m`/`-r-r`/`-r-m`/`-r-i`/`-m-i`/`-m-r`. |
| M2 — ELF64 (~70%) | `system2/formats/ELF64.red` (158 lineas) emite Ehdr+PT_PHDR+PT_LOAD_RX+PT_LOAD_RW+PT_GNU_STACK. `linker.red:13` enlaza ELF64.red. `compiler.reds` añade `target/os-type` y enlaza `x64-sysv-cc`. `x64_SCRATCH = R11`, RDI liberado en reg-sets a30/a33/a34/a35. `class_struct` añadido a `x64-cc/make`. |

Archivos modificados (8):
`encapper/compiler.r`, `system2/backend.reds`, `system2/compiler.reds`,
`system2/config.red`, `system2/linker.red`, `system2/type-system.reds`,
`system2/x86/assembler.reds`, `system2/x86/codegen.reds`.

Archivos nuevos (untracked):
`system2/formats/ELF64.red`, `system2/rs-runtime.red`,
`system2/tests/x64/{hello.reds,build.sh,README.md}`,
`.github/workflows/linux-x64.yml`, `CI/Linux-64/Dockerfile`.

### 1.2 Bloqueante actual

```
$ ./red -c -t Linux-64 system2/tests/x64/hello.reds
*** Compilation Error: undefined type: __cpu-struct!
*** in file: %~/.red/.rs-runtime/system.reds  at line: 164
```

`runtime/system.reds:87-156` solo tiene ramas `#switch target` para `IA-32` y
`ARM`. Para target `AMD64` no hay definicion de `__cpu-struct!` ni
`__fpu-struct!`, por lo que `system!` (linea 164) referencia un tipo
indefinido.

### 1.3 Regresion abierta detectada

`system2/linker.red:291` selecciona el emisor con
`either job/OS = 'Windows [PE][ELF]`, y `ELF` apunta **incondicionalmente** a
`%formats/ELF64.red`. Cualquier compilacion para targets ELF de 32 bits
(Linux IA-32, FreeBSD, NetBSD, Syllable, Android) producira un binario con
cabecera ELF64 invalida. **No marcado en estados previos.**

Solucion: bifurcar por `target/addr-size` antes del `do [file-emitter/build]`,
preservando el path 32-bit (en `formats/ELF.red`, hoy comentado). No es
critico para el MVP del hello x64 porque solo compilamos `-t Linux-64`,
pero hay que cerrarlo antes de mergear a master.

---

## 2. Trabajo pendiente — secuencia para llegar al MVP

### M3 — Runtime estatico Linux x64 (~3 dias, ~300 LoC)

Archivos: `runtime/system.reds`, `runtime/linux.reds`, `runtime/start.reds`,
`runtime/common.reds`, `runtime/lib-names.reds`, `runtime/heap.reds`,
`runtime/POSIX.reds`, `runtime/POSIX-signals.reds`,
`runtime/linux-sigaction.reds`, `runtime/lib-natives.reds`,
luego `system2/rs-runtime.red`.

**M3.1 — Rama AMD64 en `runtime/system.reds`** (desbloquea la compilacion):

Añadir tras la rama ARM en el `#switch target` (~linea 156) una rama AMD64 con:

```reds
AMD64 [
    x87-option!: alias struct! [
        rounding  [integer!]
        precision [integer!]
    ]
    __fpu-struct!: alias struct! [
        type         [integer!]
        option       [x87-option!]
        mask         [FPU-exceptions-mask!]
        status       [integer!]
        control-word [integer!]
        epsilon      [integer!]
        update       [integer!]
        init         [integer!]
    ]
    __cpu-struct!: alias struct! [      ;-- 16 GPR x64
        rax [integer!] rbx [integer!] rcx [integer!] rdx [integer!]
        rsp [integer!] rbp [integer!] rsi [integer!] rdi [integer!]
        r8  [integer!] r9  [integer!] r10 [integer!] r11 [integer!]
        r12 [integer!] r13 [integer!] r14 [integer!] r15 [integer!]
        overflow? [logic!]
    ]
]
```

Verificar: `./red -c -t Linux-64 system2/tests/x64/hello.reds` ya no falla
con "undefined type". El siguiente error te indica el siguiente bloqueante.

**M3.2 — Syscalls x64 en `runtime/linux.reds`:**

Bifurcar el bloque `#syscall`:

```reds
#either target/arch = arch-x86-64 [
    #syscall [
        write: 1 [...]                ;-- sys_write
        quit:  60 [status [integer!]] ;-- sys_exit (preferible 231 exit_group post-MVP)
    ]
][
    #syscall [
        write: 4 [...]
        quit:  1 [status [integer!]]
    ]
]
```

El opcode `I_SYSCALL` ya emite `0F 05` para `arch-x86-64` y `CD 80` para x86
(`assembler.reds:2122`); solo falta que la tabla de numeros refleje el ABI
correcto.

**M3.3 — `_start` x64 en `runtime/start.reds`:**

Añadir rama `#if target/arch = arch-x86-64 [...]` cuando `OS = 'Linux` y
`use-natives? = yes`. Patron a imitar (FreeBSD/Darwin, lineas 33-68): leer
argc/argv desde RSP via los pseudo-ops `system/stack/top`, `pop`, etc.,
**sin assembly inline**. Diferencias x64 vs x86:
- argc esta en `[rsp]`, argv en `[rsp+8]`, envp en `[rsp+8+(argc+1)*8]`.
- Antes de llamar a `***_start`: `and rsp, ~15` y `sub rsp, 8` (B39: SSE
  alineado 16; sin esto SIGSEGV en `movaps`).
- Salir con `quit` (= sys_exit 60) o exit_group (231).

**M3.4 — Resto de runtime compartido:**

| Archivo | Cambio |
|---------|--------|
| `runtime/common.reds` | `long!`/`int-ptr!` ancho variable; `typed-value!` con padding 64-bit. |
| `runtime/lib-names.reds` | `dynamic-linker: "/lib64/ld-linux-x86-64.so.2"` para x64 (no necesario MVP estatico, si para F8+). |
| `runtime/heap.reds` | Aritmetica de offsets * `target/addr-size`. |
| `runtime/POSIX.reds`, `POSIX-signals.reds`, `linux-sigaction.reds` | `siginfo_t`/`ucontext_t` x64 (R8-R15, RIP, RFLAGS). |
| `runtime/lib-natives.reds`, `runtime/libc.reds` | Punteros 8 bytes en `#import`. |

Para el MVP estatico (solo `write` + `quit`) la mayor parte de M3.4 se
puede recortar; solo es estrictamente necesario M3.1+M3.2+M3.3. Los demas
archivos hay que tocarlos solo cuando bloquean compilacion.

**M3.5 — Regenerar runtime embebido:**

```bash
./red-view system2/merge-runtime.red
```

Requiere multilib (`libc6:i386 libgcc-s1:i386`). Esto reescribe
`system2/rs-runtime.red`.

### M4 — Hello world end-to-end (~0.5 dias)

```bash
./red -c -t Linux-64 system2/tests/x64/hello.reds
file hello                          # ELF 64-bit LSB executable, x86-64
readelf -h hello | grep "AMD x86"   # Machine: AMD x86-64
readelf -l hello | grep GNU_STACK   # PT_GNU_STACK presente
strace -e write,exit_group ./hello  # write(1, "hello, x64 linux\n", 17), exit_group(0)
echo $?                             # 0
```

Si falla aqui, los puntos a auditar primero:
1. `e_entry` apunta dentro del segmento RX (`base-address + code-offset`).
2. RSP%16 al entrar a `***_start`.
3. Numero de syscall `quit` (debe ser 60, no 1).
4. Retorno de `***_start` cae en infinite loop o syscall sin numero
   (si no hay `_start` x64 explicito, el codigo "cae" desde la entry).

### M5 — Cerrar CI y regresion 32-bit (~0.5 dias)

**Pre-requisito antes de mergear:** arreglar la regresion de `linker.red`.

`system2/linker.red:291`:

```reds
;-- AHORA:
file-emitter: either job/OS = 'Windows [PE][ELF]

;-- DESPUES (sketch — el dispatch real puede ir dentro de ELF/build):
file-emitter: either job/OS = 'Windows [PE][
    either job/target = 'AMD64 [ELF64][ELF32]   ;-- ELF32 = formats/ELF.red original (descomentar)
]
```

O alternativamente, dejar un solo `ELF` que internamente bifurque por
`job/target`. Lo importante: que un build con `-t Linux` siga produciendo
ELF32 valido. Test de regresion: compilar un programa Red/System en master
y compararlo bajo esta rama con `-t Linux`.

CI:
- El workflow `linux-x64.yml` ya esta. Verificar que ejecuta el path
  completo (M4) cuando M3 cierre.
- Añadir job de regresion con `-t Linux` (32-bit) que confirme que el ELF
  sigue siendo valido tras el fix de M5.

---

## 3. Fuera del MVP (post-merge)

| # | Item | Cuando |
|---|------|--------|
| F8 | ELF64 dinamico (PT_DYNAMIC, PLT/GOT, RELA, section headers) | Tras MVP |
| F9 | Linking contra libc, T1 variadic SysV (`mov al, n`), T1.5 MOVSX/MOVZX bits altos, MOVSXD opcode | Tras MVP |
| F10 | PIC/PIE (RIP-relative, ET_DYN) | Tras F9 |
| F11 | Hardening (CET, .eh_frame, RELRO, RELR, stack-clash) | Release 1.1 |
| F12 | TLS, DWARF, stack canaries | Release 1.1+ |
| — | Escalada de syscall MVP (`quit`=60) a `exit_group`=231 | Trivial, post-MVP |

---

## 4. Riesgos abiertos

| # | Riesgo | Mitigacion |
|---|--------|------------|
| R1 | Regresion ELF32 al activar ELF64 incondicional en linker | Fix M5 antes de mergear; CI con job 32-bit. |
| R2 | `_start` x64 con sintaxis Red/System invalida | Imitar patron FreeBSD/Darwin; iterar con compilador y leer error. |
| R3 | Runtime embebido desincronizado tras M3 | `./red-view system2/merge-runtime.red` antes de M4. |
| R4 | RSP%16 mal alineado al entrar a `***_start` | Verificar con gdb (`b ***_start; info registers rsp`). |
| R5 | Cambio R11 como SCRATCH puede romper Win64 | Job `regression-windows-x64` ya existe en `.github/workflows/linux-x64.yml`. |
| R6 | `emit-q` con host 32-bit y `q >>> 32` (D3 historico) | No bloquea MVP; revisar al subir imm64 reales. |

---

## 5. Verificacion end-to-end

```bash
cd /home/alaforga/Anlaco/01-PRODUCTOS/red

# Bootstrap (ya pasa, ~80 s):
./rebol -qws red.r -r red.red

# Tras M3:
./red-view system2/merge-runtime.red                  # regenera rs-runtime.red
./red -c -t Linux-64 system2/tests/x64/hello.reds     # compila hello

# M4 — verificar binario:
file hello | grep "ELF 64-bit"
readelf -h hello | grep "AMD x86-64"
readelf -l hello | grep GNU_STACK
./hello                                                # "hello, x64 linux"
echo $?                                                # 0

# M5 — regresion 32-bit:
./red -c -t Linux some/program.reds                    # debe seguir produciendo ELF32 valido
file some-program | grep "ELF 32-bit"
```
