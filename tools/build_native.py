"""Build the aoe_sim GDExtension (native/aoe_sim) into addons/aoe_sim/bin.

Fetches the pinned godot-cpp into native/godot-cpp on first use, then builds
template_debug (editor and debug runs) and template_release (exports).

    # Linux host, Linux library:
    python tools/build_native.py
    # Windows DLL with llvm-mingw (from Linux or Windows):
    python tools/build_native.py --platform windows --llvm-mingw <llvm-mingw dir>
    # Windows host with Visual Studio (MSVC):
    python tools/build_native.py --platform windows

Requires CMake >= 3.17, git and a C++17 compiler; Ninja is used when found.
The prebuilt binaries in addons/aoe_sim/bin were built with llvm-mingw
20261020 (Windows) and GCC 13 (Linux). The kernels are integer-only, so any
conforming compiler produces identical simulation results; still run
tests/run_native_sim_equivalence.gd after rebuilding.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import platform as host
import shutil
import subprocess

GODOT_CPP_URL = "https://github.com/godotengine/godot-cpp"
# godot-cpp master with the 4.7 extension API (2026-10-31).
GODOT_CPP_COMMIT = "e103d348c4b2d8df7b819126d855e19381cb9a87"


def run(command: list[str], cwd: Path | None = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def ensure_godot_cpp(path: Path) -> None:
    if not (path / ".git").exists():
        run(["git", "clone", "--filter=blob:none", GODOT_CPP_URL, str(path)])
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=path, capture_output=True, text=True, check=True).stdout.strip()
    if head != GODOT_CPP_COMMIT:
        run(["git", "fetch", "origin", GODOT_CPP_COMMIT], cwd=path)
        run(["git", "checkout", "--detach", GODOT_CPP_COMMIT], cwd=path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_platform = "windows" if host.system() == "Windows" else "linux"
    parser.add_argument("--platform", choices=("windows", "linux"), default=default_platform)
    parser.add_argument("--targets", nargs="+", default=["template_debug", "template_release"],
                        choices=("template_debug", "template_release"))
    parser.add_argument("--llvm-mingw", help="llvm-mingw directory (Windows DLL without Visual Studio)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    native = root / "native"
    source = native / "aoe_sim"
    ensure_godot_cpp(native / "godot-cpp")
    output = root / "addons" / "aoe_sim" / "bin"
    output.mkdir(parents=True, exist_ok=True)
    for target in args.targets:
        build = source / f"build-{args.platform}-{target}"
        configure = ["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
                     f"-DGODOTCPP_TARGET={target}", f"-DAOE_OUTPUT_DIR={output}"]
        if shutil.which("ninja"):
            configure += ["-G", "Ninja"]
        if args.llvm_mingw:
            configure += [f"-DCMAKE_TOOLCHAIN_FILE={source / 'toolchain-llvm-mingw.cmake'}",
                          f"-DLLVM_MINGW={Path(args.llvm_mingw).resolve()}"]
        elif args.platform == "windows" and host.system() != "Windows":
            parser.error("cross-compiling the Windows DLL needs --llvm-mingw")
        run(configure)
        run(["cmake", "--build", str(build), "--config", "Release", "--parallel", str(args.jobs)])
    print("Built:", ", ".join(sorted(p.name for p in output.iterdir())))


if __name__ == "__main__":
    main()
