; ==================================================================
; x16-PRos - XOR encryption/decryption (safe, optimized version)
; ==================================================================

key db 0x5C, 0x44, 0xCF, 0x08, 0x8B, 0x47, 0x1B, 0x33, 0x2C, 0x8E, 0xB9, 0x59, 0xA2, 0x3A, 0x46, 0xAF, 
    db 0x0A, 0x9E, 0xC7, 0x3D, 0x63, 0x59, 0x08, 0x5F, 0x89, 0x06, 0x8A, 0x07, 0xB3, 0xF7, 0x96, 0x09, 
    db 0x73, 0x03, 0xBB, 0x3F, 0x30, 0x97, 0x63, 0x7C, 0xB7, 0x16, 0xD7, 0xD3, 0xD2, 0x8D, 0x10, 0x36, 
    db 0x2D, 0x1E, 0xDF, 0x33, 0x6F, 0x0B, 0x5B, 0x1B, 0x53, 0x42, 0xF9, 0x02, 0x78, 0xB7, 0x53, 0xE1
key_len equ 64

; ------------------------------------------------------------------
; encrypt_string / decrypt_string
; IN:  SI=input, DI=output, CX=len (0=null-terminated)
; OUT: encrypted/decrypted DI buffer, CF=0 OK
; ------------------------------------------------------------------

encrypt_string:
    pusha
    xor bx, bx             ; key index

.next_chr:
    ; Якщо довжина відома (CX != 0)
    cmp cx, 0
    jne .load_fixed

    ; Якщо CX=0 → працюємо по null-terminated
    lodsb
    cmp al, 0
    je .done
    jmp .xor_process

.load_fixed:
    ; Завантаження байта з SI (fixed length)
    lodsb

.xor_process:
    ; XOR з ключем
    mov dl, key_len - 1
    and bx, dl
    xor al, [key + bx]

    stosb                ; запис у DI
    inc bx               ; оновити key index

    ; Зменшити CX (тільки якщо режим fixed)
    cmp cx, 0
    je .next_chr
    dec cx
    jnz .next_chr
    jmp .done

.done:
    mov byte [di], 0     ; terminate string
    popa
    clc
    ret

decrypt_string:
    jmp encrypt_string
