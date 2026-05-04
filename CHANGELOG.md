# Changelog

All notable changes to this project will be documented here.

---

## [v0.5] - 2026-05-04

### Added
- **Leading-space trim** — `trim_input` now shifts buffer content left to remove
  leading spaces before any command matching (`   hi` → `hi`)
- `reboot` command — triggers a BIOS warm reboot via `INT 0x19`
- `halt` command — disables interrupts (`cli`) and loops on `hlt`; CPU stops cleanly
- `about` command — prints three lines: `sanix v0.5`, `author: Sanket Bharadwaj`, `mode: real mode`
- New command strings in data section: `cmd_reboot`, `cmd_halt`, `cmd_about`
- New message strings: `msg_about_name`, `msg_about_author`, `msg_about_mode`

### Changed
- `trim_input` rewritten — Phase 1 strips leading spaces (in-buffer shift), Phase 2 strips trailing spaces
- `handle_command` dispatch order formalised: exact → prefix → fallback
- `msg_help` updated to list all seven commands
- Banner bumped to `sanix v0.5  --  type help`
- Version header in `stage2.asm` and `boot.asm` bumped to `v0.5`

### Notes
- `reboot` and `halt` are both exact-match commands (no args) — handled by `strcmp`
- `trim_input` uses only `DS:offset` reads/writes — ES and DF untouched
- `halt` is intentionally non-returning; the `jmp .done` after `hlt` is unreachable dead code for NASM
- All existing commands (`hi`, `help`, `clear`, `echo`) unchanged and verified working

---

## [v0.4] - 2026-04-29

### Added
- `echo` command — prints everything after `echo` verbatim; bare `echo` outputs a blank line
- `strcmp_prefix` helper — checks whether a command word is a leading-space-bounded prefix of
  the input buffer (enables argument-bearing commands without breaking exact-match dispatch)
- `cmd_echo` data string in the data section

### Changed
- Version bumped to `v0.4` in both `boot.asm` and `stage2.asm` headers
- On-screen banner updated to `sanix v0.4  --  type help`

### Notes
- `echo` handles leading spaces after the command word (`echo   hi` → `hi`)
- Does not affect `hi`, `help`, `clear`, or `trim_input` — zero regressions
- `strcmp_prefix` is safe to reuse for any future argument-bearing commands

---

## [v0.3] - Interactive Shell Complete

### Added
- Interactive shell loop (`print_prompt → read_line → handle_command`)
- Command system: `hi`, `help`, `clear`
- VGA text output via direct memory access (`0xB8000`)
- Keyboard input using BIOS `int 0x16`
- Backspace support with on-screen erase
- Cursor tracking using `cur_row`, `cur_col`
- Screen scrolling (row shift + last row clear)

### Fixed
- Direction Flag (DF) corruption after BIOS interrupts (`cld` enforced)
- DS corruption during `scroll` (push/pop DS)
- ES misuse in input buffer (`stosb` safety)
- Incorrect sector loading (stage2 fully loaded)
- Far jump address mismatch (corrected to `0x0000:0x7E00`)
- Input buffer corruption due to DF issues
- Command matching failures in `strcmp`

### Notes
- System is fully functional in 16-bit real mode
- No OS, no libc — direct hardware interaction only
- Stable base for further development

---

## [v0.2] - Basic Shell (Unstable)

### Added
- Initial command handling structure
- Basic input buffer
- Simple VGA printing routines

### Issues
- No proper scrolling
- Input corruption due to DF mismanagement
- DS/ES register instability
- Partial stage2 loading (missing data section)
- Command matching unreliable

---

## [v0.1] - Boot + Static Output

### Added
- Stage 1 bootloader (512 bytes, BIOS-loaded at `0x7C00`)
- Stage 2 loader via `int 0x13`
- Far jump to `0x0000:0x7E00`
- Static VGA text output (no interaction)

### Notes
- Proof of boot pipeline working
- No input, no shell logic