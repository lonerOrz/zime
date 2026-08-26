# Zime

A Windows input method indicator that shows a small pill when you switch input methods.

Existing tools kept adding AI features nobody asked for, on top of clunky popups, dated UI and ads. Zime does one thing and stays out of the way.

## Installation

1. Download the portable zip from [GitHub Releases](../../releases).
2. Extract and run `zime.exe`.
3. Enable _Autostart_ from the tray menu to launch it on login.

## Building

Requires [Zig 0.16](https://ziglang.org). Runs on Windows 10 and later.

```
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall
```

PRs are welcome.

## License

GNU General Public License v3.0 (GPL-3.0)
