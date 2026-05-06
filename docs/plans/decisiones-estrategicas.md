# Decisiones estratégicas — Anlaco/red

**Fecha:** 2026-05-06
**Contexto:** Sesión de discusión técnica sobre el rumbo del fork tras completar M3 (hello.reds funcional en Linux-x64) y mergear master de upstream.

---

## D1 — Naturaleza del fork

**Decisión:** Anlaco/red es un **fork técnico multi-target potencial** de red/red ("Path A"), no una bifurcación semántica del lenguaje.

- Mantenemos compatibilidad con la sintaxis y semántica de Red.
- Añadimos targets/backends que red/red no contempla cuando lo necesitemos.
- **No** evolucionamos el lenguaje en direcciones incompatibles con upstream (al menos no en esta fase).

**Por qué:**
La inversión en infraestructura de targets es transferible (sigue siendo "Red"). Una bifurcación semántica del lenguaje no lo es: requiere docs propias, comunidad propia, identidad de marca, y compromete a Anlaco a mantener un lenguaje propio durante 5+ años.

**Cómo aplicar:**
Cualquier propuesta que cambie sintaxis, semántica de tipos, o comportamiento de natives core debe justificarse explícitamente y pasar por reevaluación de esta decisión. Cambios técnicos en backends/runtime/formats están dentro del alcance.

---

## D2 — Alcance inicial: solo Linux-x64

**Decisión:** El fork soporta exclusivamente **Linux x86-64 + GTK3** durante los próximos 12 meses, salvo trigger explícito (ver D5).

- Drop oficial de targets: Windows, ARM (32 y 64), IA-32, FreeBSD, NetBSD, Syllable, Android, macOS.
- GTK3 como única backend GUI.
- CI reducida a Linux-x64.

**Por qué:**
1. Anlaco está empezando: no hay clientes legacy con restricciones de hardware.
2. x86-32 está en deprecación activa en distros principales (Ubuntu 24.04+, Fedora, Arch sin i686).
3. El equipo es pequeño; multi-target multiplicaría coste de mantenimiento sin valor inmediato.
4. M3 ya está funcional sobre x64 (177 commits, hello.reds verificado).
5. Reduce drásticamente la superficie de merge con upstream.

**Cómo aplicar:**
- Cualquier código nuevo asume `target/addr-size = 8`, `arch-x86-64`, `OS = 'Linux`.
- Bugs/fixes en backends no soportados se ignoran (no se mergean desde upstream).
- Cuando se elimine código de targets descartados, hacerlo en commits limpios y reversibles, con tags `pre-drop-<target>` para poder restaurar si D5 se activa.

---

## D3 — Política de merge con upstream red/red

**Decisión:** Merge **selectivo y diferido** con `upstream/master`, no automático.

- **No** se mergea master de forma rutinaria.
- Se cherry-pickan o evalúan caso por caso fixes que afecten a:
  - `runtime/datatypes/` (compartido)
  - `runtime/lexer.reds`, `runtime/parse.reds` (compartido)
  - `system/` (legacy IA-32 compiler, compartido para bootstrap)
  - `runtime/allocator.reds`, `runtime/memory.reds` (compartido)
- Se **ignoran** cambios upstream a:
  - `runtime/win32.reds`, `runtime/freebsd.reds`, `runtime/netbsd.reds`, `runtime/android.reds`, `runtime/mac*.reds`, `runtime/iOS.reds`
  - Backends GUI no-GTK3 (`modules/view/backends/{windows,macOS,android,gtk}/`)
  - Targets ARM, ARM64

**Por qué:**
- El merge automático de hoy (master → rsc2-x64) introdujo silenciosamente el bug de `binary.reds:1007` que rompió la generación de ELF64. Un merge controlado lo hubiera detectado antes.
- Reduce trabajo: la mayoría de commits upstream tocan código que no usamos.
- Hace el fork más estable.

**Cómo aplicar:**
- Cuando aparezca un bug que sospechemos resuelto upstream, evaluar el commit específico y aplicarlo.
- Cuando un release upstream añada algo deseable, evaluar como feature import, no como sync.
- Documentar cada merge/cherry-pick con commit message explicando origen y razón.

---

## D4 — Bugs upstream descubiertos

**Decisión:** Fixes a bugs upstream se aplican **localmente** en anlaco/red. No se contribuye upstream.

- Cada fix se documenta con un issue en `anlaco/red` etiquetado `upstream` (color amarillo).
- El issue indica el commit upstream que introdujo la regresión (si se conoce) y el commit local que lo arregla.
- Si upstream eventualmente arregla el mismo bug, en el siguiente merge selectivo (D3) se evalúa si reemplazar nuestro fix por el suyo.

**Por qué:**
Anlaco no se posiciona como contribuidor de red/red. Documentar internamente preserva trazabilidad para futuros merges sin generar carga de comunicación con upstream.

**Cómo aplicar:**
- Plantilla del issue: prefijo `[UPSTREAM]` en el título, label `bug` + `upstream`, cuerpo con repro, fix y referencia al commit local.
- Ejemplo de referencia: issue #4 (binary/convert TYPE_BINARY ignora bin/head).

---

## D5 — Triggers para reabrir scope

**Decisión:** El alcance D2 (solo Linux-x64 + GTK3) se reabre **únicamente** si se cumple uno de:

1. **Cliente / proyecto Anlaco real necesita un target adicional** (Windows, ARM64, móvil, browser).
2. **Linux-x86-64 deja de ser suficiente** para algún despliegue (improbable a corto plazo).
3. **Decisión estratégica explícita** de Anlaco para posicionar el fork como producto multi-target.

**No son triggers válidos:**
- "Sería interesante tener WASM."
- "JVM mola."
- "Y si en algún momento alguien necesita X..."

**Cómo aplicar:**
Cuando se proponga ampliar scope, validar contra la lista anterior. Si se activa un trigger, abrir issue con propuesta y reevaluar D2.

---

## D6 — Identidad y nombre

**Decisión:** Mantener el nombre **"Red"** internamente; el repo es `anlaco/red`. **No** crear marca propia ("Anlaco-Red", "RedX", etc.) en esta fase.

**Por qué:**
- Reduce coste de marketing/identidad/docs.
- Mantiene compatibilidad con docs y recursos de red/red para nuevos miembros del equipo.
- Si el fork crece y diverge significativamente, se replantea (Path B futura).

**Cómo aplicar:**
- README, CLAUDE.md, commits hablan de "Red para necesidades Anlaco".
- No registrar dominios, marcas ni canales de comunidad propios.

---

## D7 — JVM y otros backends futuros

**Decisión:** **Fuera de alcance actual.** Se evaluará un spike de JVM target solo después de que x64 esté estabilizado y un trigger D5 lo justifique.

**Por qué:**
- JVM es técnicamente viable (Project Panama / FFM API desde JDK 22) pero requiere x64 funcionando como bootstrap.
- Sin demanda real, es esfuerzo no justificado.

**Cómo aplicar:**
Si en el futuro se justifica, el plan inicial sería:
1. Fase 0: x64 estabilizado (D2 cumplido + auditoría P0/P1 cerrada).
2. Fase 1: spike `system2/jvm/` con codegen + ClassFile emitter, hello-world equivalente.
3. Fase 2: decisión informada con datos del spike.

---

## D8 — Calidad: cerrar P0 de la auditoría antes de declarar M3 estable

**Decisión:** Aplicar los tres fixes P0 documentados en `auditoria-x64.md` (sección 2.3-bis) antes de considerar el fork "estable":

| ID | Archivo:línea | Naturaleza |
|---|---|---|
| **P0-S1** | `system2/x86/assembler.reds:714` | `xor-r-r r r REX_W` → `xor-r-r r r asm/rex-byte`. Trivial; en x64-only la regresión IA-32 es académica pero se arregla por consistencia. |
| **P0-S2** | `system2/runtime/lib-natives.reds:165-176` | Stubs silenciosos de float. Cambiar a fail-loud (`prin "FLOAT-STUB"` + `quit 1`) o implementar con x87/SSE. |
| **P0-S3** | `system2/x86/codegen.reds:1768-1770` | Restaurar `emit-instr cg I_POP_ALL or M_FLAG_FIXED`. Crítico: actualmente `pop_all` es no-op en x64. |

**Por qué:**
M3 actualmente es "funcional pero frágil". Estos tres fixes son baratos (1-3 líneas cada uno) y eliminan los bugs más graves identificados. Sin ellos, cualquier programa real (no solo `hello.reds`) tendrá comportamiento impredecible.

**Cómo aplicar:**
Sesión dedicada antes de aceptar nuevo trabajo de features. P0-S1 y P0-S3 son inmediatos. P0-S2 puede diferirse si no se usan floats, pero documentar la limitación.

---

## D9 — Auditoría como referencia viva

**Decisión:** `docs/plans/auditoria-x64.md` es el documento de referencia para deuda técnica conocida. Se actualiza cuando:

- Se cierra un hallazgo (marcar como ✅ resuelto + commit referencia).
- Se descubre uno nuevo durante mantenimiento.
- Se invalida uno por cambio de contexto (ej. drop de un target afectado).

**No** se reescribe ni se renombra: 4 IAs externas la van a revisar y debe ser estable como referencia.

---

## Próximos pasos inmediatos

1. Aplicar P0-S1, P0-S2, P0-S3 (fixes triviales, una sesión).
2. Drop oficial de targets no soportados (commit dedicado con tags `pre-drop-*`).
3. Actualizar `CLAUDE.md` para reflejar el scope (solo Linux-x64 + GTK3).
4. Actualizar `auditoria-x64.md` marcando P0-S1/S2/S3 como resueltos cuando se apliquen.

---

*Documento de decisiones estratégicas. Cualquier desviación debe documentarse explícitamente en este archivo (nueva sección o revisión datada de la decisión correspondiente).*
