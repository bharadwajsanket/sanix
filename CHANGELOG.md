# Changelog

All notable changes to this project will be documented here.

---

## [v0.7] - 2026-05-09

### Added
- **Inline cursor movement** — LEFT/RIGHT arrows move cursor within typed input; boundaries enforced at both ends.
- **Inline character insertion** — typing in the middle shifts the buffer right (backward `rep movsb`) and redraws the tail.
- **Delete key** — removes character *under* cursor, shifts buffer left, redraws tail without stale characters.
- **`redraw_tail`** — unified direct VGA write helper used by insert, delete, backspace; repositions hardware cursor after every edit.
- **`clear_input_line2`** — blanks the entire input area in one VGA `rep stosw` pass; replaces cursor_back loop.
- **Ctrl+L** — clears screen, reprints prompt + current buffer, repositions cursor to `inp_pos`.
- **`inp_pos` / `line_row` / `line_col`** — new memory variables tracking cursor offset and input field screen origin.
- **`check_scroll` adjusts `line_row`** — if scroll fires during output, `line_row` is decremented to stay accurate.

### Changed
- `read_line` fully restructured around `inp_pos`; BX still = `buf_len`.
- `load_history` rewritten to use `clear_input_line2` and set `inp_pos = buf_len`.
- History UP/DOWN now leaves cursor at end of restored line (correct for further editing).
- TAB autocomplete uses `clear_input_line2`; `inp_pos` set to completed command length.
- `vga_putchar_attr` no longer calls `sync_cursor` inline (removed redundancy; `redraw_tail` positions at end).
- Banner, version strings, and `msg_help` bumped to v0.7.
- `boot.asm` sector count raised to **5** (stage2.bin now ~2410 bytes).

### Notes
- Input line is guaranteed ≤ 63 chars + prompt = ≤ 65 cols — no line wrapping needed.
- All `std` + `rep movsb` blocks immediately followed by `cld` (DF invariant preserved).
- `sync_cursor` saves/restores ES and calls `cld` after `int 0x10` (INT 10h corruption prevented).

---


## [v0.6] - 2026-05-07

### Added
- **Command History** — Navigate previous commands using UP/DOWN arrow keys (maintains up to 8 commands, ignores empty strings).
- **Hardware Cursor Sync** — Visible blinking hardware cursor stays synchronized with input line and scrolling using BIOS INT 10h.
- **TAB Autocomplete** — Basic unique-match prefix autocomplete for all known commands.
- `cls` alias — exact alias for the `clear` command.
- `version` command — prints the current shell version.

### Changed
- Command dispatch refactored to use data tables (`exact_cmd_table` and `prefix_cmd_table`), drastically simplifying `handle_command` layout and removing duplicated comparison blocks.
- Arrow keys correctly mapped from BIOS extended scancodes (`AH=0x48` for UP, `AH=0x50` for DOWN).
- Version strings and prompts bumped to `v0.6`.

### Notes
- Extensively preserved the 16-bit real-mode architecture without adding overhead.
- All hardware constraints intact: `DS=0x0000`, `DF=0`.

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