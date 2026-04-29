; ============================================================
; sanix — Stage 2 (Real Mode Shell)
; ------------------------------------------------------------
; Author  : Sanket Bharadwaj
; Version : v0.4
; Mode    : 16-bit Real Mode
; Load    : 0x0000:0x7E00
; Target  : x86 BIOS (QEMU / bare metal)
;
; Description:
;   Minimal interactive shell running in real mode.
;   - VGA text output (0xB8000)
;   - Keyboard input via BIOS (int 0x16)
;   - Command handling: hi, help, clear, echo
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
    mov es, ax                      ; FIX #5 — ES=0x0000 explicit, not implicit
    mov di, input_buf
    xor bx, bx

.key_loop:
    xor ah, ah
    int 0x16                        ; al = ASCII key
    cld                             ; FIX #7 — BIOS may trash DF

    cmp al, 13                      ; Enter
    je  .enter
    cmp al, 8                       ; Backspace
    je  .backspace
    cmp al, 0                       ; FIX — ignore extended keys (al=0 means scancode only)
    je  .key_loop
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

.enter:
    mov byte [di], 0                ; null-terminate
    pop es                          ; restore ES=0x0000
    call newline                    ; FIX #2 — newline owned by input flow here
    ret

; ─────────────────────────────────────────────
; HANDLE COMMAND
; FIX #1 — SI explicitly reset to input_buf before each strcmp
; FIX #8 — trim trailing spaces before compare
; ─────────────────────────────────────────────
handle_command:
    call trim_input                 ; FIX #8 — strip trailing spaces

    mov si, input_buf
    cmp byte [si], 0                ; empty input?
    je  .done

    ; FIX #1 — SI reset before every strcmp call
    mov si, input_buf
    mov di, cmd_hi
    call strcmp
    jz  .cmd_hi

    mov si, input_buf               ; FIX #1 — explicit reset
    mov di, cmd_help
    call strcmp
    jz  .cmd_help

    mov si, input_buf               ; FIX #1 — explicit reset
    mov di, cmd_clear
    call strcmp
    jz  .cmd_clear

    ; echo — prefix match: input_buf starts with "echo" ?
    mov si, input_buf
    mov di, cmd_echo
    call strcmp_prefix
    jz  .cmd_echo

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

.cmd_echo:
    ; SI = input_buf, skip past "echo" (4 chars)
    mov si, input_buf
    add si, 4                       ; SI now points to char after "echo"
    ; skip any spaces
.echo_skip_space:
    mov al, [si]
    cmp al, 0x20
    jne .echo_print
    inc si
    jmp .echo_skip_space
.echo_print:
    ; SI points to message (or null for bare "echo")
    call println
    jmp .done

.done:
    ret

; ─────────────────────────────────────────────
; TRIM_INPUT — FIX #8
; removes trailing spaces from input_buf
; so "hi " matches "hi"
; ─────────────────────────────────────────────
trim_input:
    push si
    push ax
    mov si, input_buf
.find_end:
    mov al, [si]
    test al, al
    jz  .trim                       ; at null — start trimming backwards
    inc si
    jmp .find_end
.trim:
    cmp si, input_buf               ; at start? nothing to trim
    je  .done
    dec si
    mov al, [si]
    cmp al, 0x20                    ; space?
    jne .done
    mov byte [si], 0                ; replace with null
    jmp .trim
.done:
    pop ax
    pop si
    ret

; ─────────────────────────────────────────────
; STRCMP — FIX #1 — fully restores SI and DI
; caller must reset SI before each call
; ZF=1 if strings equal
; ─────────────────────────────────────────────
strcmp:
    push si
    push di
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
    pop di
    pop si
    xor ax, ax                      ; ZF=1
    ret
.neq:
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
.done:
    pop bx
    pop ax
    pop es
    ret

; ─────────────────────────────────────────────
; DATA
; ─────────────────────────────────────────────
msg_banner  db 'sanix v0.4  --  type help', 0
msg_prompt  db '> ', 0
msg_hi      db 'HELLO', 0
msg_help    db 'commands: hi, help, clear, echo', 0
msg_unknown db '?', 0

cmd_hi      db 'hi', 0
cmd_help    db 'help', 0
cmd_clear   db 'clear', 0
cmd_echo    db 'echo', 0

cur_row     dw 0
cur_col     dw 0
input_buf   times BUF_MAX db 0