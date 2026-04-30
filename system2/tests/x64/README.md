# Linux x64 Tests

## Build

```bash
# Rebuild runtime first (required after any change in system2/runtime/)
./red-view system2/merge-runtime.red

# Compile hello world (requires libc6:i386 for bootstrap red-view binary)
./red-view -c -t Linux-64 system2/tests/x64/hello.reds

# Or use the build script
./system2/tests/x64/build.sh
```

## Verify

```bash
file hello                    # ELF 64-bit LSB executable, x86-64
readelf -h hello              # Class: ELF64, Machine: AMD x86-64
readelf -l hello              # PT_LOAD + PT_GNU_STACK flags=RW
objdump -d hello | head -20   # REX.W 48 prefixes, syscall 0F 05
strace ./hello                # write(1,...) + exit_group(0)
echo $?                       # 0
```

## Dependencies

- `red-view` (ELF 32-bit i386, dynamic-linked) — requires `libc6:i386`
- `binutils` (readelf, objdump, file)
- `strace` (optional, for syscall tracing)
