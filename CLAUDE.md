# CLAUDE.md

Repositorio: anlaco/red — fork de red/red con migración a x86-64.

## Ramas activas

- `master` — rama principal, sincronizada con upstream red/red (IA-32)
- `rsc2-x64` — migración a x86-64 (~177 commits adelante de master)

## Estructura clave

```
system/       → compilador IA-32 original (REBOL2 .r files)
system2/      → nuevo compilador x86-64 (Red/System .reds files)
  compiler.reds     → driver de compilación
  rst/              → parser + type-checker
  ir/               → SSA IR (graph, lowering, optimizer)
  x86/              → backend: codegen + assembler
  formats/          → ELF32, ELF64, PE emitters
  runtime/          → stubs OS-specific (linux64.reds, win32.reds, etc.)
  tests/x64/        → hello.reds de prueba
runtime/       → runtime Red/System compartido (modificado para 64-bit)
modules/view/  → GUI (sin cambios 64-bit, solo limpieza multi-monitor)
docs/plans/    → documentación de planificación y auditoría
CI/            → Dockerfiles y configs de CI
```

## Flujo de compilación

### Compilar el compilador Red
```bash
./rebol-core/rebol -qs red.r -r red.red
```

### Compilar hello.reds para x86-64
```bash
./red -t Linux-64 -c system2/tests/x64/hello.reds
chmod +x ./hello && ./hello     # debe imprimir "hello, x64 linux"
```

### Regenerar runtime embebido
```bash
./red-view system2/merge-runtime.red
```

## Dependencias

- `./rebol-core/rebol` — REBOL/Core 2.7.8 x86-64 (bootstrap)
- `./red-view` — Red 0.6.5 IA-32 precompilado (para merge-runtime)
- `./red` — Red 0.7.0 IA-32 (compilado desde red.red)

## Auditoría

Ver `docs/plans/auditoria-x64.md` para el informe completo de seguridad/calidad de la migración.
Issues abiertos en https://github.com/anlaco/red/issues.
