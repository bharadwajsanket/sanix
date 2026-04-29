# Changelog

All notable changes to this project will be documented here.

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