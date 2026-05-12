Red []

do %environment/anlaco/serial.red

print ["open?:" serial/open?]

r: serial/open "/dev/no-existe-test"
print ["open(/dev/no-existe-test):" r]
print ["open? after:" serial/open?]
print ["available?:" serial/available?]
print ["readable?:" serial/readable?]

e: serial/last-error
print ["last-error code:" e/code]
print ["last-error message:" e/message]

print ["close:" serial/close]
print "smoke OK"
