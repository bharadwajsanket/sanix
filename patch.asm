; Feature 3: HARDWARE CURSOR
sync_cursor:
    push ax
    push bx
    push dx
    mov ah, 0x02
    mov bh, 0
    mov dh, byte [cur_row]
    mov dl, byte [cur_col]
    int 0x10
    pop dx
    pop bx
    pop ax
    ret
