; ============================================================
; sanix — Stage 2 (Real Mode Shell)
; ------------------------------------------------------------
; Author  : Sanket Bharadwaj
; Version : v0.7
; Mode    : 16-bit Real Mode
; Load    : 0x0000:0x7E00
; Target  : x86 BIOS (QEMU / bare metal)
;
; Description:
;   Interactive shell in 16-bit real mode.
;   - VGA text output (0xB8000)
;   - Keyboard input via BIOS (int 0x16)
;   - Inline editing: left/right cursor, insert, delete
;   - Command history (UP/DOWN), TAB autocomplete
;   - Hardware cursor sync, scrolling, Ctrl+L clear
;
; Invariants:
;   DS = 0x0000 (except inside scroll — push/pop)
;   ES = 0x0000 (except inside VGA writes — push/pop)
;   DF = 0 always (cld enforced after every rep op / BIOS int)
;
; Input state (during read_line):
;   BX        = buf_len  (total chars in input_buf)
;   [inp_pos] = cur_pos  (cursor offset, 0..buf_len)
;   [line_row] / [line_col] = screen origin of input field
; ============================================================

org 0x7e00

%define VGA_BASE   0xb800
%define COLS       80
%define ROWS       25
%define ATTR       0x07
%define ATTR_GRN   0x0a
%define BUF_MAX    64

start:
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
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
    ; record where input field starts
    mov ax, [cur_row]
    mov [line_row], ax
    mov ax, [cur_col]
    mov [line_col], ax
    call read_line
    call handle_command
    jmp main_loop

; ─────────────────────────────────────────────
; CLEAR SCREEN
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
    pop es
    mov word [cur_row], 0
    mov word [cur_col], 0
    call sync_cursor
    ret

; ─────────────────────────────────────────────
; SCROLL
; ─────────────────────────────────────────────
scroll:
    push ax
    push cx
    push si
    push di
    push es
    push ds
    mov ax, VGA_BASE
    mov ds, ax
    mov es, ax
    mov si, COLS * 2
    xor di, di
    mov cx, (ROWS - 1) * COLS
    rep movsw
    mov cx, COLS
    mov ax, 0x0720
    rep stosw
    pop ds
    pop es
    pop di
    pop si
    pop cx
    pop ax
    cld
    ret

check_scroll:
    cmp word [cur_row], ROWS
    jl  .done
    call scroll
    mov word [cur_row], ROWS - 1
    ; adjust line_row if it was pushed up
    cmp word [line_row], 0
    je  .done
    dec word [line_row]
.done:
    ret

newline:
    mov word [cur_col], 0
    inc word [cur_row]
    call check_scroll
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
; READ LINE — v0.7 inline editing
; BX = buf_len, [inp_pos] = cursor offset
; ─────────────────────────────────────────────
read_line:
    push es
    xor ax, ax
    mov es, ax
    xor bx, bx                      ; buf_len = 0
    mov word [inp_pos], 0           ; cursor at start
    ; clear input_buf
    mov di, input_buf
    mov cx, BUF_MAX
    xor al, al
    rep stosb

.key_loop:
    xor ah, ah
    int 0x16
    cld

    cmp al, 13                      ; Enter
    je  .enter
    cmp al, 8                       ; Backspace
    je  .do_backspace
    cmp al, 9                       ; TAB
    je  .do_tab
    cmp al, 0x0c                    ; Ctrl+L
    je  .do_ctrlL
    cmp al, 0                       ; extended scan
    jne .printable

    ; --- extended keys ---
    cmp ah, 0x48                    ; UP
    je  .do_up
    cmp ah, 0x50                    ; DOWN
    je  .do_down
    cmp ah, 0x4b                    ; LEFT
    je  .do_left
    cmp ah, 0x4d                    ; RIGHT
    je  .do_right
    cmp ah, 0x53                    ; DELETE
    je  .do_delete
    jmp .key_loop                   ; ignore other extended keys

.printable:
    cmp al, 0x20
    jl  .key_loop
    cmp bx, BUF_MAX - 1
    jge .key_loop
    call insert_char                ; inserts AL, updates BX, inp_pos
    jmp .key_loop

.do_backspace:
    cmp word [inp_pos], 0
    je  .key_loop
    dec word [inp_pos]
    dec bx
    ; shift buffer left over the deleted char
    push si
    push di
    push cx
    push es
    push ds
    mov cx, bx
    sub cx, [inp_pos]               ; chars after new position
    inc cx                          ; include null
    mov si, input_buf
    add si, [inp_pos]
    inc si                          ; source: one past deleted char
    mov di, si
    dec di                          ; dest: at deleted char position
    mov ax, ds
    mov es, ax
    rep movsb
    cld
    pop ds
    pop es
    pop cx
    pop di
    pop si
    ; update cur_col to inp_pos, redraw
    mov ax, [line_col]
    add ax, [inp_pos]
    mov [cur_col], ax
    mov ax, [line_row]
    mov [cur_row], ax
    call sync_cursor
    call redraw_tail
    jmp .key_loop

.do_delete:
    mov ax, [inp_pos]
    cmp ax, bx
    jge .key_loop                   ; cursor at end — nothing to delete
    dec bx
    ; shift buffer left
    push si
    push di
    push cx
    push es
    push ds
    mov ax, [inp_pos]
    mov cx, bx
    sub cx, ax                      ; chars to copy
    inc cx                          ; include null
    mov si, input_buf
    add si, [inp_pos]
    inc si
    mov di, si
    dec di
    mov ax, ds
    mov es, ax
    rep movsb
    cld
    pop ds
    pop es
    pop cx
    pop di
    pop si
    call redraw_tail
    jmp .key_loop

.do_left:
    cmp word [inp_pos], 0
    je  .key_loop
    dec word [inp_pos]
    mov ax, [line_col]
    add ax, [inp_pos]
    mov [cur_col], ax
    call sync_cursor
    jmp .key_loop

.do_right:
    mov ax, [inp_pos]
    cmp ax, bx
    jge .key_loop
    inc word [inp_pos]
    mov ax, [line_col]
    add ax, [inp_pos]
    mov [cur_col], ax
    call sync_cursor
    jmp .key_loop

.do_ctrlL:
    call clear_screen
    ; reprint prompt
    call print_prompt
    mov ax, [cur_row]
    mov [line_row], ax
    mov ax, [cur_col]
    mov [line_col], ax
    ; reprint current buffer from start
    mov ax, [line_col]
    mov [cur_col], ax
    push si
    mov si, input_buf
    call print_str
    pop si
    ; restore cursor to inp_pos
    mov ax, [line_col]
    add ax, [inp_pos]
    mov [cur_col], ax
    call sync_cursor
    jmp .key_loop

.do_up:
    mov cx, [hist_count]
    test cx, cx
    jz  .key_loop
    mov ax, [hist_nav_idx]
    inc ax
    cmp ax, cx
    jge .key_loop
    mov [hist_nav_idx], ax
    call load_history               ; clears line, loads, sets BX=len, inp_pos=len
    jmp .key_loop

.do_down:
    mov ax, [hist_nav_idx]
    cmp ax, -1
    je  .key_loop
    dec ax
    mov [hist_nav_idx], ax
    cmp ax, -1
    je  .hist_clear
    call load_history
    jmp .key_loop
.hist_clear:
    call clear_input_line2
    xor bx, bx
    mov word [inp_pos], 0
    mov byte [input_buf], 0
    jmp .key_loop

.do_tab:
    test bx, bx
    jz  .key_loop
    push bx
    push si
    xor cx, cx
    xor dx, dx
    mov si, tab_complete_table
.tab_scan:
    mov di, [si]
    test di, di
    jz  .tab_eval
    push si
    mov si, input_buf
    call is_prefix
    pop si
    jnz .tab_next
    inc cx
    mov dx, di
.tab_next:
    add si, 2
    jmp .tab_scan
.tab_eval:
    pop si
    pop bx
    cmp cx, 1
    jne .key_loop
    ; unique match — replace buffer
    call clear_input_line2
    mov si, dx
    mov di, input_buf
    xor bx, bx
.tab_copy:
    mov al, [si]
    mov [di], al
    test al, al
    jz  .tab_done
    inc si
    inc di
    inc bx
    jmp .tab_copy
.tab_done:
    mov word [inp_pos], bx          ; cursor at end
    mov si, input_buf
    call print_str
    mov ax, [line_col]
    add ax, bx
    mov [cur_col], ax
    call sync_cursor
    jmp .key_loop

.enter:
    mov si, input_buf
    add si, bx
    mov byte [si], 0                ; ensure null-terminated
    pop es
    call newline
    ret

; ─────────────────────────────────────────────
; INSERT_CHAR — inserts AL at inp_pos, shifts right
; Modifies: BX (buf_len++), [inp_pos]++
; All other regs saved
; ─────────────────────────────────────────────
insert_char:
    push ax
    push si
    push di
    push cx
    push es
    push ds

    mov ah, al                      ; save char

    ; shift input_buf[inp_pos..buf_len] right by 1 (backward copy)
    mov cx, bx
    sub cx, [inp_pos]               ; number of chars to shift
    inc cx                          ; include null terminator

    mov si, input_buf
    add si, bx                      ; si = &input_buf[buf_len] (null)
    mov di, si
    inc di                          ; di = &input_buf[buf_len+1]

    mov ax, ds
    mov es, ax
    std
    rep movsb
    cld

    ; write the new character
    mov al, ah
    mov si, input_buf
    add si, [inp_pos]
    mov [si], al

    pop ds
    pop es

    inc bx                          ; buf_len++
    inc word [inp_pos]              ; cursor advances right

    pop cx
    pop di
    pop si
    pop ax

    ; reposition cursor to (line_row, line_col + inp_pos) and redraw right portion
    mov ax, [line_col]
    add ax, [inp_pos]
    dec ax                          ; back one: where new char was inserted
    mov [cur_col], ax
    mov ax, [line_row]
    mov [cur_row], ax
    call sync_cursor
    call redraw_tail
    ret

; ─────────────────────────────────────────────
; REDRAW_TAIL
; Redraws input_buf[inp_pos..buf_len-1] directly to VGA
; Blanks one extra position after (cleans up delete residue)
; Repositions hardware cursor to (line_row, line_col + inp_pos)
; Saves all registers
; ─────────────────────────────────────────────
redraw_tail:
    push ax
    push bx
    push si
    push di
    push cx
    push es

    mov ax, VGA_BASE
    mov es, ax

    ; compute VGA offset for (line_row, line_col + inp_pos)
    mov bx, [line_row]
    mov ax, COLS
    imul bx, ax
    add bx, [line_col]
    add bx, [inp_pos]
    shl bx, 1                       ; BX = VGA byte offset

    mov si, input_buf
    add si, [inp_pos]               ; SI = source in buffer

.draw_loop:
    mov al, [si]
    test al, al
    jz  .draw_done
    mov ah, ATTR
    mov [es:bx], ax
    add bx, 2
    inc si
    jmp .draw_loop
.draw_done:
    ; blank one trailing position (erase stale char after delete)
    mov word [es:bx], 0x0720

    pop es

    ; reposition cursor to inp_pos
    mov ax, [line_col]
    add ax, [inp_pos]
    mov [cur_col], ax
    mov ax, [line_row]
    mov [cur_row], ax
    call sync_cursor

    pop cx
    pop di
    pop si
    pop bx
    pop ax
    ret

; ─────────────────────────────────────────────
; CLEAR_INPUT_LINE2
; Blanks the entire input area on screen
; Resets cur_row/cur_col to line_row/line_col
; Does NOT touch BX or inp_pos (caller does that)
; ─────────────────────────────────────────────
clear_input_line2:
    push ax
    push bx
    push cx
    push di
    push es

    mov ax, VGA_BASE
    mov es, ax

    ; compute VGA offset for (line_row, line_col)
    mov bx, [line_row]
    mov ax, COLS
    imul bx, ax
    add bx, [line_col]
    shl bx, 1

    ; blank from line_col to end of row
    mov di, bx
    mov ax, [line_col]
    mov cx, COLS
    sub cx, ax                      ; chars remaining on line
    mov ax, 0x0720
    rep stosw

    ; reset cursor to start of input field
    mov ax, [line_col]
    mov [cur_col], ax
    mov ax, [line_row]
    mov [cur_row], ax
    call sync_cursor

    pop es
    pop di
    pop cx
    pop bx
    pop ax
    ret

; ─────────────────────────────────────────────
; HANDLE COMMAND
; ─────────────────────────────────────────────
handle_command:
    call trim_input

    mov si, input_buf
    cmp byte [si], 0
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
    int 0x19
    jmp .done
.cmd_halt:
    cli
.hang:
    hlt
    jmp .hang
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
    add si, 4
.echo_skip:
    mov al, [si]
    cmp al, 0x20
    jne .echo_print
    inc si
    jmp .echo_skip
.echo_print:
    call println
    jmp .done
.done:
    ret

; ─────────────────────────────────────────────
; TRIM_INPUT
; ─────────────────────────────────────────────
trim_input:
    push si
    push di
    push ax
    mov si, input_buf
.skip_lead:
    mov al, [si]
    test al, al
    jz  .lead_done
    cmp al, 0x20
    jne .lead_done
    inc si
    jmp .skip_lead
.lead_done:
    mov di, input_buf
    cmp si, di
    je  .trim_trail
.shift:
    mov al, [si]
    mov [di], al
    inc si
    inc di
    test al, al
    jnz .shift
.trim_trail:
    mov si, input_buf
.find_end:
    mov al, [si]
    test al, al
    jz  .trim_back
    inc si
    jmp .find_end
.trim_back:
    cmp si, input_buf
    je  .trim_done
    dec si
    mov al, [si]
    cmp al, 0x20
    jne .trim_done
    mov byte [si], 0
    jmp .trim_back
.trim_done:
    pop ax
    pop di
    pop si
    ret

; ─────────────────────────────────────────────
; STRCMP — ZF=1 if equal. Saves BX, SI, DI.
; ─────────────────────────────────────────────
strcmp:
    push si
    push di
    push bx
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
    xor ax, ax
    ret
.neq:
    pop bx
    pop di
    pop si
    mov ax, 1
    test ax, ax
    ret

; ─────────────────────────────────────────────
; STRCMP_PREFIX — ZF=1 if DI is prefix of SI (SI ends with null or space)
; ─────────────────────────────────────────────
strcmp_prefix:
    push si
    push di
    push ax
.pfx_loop:
    mov al, [di]
    test al, al
    jz  .pfx_check
    mov ah, [si]
    cmp al, ah
    jne .pfx_neq
    inc si
    inc di
    jmp .pfx_loop
.pfx_check:
    mov al, [si]
    test al, al
    jz  .pfx_eq
    cmp al, 0x20
    je  .pfx_eq
.pfx_neq:
    pop ax
    pop di
    pop si
    mov ax, 1
    test ax, ax
    ret
.pfx_eq:
    pop ax
    pop di
    pop si
    xor ax, ax
    ret

; ─────────────────────────────────────────────
; PRINTLN / PRINT_STR / PRINT_STR_GREEN
; ─────────────────────────────────────────────
println:
    call print_str
    call newline
    ret

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

print_char:
    push es
    mov ah, ATTR
    push ax
    mov ax, VGA_BASE
    mov es, ax
    pop ax
    call vga_putchar_attr
    pop es
    ret

vga_putchar:
    mov ah, ATTR
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
    call check_scroll
.done:
    call sync_cursor
    pop dx
    pop bx
    ret

; ─────────────────────────────────────────────
; SYNC_CURSOR — saves AX, BX, DX, ES. Restores DF.
; ─────────────────────────────────────────────
sync_cursor:
    push ax
    push bx
    push dx
    push es
    mov ah, 0x02
    mov bh, 0
    mov dh, byte [cur_row]
    mov dl, byte [cur_col]
    int 0x10
    cld
    pop es
    pop dx
    pop bx
    pop ax
    ret

; ─────────────────────────────────────────────
; LOAD_HISTORY
; Clears line, copies history[hist_nav_idx] to input_buf,
; prints it. Sets BX = new len, inp_pos = BX.
; ─────────────────────────────────────────────
load_history:
    push dx
    call clear_input_line2
    mov ax, [hist_nav_idx]
    mov cx, BUF_MAX
    mul cx                          ; AX = index * BUF_MAX
    pop dx

    mov si, history_buf
    add si, ax
    mov di, input_buf
    xor bx, bx
.copy:
    mov al, [si]
    mov [di], al
    test al, al
    jz  .done
    inc si
    inc di
    inc bx
    jmp .copy
.done:
    mov [inp_pos], bx               ; cursor at end
    mov si, input_buf
    call print_str
    mov ax, [line_col]
    add ax, bx
    mov [cur_col], ax
    call sync_cursor
    ret

; ─────────────────────────────────────────────
; PUSH_HISTORY
; ─────────────────────────────────────────────
push_history:
    push ax
    push bx
    push cx
    push si
    push di

    cmp byte [input_buf], 0
    je  .done

    mov si, input_buf
    mov di, history_buf
    call strcmp
    jz  .done

    push ds
    push es
    mov ax, ds
    mov es, ax
    mov si, history_buf + BUF_MAX * 7 - 1
    mov di, history_buf + BUF_MAX * 8 - 1
    mov cx, BUF_MAX * 7
    std
    rep movsb
    cld
    pop es
    pop ds

    push es
    xor ax, ax
    mov es, ax
    mov si, input_buf
    mov di, history_buf
    mov cx, BUF_MAX
    rep movsb
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

; ─────────────────────────────────────────────
; IS_PREFIX — ZF=1 if SI is a prefix of DI
; ─────────────────────────────────────────────
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
msg_banner      db 'sanix v0.7  --  type help', 0
msg_prompt      db '> ', 0
msg_hi          db 'HELLO', 0
msg_help        db 'commands: hi help clear cls echo reboot halt about version', 0
msg_unknown     db '?', 0

msg_about_name   db 'sanix v0.7', 0
msg_about_author db 'author: Sanket Bharadwaj', 0
msg_about_mode   db 'mode: real mode', 0
msg_version      db 'sanix v0.7', 0

cmd_hi      db 'hi', 0
cmd_help    db 'help', 0
cmd_clear   db 'clear', 0
cmd_cls     db 'cls', 0
cmd_reboot  db 'reboot', 0
cmd_halt    db 'halt', 0
cmd_about   db 'about', 0
cmd_version db 'version', 0
cmd_echo    db 'echo', 0

exact_cmd_table:
    dw cmd_hi,      handle_command.cmd_hi
    dw cmd_help,    handle_command.cmd_help
    dw cmd_clear,   handle_command.cmd_clear
    dw cmd_cls,     handle_command.cmd_clear
    dw cmd_reboot,  handle_command.cmd_reboot
    dw cmd_halt,    handle_command.cmd_halt
    dw cmd_about,   handle_command.cmd_about
    dw cmd_version, handle_command.cmd_version
    dw 0

prefix_cmd_table:
    dw cmd_echo, handle_command.cmd_echo
    dw 0

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

hist_count   dw 0
hist_nav_idx dw -1
history_buf  times BUF_MAX * 8 db 0

inp_pos  dw 0
line_row dw 0
line_col dw 0

cur_row     dw 0
cur_col     dw 0
input_buf   times BUF_MAX db 0