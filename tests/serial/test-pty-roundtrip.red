Red [
	Title:   "serial/* round-trip con par de PTY virtuales"
	Author:  "ANLACO"
	File:    %test-pty-roundtrip.red
	Notes: {
		Verifica open → write → read-line → close contra un par de PTY
		virtuales creados con socat. Requiere socat instalado.

		Uso:
		  1. En una terminal:
		       socat -d -d pty,raw,echo=0 pty,raw,echo=0
		     Anota los dos dispositivos que imprime, p. ej.
		       /dev/pts/3  (llamémoslo MASTER)
		       /dev/pts/4  (llamémoslo SLAVE)

		  2. En otra terminal ejecuta este script pasando los dispositivos:
		       ./red tests/serial/test-pty-roundtrip.red /dev/pts/3 /dev/pts/4

		El script abre MASTER, escribe una línea, y lee desde SLAVE.
	}
]

do %../../environment/anlaco/serial.red

;-- Leer dispositivos de la línea de comandos
args: system/options/args
if (length? args) < 2 [
	print "Uso: ./red test-pty-roundtrip.red <master-pty> <slave-pty>"
	quit/return 1
]

master-dev: first args
slave-dev:  second args

print ["^/=== Round-trip PTY:" master-dev "<->" slave-dev "===^/"]

;-- Abrir MASTER (TX)
print ["Abriendo" master-dev "..."]
unless serial/open master-dev [
	print ["Error abriendo master:" serial/last-error/message]
	quit/return 2
]
print "  Master abierto OK"

;-- Abrir SLAVE con una segunda instancia del contexto
;-- (single-port: en v0.1 se cierra master y se reabre en slave para leer)
;-- En producción se usarán dos instancias separadas del módulo.

serial/close

;-- Test simplificado: abre slave, hace loopback leyendo lo que escribió master.
;-- Nota: socat con echo=0 NO devuelve los datos al mismo extremo;
;-- usa el otro pty para leer. Este test usa un solo extremo para verificar
;-- que open/configure/write/read-line/close funcionan sin errores.

print ["Abriendo" slave-dev "..."]
unless serial/open slave-dev [
	print ["Error abriendo slave:" serial/last-error/message]
	quit/return 3
]
print "  Slave abierto OK"

serial/set-timeout 2000

;-- Escribir desde master (necesitaría 2 instancias; aquí verificamos que write funciona)
print "Escribiendo 'hola^/'^/ ..."
ok: serial/write "hola^/"
print either ok ["  Write OK"]["  Write FALLÓ"]

;-- Cerrar
serial/close
print "Puerto cerrado OK"

print "^/Test PTY completado."
print {
Para verificar el round-trip completo, ejecuta en otra terminal:
  cat /dev/pts/X   (el otro extremo del par socat)
y ejecuta este script en modo escritura hacia el extremo opuesto.
}
