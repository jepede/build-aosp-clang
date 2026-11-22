#!/usr/bin/env python3
"""Native Linux AArch64 smoke tests for a source-pinned AOSP Clang rebuild."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: smoke-clang-linux-arm64-multi.py STAGE EXPECTED_VERSION")
    stage = Path(sys.argv[1]).resolve()
    version = sys.argv[2]
    bindir = stage / "bin"
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ.get("PATH", ""))
    flags = []
    if os.environ.get("HOST_GCC_TOOLCHAIN"):
        flags.append("--gcc-toolchain=" + os.environ["HOST_GCC_TOOLCHAIN"])
    results = []

    def run(cmd, regexp=None, cwd=None):
        cmd = [str(x) for x in cmd]
        p = subprocess.run(cmd, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        rec = {"command": cmd, "exit_code": p.returncode, "output": p.stdout[:15000]}
        results.append(rec)
        if p.returncode or (regexp is not None and not re.search(regexp, p.stdout)):
            raise RuntimeError(json.dumps(rec, indent=2))
        return p.stdout.strip()

    def exe(name):
        p = bindir / name
        if not p.is_file():
            raise RuntimeError("Required native tool missing: " + name)
        return p

    try:
        for name in ["clang", "clang++", "ld.lld", "llvm-ar", "llvm-ranlib",
                     "llvm-nm", "llvm-objcopy", "llvm-objdump", "llvm-readelf",
                     "llvm-strip", "llvm-size", "llc", "opt"]:
            exe(name)
        for path in sorted(bindir.iterdir()):
            run(["readelf", "-h", path], r"Machine:\s+AArch64")
            if not path.is_symlink():
                run(["readelf", "-l", path], r"/lib/ld-linux-aarch64.so.1")
                deps = run(["ldd", path])
                if "not found" in deps or "/system/bin/linker" in deps:
                    raise RuntimeError("Not a working Linux/glibc executable: " + str(path))
        run([exe("clang"), "--version"], re.escape("clang version " + version))
        run([exe("ld.lld"), "--version"], re.escape("LLD " + version))
        run([exe("clang"), "-dumpmachine"], r"aarch64.*linux-gnu")
        resource = Path(run([exe("clang"), "-print-resource-dir"]))
        if not (resource / "include/stddef.h").is_file():
            raise RuntimeError("Missing packaged resource headers: " + str(resource))

        with tempfile.TemporaryDirectory(prefix="clang-aosp-multi-smoke-") as temp:
            d = Path(temp)
            c = d / "native.c"
            c.write_text('#include <stdio.h>\nint main(){puts("aosp-native-glibc-ok");return 0;}\n')
            run([exe("clang"), *flags, c, "-o", d / "native"])
            run([d / "native"], r"aosp-native-glibc-ok")
            cpp = d / "native.cpp"
            cpp.write_text('#include <vector>\n#include <numeric>\n'
                           'int main(){std::vector<int> v{1,2,3};'
                           'return std::accumulate(v.begin(),v.end(),0)!=6;}\n')
            run([exe("clang++"), *flags, cpp, "-o", d / "native-cxx"])
            run([d / "native-cxx"])
            kernel = d / "kernel.c"
            kernel.write_text('typedef unsigned long uword;\n'
                              'uword kernel_probe(uword x){return (x ^ 0x1234UL) + 7;}\n')
            obj = {}
            for name, triple, pattern, extra in [
                ("arm64", "aarch64-linux-gnu", "AArch64",
                 ["-mgeneral-regs-only", "-mno-outline-atomics"]),
                ("arm32", "arm-linux-gnueabi", "ARM",
                 ["-march=armv7-a", "-mfloat-abi=soft"]),
                ("x86_64", "x86_64-linux-gnu", "Advanced Micro Devices X86-64", []),
                ("bpf", "bpf", "(?:Linux BPF|EM_BPF|BPF)", []),
            ]:
                obj[name] = d / (name + ".o")
                run([exe("clang"), "--target=" + triple, "-O2", "-g", "-ffreestanding",
                     "-fno-builtin", "-fno-stack-protector", *extra, "-c", kernel,
                     "-o", obj[name]])
                run([exe("llvm-readelf"), "-h", obj[name]], r"Machine:\s+" + pattern)
            run([exe("ld.lld"), "-m", "aarch64elf", "-r", obj["arm64"], "-o", d / "linked.o"])
            run([exe("llvm-ar"), "rcs", d / "built-in.a", d / "linked.o"])
            run([exe("llvm-ranlib"), d / "built-in.a"])
            run([exe("llvm-nm"), d / "built-in.a"], r"kernel_probe")
            run([exe("llvm-objdump"), "-d", d / "linked.o"], r"kernel_probe")
            run([exe("llvm-objcopy"), "-O", "binary", d / "linked.o", d / "Image"])
            run([exe("llvm-strip"), "--strip-debug", d / "linked.o"])
            run([exe("llvm-size"), d / "linked.o"], r"text\s+data\s+bss")
            if not (d / "Image").stat().st_size:
                raise RuntimeError("llvm-objcopy produced an empty binary")
            cfi = d / "cfi.c"
            cfi.write_text("static int twice(int x){return x*2;}\n"
                           "int (*volatile callback)(int)=twice;\n"
                           "int entry(int x){return callback(x);}\n")
            for lto in ("full", "thin"):
                dest = d / ("cfi-" + lto)
                run([exe("clang"), "--target=aarch64-linux-gnu", "-O2", "-ffreestanding",
                     "-nostdlib", "-static", "-fuse-ld=lld", "-flto=" + lto,
                     "-fsanitize=cfi", "-fvisibility=hidden", "-Wl,-e,entry",
                     cfi, "-o", dest])
                run([exe("llvm-readelf"), "-h", dest], r"Machine:\s+AArch64")
        passed = True
        error = None
    except Exception as exc:
        passed = False
        error = str(exc)
        raise
    finally:
        report = {"passed": passed, "version": version, "checks": len(results),
                  "error": error, "results": results}
        (stage / "smoke-results.json").write_text(json.dumps(report, indent=2) + "\n")
    print("AOSP Linux/glibc AArch64 smoke checks passed:", len(results))

if __name__ == "__main__":
    main()
