#!/usr/bin/env python3
"""Exercise the packaged Linux ARM64 compiler, linker, and kernel build tools."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    stage = Path(sys.argv[1]).resolve()
    bindir = stage / 'bin'
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'])
    gcc_prefix = os.environ.get('HOST_GCC_TOOLCHAIN')
    native_flags = ['--gcc-toolchain=' + gcc_prefix] if gcc_prefix else []
    results = []

    def run(args, expected=None, cwd=None):
        command = [str(arg) for arg in args]
        proc = subprocess.run(command, cwd=cwd, env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        record = {'command': command, 'exit_code': proc.returncode, 'output': proc.stdout}
        results.append(record)
        if proc.returncode or (expected and not re.search(expected, proc.stdout)):
            raise RuntimeError(json.dumps(record, indent=2))
        return proc.stdout

    def tool(name):
        path = bindir / name
        if not path.is_file():
            raise RuntimeError('missing packaged tool: ' + name)
        return path

    try:
        for path in sorted(bindir.iterdir()):
            run(['readelf', '-h', path], r'Machine:\s+AArch64')
            if not path.is_symlink():
                run(['readelf', '-l', path], r'/lib/ld-linux-aarch64.so.1')
                dependencies = run(['ldd', path])
                if 'not found' in dependencies or '/system/bin/linker' in dependencies:
                    raise RuntimeError('invalid Linux dependencies: ' + str(path))
        run([tool('clang'), '--version'], r'clang version 12\.0\.5')
        run([tool('clang'), '-dumpmachine'], r'aarch64.*linux-gnu')
        run([tool('ld.lld'), '--version'], r'LLD 12\.0\.5')
        resource = Path(run([tool('clang'), '-print-resource-dir']).strip())
        if not (resource / 'include/stddef.h').is_file():
            raise RuntimeError('missing Clang resource headers')

        with tempfile.TemporaryDirectory(prefix='clang12-smoke-') as temporary:
            work = Path(temporary)
            native_c = work / 'native.c'
            native_c.write_text('#include <stdio.h>\nint main(void) { puts("clang12-native-ok"); return 0; }\n')
            run([tool('clang'), *native_flags, native_c, '-o', work / 'native'])
            run([work / 'native'], r'clang12-native-ok')
            native_cxx = work / 'native.cpp'
            native_cxx.write_text('#include <vector>\n#include <numeric>\nint main() { std::vector<int> v{1, 2, 3}; return std::accumulate(v.begin(), v.end(), 0) != 6; }\n')
            run([tool('clang++'), *native_flags, native_cxx, '-o', work / 'native-cxx'])
            run([work / 'native-cxx'])

            kernel_c = work / 'kernel.c'
            kernel_c.write_text('typedef unsigned long uword;\nuword kernel_probe(uword x) { return (x ^ 0x1234UL) + 7; }\n')
            objects = []
            for name, triple, machine, flags in [
                ('arm64', 'aarch64-linux-gnu', 'AArch64', ['-mgeneral-regs-only', '-mno-outline-atomics']),
                ('arm32', 'arm-linux-gnueabi', 'ARM', ['-march=armv7-a', '-mfloat-abi=soft']),
                ('x86_64', 'x86_64-linux-gnu', 'Advanced Micro Devices X86-64', []),
                ('bpf', 'bpf', '(?:Linux BPF|EM_BPF|BPF)', []),
            ]:
                obj = work / (name + '.o')
                run([tool('clang'), '--target=' + triple, '-O2', '-g', '-ffreestanding',
                     '-fno-builtin', '-fno-stack-protector', *flags, '-c', kernel_c, '-o', obj])
                run([tool('llvm-readelf'), '-h', obj], r'Machine:\s+' + machine)
                objects.append(obj)

            run([tool('ld.lld'), '-m', 'aarch64elf', '-r', objects[0], '-o', work / 'linked.o'])
            run([tool('llvm-ar'), 'rcs', work / 'built-in.a', work / 'linked.o'])
            run([tool('llvm-ranlib'), work / 'built-in.a'])
            run([tool('llvm-nm'), work / 'built-in.a'], r'kernel_probe')
            run([tool('llvm-objdump'), '-d', work / 'linked.o'], r'kernel_probe')
            run([tool('llvm-objcopy'), '-O', 'binary', work / 'linked.o', work / 'Image'])
            run([tool('llvm-strip'), '--strip-debug', work / 'linked.o'])
            run([tool('llvm-size'), work / 'linked.o'], r'text\s+data\s+bss')
            if not (work / 'Image').stat().st_size:
                raise RuntimeError('llvm-objcopy generated an empty raw image')

            cfi_c = work / 'cfi.c'
            cfi_c.write_text('static int twice(int x) { return x * 2; }\nint (*volatile callback)(int) = twice;\nint entry(int x) { return callback(x); }\n')
            for lto in ['full', 'thin']:
                output = work / ('cfi-' + lto)
                run([tool('clang'), '--target=aarch64-linux-gnu', '-O2', '-ffreestanding',
                     '-nostdlib', '-static', '-fuse-ld=lld', '-flto=' + lto,
                     '-fsanitize=cfi', '-fvisibility=hidden', '-Wl,-e,entry',
                     cfi_c, '-o', output])
                run([tool('llvm-readelf'), '-h', output], r'Machine:\s+AArch64')
        report = {'passed': True, 'checks': len(results), 'results': results}
    except Exception as error:
        report = {'passed': False, 'error': str(error), 'results': results}
        raise
    finally:
        (stage / 'smoke-results.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Linux ARM64 toolchain smoke checks passed: ' + str(len(results)))


if __name__ == '__main__':
    main()
