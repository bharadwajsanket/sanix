; ============================================================
; sanix — Stage 2 (Real Mode Shell)
; ------------------------------------------------------------
; Author  : Sanket Bharadwaj
; Version : v0.6
; Mode    : 16-bit Real Mode
; Load    : 0x0000:0x7E00
; Target  : x86 BIOS (QEMU / bare metal)
;
; Description:
;   Minimal interactive shell running in real mode.
;   - VGA text output (0xB8000)
;   - Keyboard input via BIOS (int 0x16)
;   - Command handling: hi, help, clear, echo, reboot, halt, about
;   - Cursor + scrolling support
;
; Invariants:
;   DS = 0x0000 (except inside scroll)
;   ES = 0x0000 (except inside VGA writes)
;   DF = 0 always (cld enforced)
;
; ============================================================

org 0x7e00

; ─────────────────────────────────────────────
; CONSTANTS
; ─────────────────────────────────────────────
%define VGA_BASE    0xb800          ; VGA text buffer segment
%define COLS        80
%define ROWS        25
%define ATTR        0x07            ; white on black
%define ATTR_GRN    0x0a            ; bright green on black
%define BUF_MAX     64

; ─────────────────────────────────────────────
; INVARIANTS (must hold at all call boundaries)
;   DS = 0x0000  at all times except inside scroll (push/pop)
;   ES = 0x0000  at all times except inside VGA writers (push/pop)
;   DF = 0       at all times (cld on entry + after every int 0x16)
; ─────────────────────────────────────────────

start:
    cld                             ; FIX #7 — DF=0, set once at entry
    xor ax, ax
    mov ds, ax
    mov es, ax                      ; ES=0x0000 baseline
    mov ss, ax
    mov sp, 0x7c00

    mov word [cur_row], 0
    mov word [cur_col], 0

    call clear_screen

    mov si, msg_banner
    call println

main_loop:
    mov word [hist_nav_idx], -1
    call print_prompt
    call read_line
    call handle_command
    jmp main_loop

; ─────────────────────────────────────────────
; CLEAR SCREEN
; does not touch DS or ES on exit
; ─────────────────────────────────────────────
clear_screen:
    push es
    push di
    push cx
    push ax
    mov ax, VGA_BASE
    mov es, ax
    xor di, di
    mov cx, COLS * ROWS
    mov ax, 0x0720
    rep stosw
    pop ax
    pop cx
    pop di
    pop es                          ; ES restored to 0x0000
    mov word [cur_row], 0
    mov word [cur_col], 0
    call sync_cursor
    ret

; ─────────────────────────────────────────────
; SCROLL — single unified entry point
; FIX #6 — only called from check_scroll, nowhere else
; FIX #3 — cur_row clamped here and only here
; ─────────────────────────────────────────────
scroll:
    push ax
    push cx
    push si
    push di
    push es
    push ds                         ; FIX: DS saved before changing

    mov ax, VGA_BASE
    mov ds, ax
    mov es, ax

    mov si, COLS * 2                ; src = start of row 1
    xor di, di                      ; dst = start of row 0
    mov cx, (ROWS - 1) * COLS
    rep movsw

    mov cx, COLS                    ; clear last row
    mov ax, 0x0720
    rep stosw

    pop ds                          ; DS = 0x0000 restored
    pop es                          ; ES = 0x0000 restored
    pop di
    pop si
    pop cx
    pop ax
    cld                             ; DF=0 restored after rep ops
    ret

; ─────────────────────────────────────────────
; CHECK_SCROLL — FIX #6 — single scroll trigger
; call after any cur_row increment
; ─────────────────────────────────────────────
check_scroll:
    cmp word [cur_row], ROWS
    jl  .done
    call scroll
    mov word [cur_row], ROWS - 1    ; FIX #3 — clamp in one place
.done:
    ret

; ─────────────────────────────────────────────
; NEWLINE — FIX #2 — only increments row, calls check_scroll
; does NOT own scroll logic directly
; ─────────────────────────────────────────────
newline:
    mov word [cur_col], 0
    inc word [cur_row]
    call check_scroll               ; FIX #3/#6 — unified path
    call sync_cursor
    ret

; ─────────────────────────────────────────────
; PRINT PROMPT
; ─────────────────────────────────────────────
print_prompt:
    mov si, msg_prompt
    call print_str_green
    ret

; ─────────────────────────────────────────────
; READ LINE → input_buf (null-terminated)
; FIX #5 — ES explicitly set to 0x0000 before stosb
; ─────────────────────────────────────────────
read_line:
    push es
    xor ax, ax
    mov es, ax                      ; ES=0x0000 for stosb
    mov di, input_buf
    xor bx, bx
    ; note: cursor already positioned by print_prompt — no sync needed here

.key_loop:
    xor ah, ah
    int 0x16                        ; al = ASCII key
    cld                             ; FIX #7 — BIOS may trash DF

    cmp al, 13                      ; Enter
    je  .enter
    cmp al, 8                       ; Backspace
    je  .backspace
    cmp al, 9                       ; TAB
    je  .handle_tab
    cmp al, 0                       ; Extended key
    jne .not_ext

    cmp ah, 0x48                    ; UP
    je  .handle_up
    cmp ah, 0x50                    ; DOWN
    je  .handle_down
    jmp .key_loop

.not_ext:
    cmp al, 0x20                    ; FIX #7 — ignore non-printable chars below space
    jl  .key_loop
    cmp bx, BUF_MAX - 1             ; buffer full?
    jge .key_loop

    stosb                           ; ES:DI — ES=0x0000 guaranteed above
    inc bx
    call print_char
    jmp .key_loop

.backspace:
    test bx, bx
    jz  .key_loop
    dec bx
    dec di
    mov byte [di], 0
    call cursor_back
    jmp .key_loop

.handle_up:
    mov cx, [hist_count]
    test cx, cx
    jz  .key_loop
    mov ax, [hist_nav_idx]
    inc ax
    cmp ax, cx
    jge .key_loop
    mov [hist_nav_idx], ax
    call load_history
    mov di, input_buf
    add di, bx
    jmp .key_loop

.handle_down:
    mov ax, [hist_nav_idx]
    cmp ax, -1
    je  .key_loop
    dec ax
    mov [hist_nav_idx], ax
    cmp ax, -1
    je  .clear_for_down
    call load_history
    mov di, input_buf
    add di, bx
    jmp .key_loop

.clear_for_down:
    call clear_input_line
    mov di, input_buf
    mov byte [di], 0
    xor bx, bx
    jmp .key_loop

.handle_tab:
    test bx, bx                     ; nothing typed — do nothing
    jz  .key_loop

    ; ── scan tab_complete_table for unique prefix match ──
    push bx                         ; save current char count
    push si                         ; save SI (clobbered by scan)
    xor cx, cx                      ; cx = match count
    xor dx, dx                      ; dx = matched string address
    mov si, tab_complete_table      ; SI walks the pointer list

.tab_scan:
    mov di, [si]                    ; DI = next candidate string address
    test di, di                     ; zero terminator?
    jz  .tab_done
    push si                         ; save table position
    mov si, input_buf               ; compare input against candidate
    call is_prefix                  ; ZF=1 if input is prefix of candidate
    pop si
    jnz .tab_next                   ; no match — advance
    inc cx                          ; match found
    mov dx, di                      ; save matched string address
.tab_next:
    add si, 2                       ; each table entry is one word (dw)
    jmp .tab_scan

.tab_done:
    pop si                          ; restore SI
    pop bx                          ; restore char count
    cmp cx, 1                       ; unique match?
    jne .key_loop                   ; 0 or >1 matches — do nothing

    ; ── unique match: clear current input and insert completed command ──
    call clear_input_line           ; erase typed chars (uses bx as count)
    mov si, dx                      ; SI = matched command string
    mov di, input_buf
.tab_copy:
    mov al, [si]
    mov [di], al
    test al, al
    jz  .tab_copy_done
    inc si
    inc di
    jmp .tab_copy
.tab_copy_done:
    mov bx, di
    sub bx, input_buf               ; bx = new char count
    mov si, input_buf
    call print_str                  ; render completed command
    mov di, input_buf
    add di, bx                      ; di = end of input_buf
    jmp .key_loop

.enter:
    mov byte [di], 0                ; null-terminate
    pop es                          ; restore ES=0x0000
    call newline                    ; FIX #2 — newline owned by input flow here
    ret

; ─────────────────────────────────────────────
; HANDLE COMMAND
; Order: trim → empty check → exact matches → prefix matches → fallback
; ─────────────────────────────────────────────
handle_command:
    call trim_input                 ; strips leading AND trailing spaces

    mov si, input_buf
    cmp byte [si], 0                ; empty input after trim?
    je  .done

    call push_history

    mov bx, exact_cmd_table
.check_exact:
    mov di, [bx]
    test di, di
    jz  .check_prefix
    mov si, input_buf
    call strcmp
    jz  .exact_match
    add bx, 4
    jmp .check_exact

.exact_match:
    mov ax, [bx+2]
    jmp ax

.check_prefix:
    mov bx, prefix_cmd_table
.check_prefix_loop:
    mov di, [bx]
    test di, di
    jz  .fallback
    mov si, input_buf
    call strcmp_prefix
    jz  .prefix_match
    add bx, 4
    jmp .check_prefix_loop

.prefix_match:
    mov ax, [bx+2]
    jmp ax

.fallback:
    mov si, msg_unknown
    call println
    jmp .done

.cmd_hi:
    mov si, msg_hi
    call println
    jmp .done

.cmd_help:
    mov si, msg_help
    call println
    jmp .done

.cmd_clear:
    call clear_screen
    jmp .done

.cmd_reboot:
    mov ax, 0
    int 0x19                        ; BIOS warm reboot
    jmp .done                       ; never reached

.cmd_halt:
    cli                             ; disable interrupts
.hang:
    hlt
    jmp .hang                       ; loop — CPU is stopped

.cmd_about:
    mov si, msg_about_name
    call println
    mov si, msg_about_author
    call println
    mov si, msg_about_mode
    call println
    jmp .done

.cmd_version:
    mov si, msg_version
    call println
    jmp .done

.cmd_echo:
    mov si, input_buf
    add si, 4                       ; skip past "echo"
.echo_skip_space:
    mov al, [si]
    cmp al, 0x20
    jne .echo_print
    inc si
    jmp .echo_skip_space
.echo_print:
    call println                    ; SI = message or null (blank line)
    jmp .done

.done:
    ret

; ─────────────────────────────────────────────
; TRIM_INPUT
; 1) Trims leading spaces  — shifts content left in buffer
; 2) Trims trailing spaces — writes null over them
; Invariants: DS=0x0000, no ES/DF touch, stack balanced
; ─────────────────────────────────────────────
trim_input:
    push si
    push di
    push ax

    ; ── Phase 1: trim leading spaces ───────────
    mov si, input_buf               ; SI = read pointer
.skip_leading:
    mov al, [si]
    test al, al
    jz  .leading_done               ; empty string — nothing to do
    cmp al, 0x20
    jne .leading_done               ; found first non-space
    inc si
    jmp .skip_leading
.leading_done:
    ; shift [si..] left to input_buf
    mov di, input_buf
    cmp si, di
    je  .trim_trailing              ; no leading spaces — skip copy
.shift_loop:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    test al, al
    jnz .shift_loop                 ; stop after copying the null

    ; ── Phase 2: trim trailing spaces ──────────
.trim_trailing:
    mov si, input_buf
.find_end:
    mov al, [si]
    test al, al
    jz  .trim_back
    inc si
    jmp .find_end
.trim_back:
    cmp si, input_buf
    je  .done
    dec si
    mov al, [si]
    cmp al, 0x20
    jne .done
    mov byte [si], 0
    jmp .trim_back

.done:
    pop ax
    pop di
    pop si
    ret

; ─────────────────────────────────────────────
; STRCMP — ZF=1 if strings equal, ZF=0 otherwise
; Saves/restores SI, DI, BX. Clobbers AX only.
; ─────────────────────────────────────────────
strcmp:
    push si
    push di
    push bx                         ; BUG FIX: BL used as scratch; BX is table pointer in handle_command
.loop:
    mov al, [si]
    mov bl, [di]
    cmp al, bl
    jne .neq
    test al, al
    jz  .eq
    inc si
    inc di
    jmp .loop
.eq:
    pop bx
    pop di
    pop si
    xor ax, ax                      ; ZF=1
    ret
.neq:
    pop bx
    pop di
    pop si
    mov ax, 1
    test ax, ax                     ; ZF=0
    ret

; ─────────────────────────────────────────────
; STRCMP_PREFIX
; Returns ZF=1 if the null-terminated string at DI is a
; prefix of the string at SI, AND the next char in SI is
; either null (exact match) or a space (argument follows).
; i.e. "echo" matches "echo", "echo hello", "echo  x"
; Clobbers: nothing (SI, DI, AX saved/restored)
; ─────────────────────────────────────────────
strcmp_prefix:
    push si
    push di
    push ax
.pfx_loop:
    mov al, [di]
    test al, al
    jz  .pfx_check          ; reached end of prefix string
    mov ah, [si]
    cmp al, ah
    jne .pfx_neq
    inc si
    inc di
    jmp .pfx_loop
.pfx_check:
    ; DI exhausted — check that SI char is null or space
    mov al, [si]
    test al, al
    jz  .pfx_eq             ; exact command, no args
    cmp al, 0x20
    je  .pfx_eq             ; command followed by space + args
.pfx_neq:
    pop ax
    pop di
    pop si
    mov ax, 1
    test ax, ax             ; ZF=0
    ret
.pfx_eq:
    pop ax
    pop di
    pop si
    xor ax, ax              ; ZF=1
    ret

; ─────────────────────────────────────────────
; PRINTLN
; ─────────────────────────────────────────────
println:
    call print_str
    call newline
    ret

; ─────────────────────────────────────────────
; PRINT_STR — saves/restores ES
; ─────────────────────────────────────────────
print_str:
    push ax
    push es
    mov ax, VGA_BASE
    mov es, ax
.loop:
    lodsb
    test al, al
    jz  .done
    call vga_putchar
    jmp .loop
.done:
    pop es
    pop ax
    ret

; ─────────────────────────────────────────────
; PRINT_STR_GREEN — saves/restores ES
; ─────────────────────────────────────────────
print_str_green:
    push ax
    push es
    mov ax, VGA_BASE
    mov es, ax
.loop:
    lodsb
    test al, al
    jz  .done
    mov ah, ATTR_GRN
    call vga_putchar_attr
    jmp .loop
.done:
    pop es
    pop ax
    ret

; ─────────────────────────────────────────────
; PRINT_CHAR — FIX #4 — simplified, no nested push/pop AX trick
; AL = char to print at current cursor position
; ─────────────────────────────────────────────
print_char:
    push es
    mov ah, ATTR                    ; FIX #4 — set AH directly, no stack juggle
    push ax                         ; save char+attr
    mov ax, VGA_BASE
    mov es, ax
    pop ax                          ; restore char+attr
    call vga_putchar_attr
    pop es
    ret

; ─────────────────────────────────────────────
; VGA_PUTCHAR — sets ATTR then falls through
; ─────────────────────────────────────────────
vga_putchar:
    mov ah, ATTR

; ─────────────────────────────────────────────
; VGA_PUTCHAR_ATTR — AL=char AH=attr ES=VGA_BASE
; FIX #6 — scroll triggered via check_scroll only
; ─────────────────────────────────────────────
vga_putchar_attr:
    push bx
    push dx
    push ax
    mov bx, [cur_row]
    mov dx, COLS
    imul bx, dx
    add bx, [cur_col]
    shl bx, 1
    pop ax
    mov [es:bx], ax
    inc word [cur_col]
    cmp word [cur_col], COLS
    jl  .done
    mov word [cur_col], 0
    inc word [cur_row]
    call check_scroll               ; FIX #6 — unified scroll trigger
.done:
    call sync_cursor
    pop dx
    pop bx
    ret

; ─────────────────────────────────────────────
; CURSOR_BACK — erase last char on screen
; ─────────────────────────────────────────────
cursor_back:
    push es
    push ax
    push bx
    cmp word [cur_col], 0
    je  .done
    dec word [cur_col]
    mov ax, VGA_BASE
    mov es, ax
    mov bx, [cur_row]
    mov ax, COLS
    imul bx, ax
    add bx, [cur_col]
    shl bx, 1
    mov word [es:bx], 0x0720
    call sync_cursor
.done:
    pop bx
    pop ax
    pop es
    ret

; ─────────────────────────────────────────────
; SYNC_CURSOR — moves hardware cursor to cur_row/cur_col
; Uses BIOS INT 10h AH=02h.
; Saves/restores: AX, BX, DX, ES. Restores DF=0.
; ─────────────────────────────────────────────
sync_cursor:
    push ax
    push bx
    push dx
    push es                         ; BUG FIX: INT 10h may corrupt ES
    mov ah, 0x02
    mov bh, 0
    mov dh, byte [cur_row]
    mov dl, byte [cur_col]
    int 0x10
    cld                             ; BIOS may trash DF — restore invariant
    pop es                          ; restore ES exactly as caller left it
    pop dx
    pop bx
    pop ax
    ret

clear_input_line:
    push ax
    push cx
    mov cx, bx
    test cx, cx
    jz  .done
.loop:
    call cursor_back
    dec cx
    jnz .loop
.done:
    pop cx
    pop ax
    ret

; ─────────────────────────────────────────────
; LOAD_HISTORY
; Clears current input line, copies history[hist_nav_idx]
; into input_buf, prints it, and updates BX = new length.
; Clobbers: AX, BX, CX, DX, SI, DI (intentional — callers reload these)
; ─────────────────────────────────────────────
load_history:
    push dx                         ; save DX — mul will clobber it
    call clear_input_line
    mov ax, [hist_nav_idx]
    mov cx, BUF_MAX
    mul cx                          ; AX = hist_nav_idx * BUF_MAX  (DX=0 always, fits 16-bit)
    pop dx                          ; restore DX before any further ops
    
    mov si, history_buf
    add si, ax
    mov di, input_buf
.copy_loop:
    mov al, [si]
    mov [di], al
    test al, al
    jz  .copy_done
    inc si
    inc di
    jmp .copy_loop
.copy_done:
    mov bx, di
    sub bx, input_buf               ; BX = length of loaded string (intentionally returned)
    mov si, input_buf
    call print_str
    ret

; ─────────────────────────────────────────────
; PUSH_HISTORY
; Prepends current input_buf to history ring (max 8).
; Skips empty input and exact duplicate of most-recent.
; Saves: AX, BX, CX, SI, DI (via push/pop).
; DS and ES are explicitly managed and restored.
; DF is always restored to 0 before return.
; ─────────────────────────────────────────────
push_history:
    push ax
    push bx
    push cx
    push si
    push di

    cmp byte [input_buf], 0         ; empty command — skip
    je  .done

    mov si, input_buf
    mov di, history_buf
    call strcmp                     ; duplicate of most-recent — skip
    jz  .done

    ; ── Phase 1: shift history ring backward by one slot ──
    ; We copy from slot 0..6 → slot 1..7 (backwards to avoid overlap)
    ; Using std+rep movsb: SI points to last byte of slot 6, DI to last of slot 7
    push ds
    push es
    mov ax, ds                      ; DS = 0x0000
    mov es, ax                      ; ES = 0x0000 (same segment for movsb)
    mov si, history_buf + BUF_MAX * 7 - 1   ; last byte of slot 6
    mov di, history_buf + BUF_MAX * 8 - 1   ; last byte of slot 7
    mov cx, BUF_MAX * 7
    std                             ; direction: descending
    rep movsb
    cld                             ; DF=0 restored — critical invariant
    pop es
    pop ds

    ; ── Phase 2: copy input_buf into slot 0 ──
    ; DS=0x0000, ES=0x0000 now — forward copy is safe
    push es
    xor ax, ax
    mov es, ax                      ; ensure ES=0x0000 explicitly
    mov si, input_buf
    mov di, history_buf
    mov cx, BUF_MAX
    rep movsb                       ; DF=0, forward copy
    pop es

    cmp word [hist_count], 8
    je  .done
    inc word [hist_count]
.done:
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

is_prefix:
    push si
    push di
.loop:
    mov al, [si]
    test al, al
    jz  .match
    mov ah, [di]
    test ah, ah
    jz  .no_match
    cmp al, ah
    jne .no_match
    inc si
    inc di
    jmp .loop
.match:
    pop di
    pop si
    xor ax, ax
    ret
.no_match:
    pop di
    pop si
    mov ax, 1
    test ax, ax
    ret

; ─────────────────────────────────────────────
; DATA
; ─────────────────────────────────────────────
msg_banner      db 'sanix v0.6  --  type help', 0
msg_prompt      db '> ', 0
msg_hi          db 'HELLO', 0
msg_help        db 'commands: hi, help, clear, cls, echo, reboot, halt, about, version', 0
msg_unknown     db '?', 0

msg_about_name   db 'sanix v0.6', 0
msg_about_author db 'author: Sanket Bharadwaj', 0
msg_about_mode   db 'mode: real mode', 0

cmd_hi      db 'hi', 0
cmd_help    db 'help', 0
cmd_clear   db 'clear', 0
cmd_cls     db 'cls', 0
cmd_reboot  db 'reboot', 0
cmd_halt    db 'halt', 0
cmd_about   db 'about', 0
cmd_version db 'version', 0
cmd_echo    db 'echo', 0

msg_version db 'sanix v0.6', 0

exact_cmd_table:
    dw cmd_hi, handle_command.cmd_hi
    dw cmd_help, handle_command.cmd_help
    dw cmd_clear, handle_command.cmd_clear
    dw cmd_cls, handle_command.cmd_clear
    dw cmd_reboot, handle_command.cmd_reboot
    dw cmd_halt, handle_command.cmd_halt
    dw cmd_about, handle_command.cmd_about
    dw cmd_version, handle_command.cmd_version
    dw 0

; flat pointer list — each entry is dw ptr, terminated by dw 0
; used ONLY for TAB autocomplete (no handler addresses, no stride issues)
tab_complete_table:
    dw cmd_hi
    dw cmd_help
    dw cmd_clear
    dw cmd_cls
    dw cmd_reboot
    dw cmd_halt
    dw cmd_about
    dw cmd_version
    dw cmd_echo
    dw 0

; dispatcher prefix table (4-byte entries: {cmd_string, handler_addr})
prefix_cmd_table:
    dw cmd_echo, handle_command.cmd_echo
    dw 0

hist_count   dw 0
hist_nav_idx dw -1
history_buf  times BUF_MAX * 8 db 0

cur_row     dw 0
cur_col     dw 0
input_buf   times BUF_MAX db 0