Dev Setup
=========

# ArtCraft 

ArtCraft is a Rust / Tauri app.

To set up the ArtCraft development environment,  install the following:

1. [Install Rust](https://doc.rust-lang.org/cargo/getting-started/installation.html).
2. [Install npm](https://nodejs.org/en/download) or [nvm](https://github.com/nvm-sh/nvm). (Node version `v24.13.0` works at time of writing.) 
3. The frontend's Nx and Vite dependencies are installed locally with npm; a global Nx installation is not required for the combined Unix launcher.
4. [Install Tauri CLI](https://v2.tauri.app/reference/cli/). (Version `tauri-cli 2.10.0` works at time of writing.)

**Mac and Linux Development** 

```bash
# Start the frontend and Rust/Tauri together in one terminal
./script/artcraft/unix_dev.sh

# Optionally start the free-port search at another port
ARTCRAFT_DEV_PORT=6200 ./script/artcraft/unix_dev.sh
```

Use the combined launcher instead of starting the two legacy dev scripts. It
works from any working directory when invoked by its path and installs frontend
dependencies if the local Vite installation is missing. Node.js 20+ is required.

The launcher binds Vite to `127.0.0.1`, starting at port **5193** and trying
successive ports until one is available. It leaves existing listeners alone.
Only after the real frontend socket is bound does it start Tauri with that exact
`devUrl`. HTTP and the HMR websocket share the selected port; Rust communicates
through native Tauri IPC and needs no separate HTTP port. Configuration overrides
are passed in memory, without changing the checked-in Tauri config.

The native HTTP bridge normalizes loopback development origins for first-party
API requests so an automatically selected port does not break login or media
loading. See the [desktop session regression checks](../docs/desktop-session-regression.md)
when changing ports, the launcher, or authentication.

JavaScript, TypeScript, React, and CSS changes use Vite hot reload; compatible
React component edits use Fast Refresh. Changes that cannot be hot-replaced
reload the page. Rust changes use `cargo tauri dev`'s automatic **rebuild and app
restart**, including dependent workspace crates. SQLx metadata and SQLite
migrations are also watched. Rust reload is a process restart, so it does not
preserve unsaved in-memory app state. See [Tauri's watch behavior](https://v2.tauri.app/develop/#reacting-to-source-code-changes).

After startup, a Vite configuration restart must reuse the chosen port or report
an error; it cannot silently switch to another port while Tauri uses an old URL.
Ctrl-C stops this session's frontend, Rust watcher/compiler, and desktop app.
If the Rust watcher exits, the launcher closes Vite and propagates the exit code.
It never finds or terminates another app by name or port.

The launcher retains the existing Unix defaults for `VITE_ENVIRONMENT_TYPE`,
`SQLX_OFFLINE`, `RUSTFLAGS`, and the Linux WebKit workarounds. Explicit environment
overrides are preserved. It uses the normal Artcraft app data and Cargo target
directory; port separation does not create an isolated account/data profile, and
concurrent Rust builds can wait on Cargo's build lock.

To verify the launcher without compiling Rust or opening a desktop window:

```bash
node --test frontend/scripts/unix-dev.test.mjs
```

The tests use real Vite listeners and HMR, with a test-owned fake Cargo process
tree. They cover occupied ports, simultaneous launches, React edits, shutdown,
Rust-process failure, and watcher arguments. To verify native Rust reload, run
the launcher, wait for the desktop window, make a Rust source edit, and check for
a rebuild/restart in the same terminal. Frontend edits should update the webview
without restarting the Rust process.

**Windows Development**

```powershell
# Run the frontend dev server
.\script\artcraft\windows_frontend_dev.ps1

# Run the Tauri Rust application
.\script\artcraft\windows_rust_dev.ps1
```

**Windows Production Builds (x64 and ARM64)**

Use PowerShell 7 and install Rust, the Tauri CLI, Node.js, Visual Studio's C++
build tools, and a Windows SDK. ARM64 builds additionally require the MSVC ARM64
build tools. The native HTTP clients need CMake, LLVM (including `libclang.dll`),
Perl, and Go; x64 builds also use NASM. On ARM64, bindgen must load an ARM64
`libclang.dll` when using native ARM64 Rust, even if an x64 PowerShell or installer
is running under emulation. Set `LIBCLANG_PATH` to its directory if discovery fails.

```powershell
rustup target add aarch64-pc-windows-msvc
.\script\artcraft\windows_build.ps1 -Target aarch64-pc-windows-msvc

rustup target add x86_64-pc-windows-msvc
.\script\artcraft\windows_build.ps1 -Target x86_64-pc-windows-msvc
```

Omitting `-Target` selects the Windows OS architecture, not the shell's process
architecture. Use `-NoOpen` to skip opening Explorer. Native ARM64 builds are the
CI path; cross-compiling on x64 needs ARM64 MSVC tools and separate verification
of the native TLS dependencies. The script preserves existing `RUSTFLAGS`, adds
the static CRT flag required by the Windows HTTP build, uses the lockfile and
SQLx offline mode, and stops if dependency installation or compilation fails.

The application is in `<cargo-target-directory>/<target>/release/artcraft.exe`.
NSIS installers are in that directory's `bundle/nsis/` subdirectory. The script
uses Cargo metadata for the target directory, including `CARGO_TARGET_DIR` or
Cargo configuration overrides. ARM64 selects NSIS; x64 keeps the configured
installer types. The NSIS setup program is x86 and runs under Windows emulation,
but its installed ARM64 application is native.

The Windows publish workflow builds x64 on `windows-latest` and ARM64 on
`windows-11-arm`. It can also be started with `workflow_dispatch`; this still
creates or updates the normal **draft** `artcraft-v<version>` release. ARM64 CI
uses native LLVM and clang-cl with Ninja Multi-Config, preserving the MSVC
library directory layout expected by the locked BoringSSL dependency. The
`windows_static_crt.cmake` toolchain selects the non-debug static CRT (`/MT`)
for native C/C++ dependencies in every configuration, matching Rust's
`+crt-static` even for debug tests. Its rules override also handles BoringSSL's
older CMake policy mode, which otherwise adds `/MDd` in Debug and causes
unresolved `__imp_*` CRT symbols when linking the Rust tests. ARM64 CI checks
generated C/C++ compiler commands before building those dependencies. It runs
the native HTTP dependency tests, checks the application PE machine type, and
smoke-tests a separately built no-bundle ARM64 executable before publication.
Installers and staged executables are also retained as Actions artifacts.

The ARM64 release includes `ArtCraft_<version>_windows_arm64.exe` in addition to
the installer. The standalone executable requires an installed **ARM64 WebView2
Runtime**; unlike the installer, it does not provision that runtime. CI rejects
directly imported companion DLLs found in the app output and checks that the
staged app stays alive during startup. This is not a guarantee of full portable
operation or a substitute for clean-machine testing.

Before publishing the draft release, test on Windows ARM64 without development
tools: install, launch, confirm the application runs as ARM64, verify login and
media loading, test the standalone executable with WebView2 installed, and
uninstall. Also verify an existing x64 installation can transition without
losing account/session data. Preserve the current Windows signing policy;
unsigned downloads may still trigger SmartScreen warnings.

Run the focused script tests without Rust compilation or opening the app:

```powershell
pwsh -NoProfile -File .\script\artcraft\windows_build.test.ps1
```

They cover target arguments, OS architecture defaults, Cargo output paths,
preserved flags, failure handling, and acceptance/rejection of PE architectures.
The optional `-CMakePath` and `-NinjaPath` parameters also run a configure-only
fixture with a simulated clang-cl compiler identity, verifying the generated
runtime flags without compiling native code. This complements, rather than
replaces, linking and running the real Rust dependency tests in ARM64 CI.
To inspect a real application payload independently:

```powershell
.\script\artcraft\verify_windows_binary.ps1 `
	-BinaryPath .\target\aarch64-pc-windows-msvc\release\artcraft.exe `
	-Target aarch64-pc-windows-msvc
```

Backend services and website builds live in the separate `artcraft-services` repository.
This repository retains the desktop task database in
`_database/sql/artcraft_migrations/` and its SQLite query cache in `.sqlx/`.
Use `SQLX_OFFLINE=true cargo check -p artcraft` to check Rust without a database server.
