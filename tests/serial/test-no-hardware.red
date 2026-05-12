Red [
	Title:   "serial/* smoke tests (no hardware required)"
	Author:  "ANLACO"
	File:    %test-no-hardware.red
	Notes: {
		Verifica el comportamiento del módulo serial sin ningún puerto físico.
		Ejecutar con:
		  ./red tests/serial/test-no-hardware.red

		Todos los tests deben imprimir OK.
	}
]

do %../../environment/anlaco/serial.red

passed: 0
failed: 0

assert: func [desc [string!] result [logic!]][
	either result [
		print ["  OK" desc]
		passed: passed + 1
	][
		print ["FAIL" desc]
		failed: failed + 1
	]
]

print "^/=== serial/* -- tests sin hardware ===^/"

;-- Estado inicial
print "^/-- Estado inicial --"
assert "open? es false al cargar"           (serial/open? = false)
assert "available? devuelve 0 sin abrir"    (serial/available? = 0)
assert "readable? devuelve false sin abrir" (serial/readable? = false)

;-- Abrir dispositivo inexistente
print "^/-- Abrir dispositivo inexistente --"
result: serial/open "/dev/no-existe-12345"
assert "open devuelve false"                (result = false)
assert "open? sigue false tras error"       (serial/open? = false)

err: serial/last-error
assert "last-error devuelve object!"        (object? err)
assert "last-error/code <> 0"               (err/code <> 0)
assert "last-error/message es string!"      (string? err/message)

;-- Operaciones sobre puerto cerrado
print "^/-- Operaciones sobre puerto cerrado --"
assert "write devuelve false sin abrir"     (false = serial/write "hola")
assert "read devuelve none sin abrir"       (none = serial/read 32)
assert "read-line devuelve none sin abrir"  (none = serial/read-line)
assert "close devuelve true siempre"        (true = serial/close)
assert "flush devuelve false sin abrir"     (false = serial/flush)
assert "drain devuelve false sin abrir"     (false = serial/drain)
assert "set-dtr devuelve false sin abrir"   (false = serial/set-dtr true)
assert "set-rts devuelve false sin abrir"   (false = serial/set-rts false)
assert "get-cts devuelve false sin abrir"   (false = serial/get-cts)
assert "get-dsr devuelve false sin abrir"   (false = serial/get-dsr)
assert "get-cd  devuelve false sin abrir"   (false = serial/get-cd)
assert "get-ri  devuelve false sin abrir"   (false = serial/get-ri)

;-- set-timeout (no requiere puerto abierto)
print "^/-- set-timeout --"
assert "set-timeout devuelve true"          (true = serial/set-timeout 500)

;-- Resumen
print rejoin ["^/Resultado: " passed " OK, " failed " FAIL"]
either failed = 0 [
	print "Todos los tests pasaron.^/"
][
	print rejoin [failed " tests fallaron.^/"]
]
