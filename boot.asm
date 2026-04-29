; ============================================================
; sanix — Stage 1 Bootloader (MBR)
; ------------------------------------------------------------
; Author  : Sanket Bharadwaj
; Version : v0.3
; Mode    : 16-bit Real Mode
; Load    : 0x0000:0x7C00 (BIOS)
; Target  : x86 BIOS (QEMU / bare metal)
;
; Description:
;   Minimal 512-byte bootloader.
;   - Loaded by BIOS at 0x7C00
;   - Sets up segments and stack
;   - Loads Stage 2 from disk (INT 13h)
;   - Jumps to 0x0000:0x7E00
;
; Constraints:
;   - Exactly 512 bytes
;   - Boot signature 0xAA55 required
;
; ============================================================

org 0x7c00

jmp start

start:
    ; ------------------------
    ; SETUP
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    mov [BOOT_DRIVE], dl

    ; ------------------------
    ; LOAD STAGE 2 → 0000:7E00
    ; set ES:BX = 0x0000:0x7E00 FIRST, before touching AX
    xor ax, ax
    mov es, ax
    mov bx, 0x7e00

    ; NOW set up int 0x13 params (AX must be set last)
    mov ah, 0x02    ; function: read sectors
    mov al, 2       ; number of sectors
    mov ch, 0       ; cylinder 0
    mov cl, 2       ; sector 2 (1-indexed)
    mov dh, 0       ; head 0
    mov dl, [BOOT_DRIVE]

    int 0x13
    jc disk_error

    ; ------------------------
    ; FAR JUMP TO STAGE 2
    jmp 0x0000:0x7E00

; ------------------------
disk_error:
    mov ax, 0xb800
    mov es, ax
    mov di, 0

    mov si, err_msg
.print:
    lodsb
    cmp al, 0
    je $
    mov ah, 0x07
    stosw
    jmp .print

; ------------------------
err_msg db 'DISK ERROR', 0
BOOT_DRIVE db 0

times 510 - ($ - $$) db 0
dw 0xaa55