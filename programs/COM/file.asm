; Min; ======================================================================
; Nano File Manager (NFM) for DOS, FAT-compatible via DOS INT 21h
;   - Build: nasm -f bin nano-fm.asm -o NFM.COM
;   - Keys: ↑/↓ select, Enter cd (if dir), Backspace cd .., Del delete, Esc quit
;   - Uses DOS FindFirst/FindNext (AH=4Eh/4Fh), SetDTA (AH=1Ah)
;   - Screen: BIOS teletype INT 10h/AH=0Eh, cursor INT 10h/AH=02h
;   - Keyboard: INT 16h/AH=10h (AL=ASCII, AH=scancode)
; ======================================================================

org 0x100

%define K_ESC       27
%define K_BS         8
%define K_CR        13
%define SC_UP      0x48
%define SC_DOWN    0x50
%define SC_PGUP    0x49
%define SC_PGDN    0x51
%define SC_DEL     0x53

%define MAX_ITEMS     256            ; максимум елементів в списку
%define NAME_LEN       13            ; 8.3 + NUL
%define PAGE_ROWS      18            ; скільки рядків показуємо (крім заголовка/статуса)

; -------------------------
; PSP segment available as CS in .COM
; -------------------------

start:
    ; 1) Зберегти початкову DTA та встановити власну
    mov ah,0x2F              ; Get DTA
    int 0x21
    mov [orig_dta_off], bx
    mov [orig_dta_seg], es

    mov dx, dta_buf          ; Set DTA = наш буфер
    mov ah, 0x1A
    int 0x21

    ; 2) Очистити екран і показати заголовок
    call ClearScreen
    mov dx, title
    call PrintStr$

    ; 3) Завантажити список елементів поточного каталогу
rescan_dir:
    call LoadDir             ; будує таблицю items[], attr[]
    xor bx, bx               ; bx = поточний індекс
show_page:
    call DrawList            ; малює екран / підсвічує вибір

main_loop:
    call GetKeyEx            ; AH=scancode, AL=ascii
    cmp al, K_ESC
    je  quit
    cmp al, K_CR
    je  act_enter
    cmp al, K_BS
    je  act_updir

    cmp ah, SC_UP
    je  nav_up
    cmp ah, SC_DOWN
    je  nav_down
    cmp ah, SC_PGUP
    je  nav_pgup
    cmp ah, SC_PGDN
    je  nav_pgdn
    cmp ah, SC_DEL
    je  act_del

    jmp main_loop

nav_up:
    cmp bx, 0
    je main_loop
    dec bx
    jmp show_page

nav_down:
    mov ax, [item_count]
    dec ax
    cmp bx, ax
    jae main_loop
    inc bx
    jmp show_page

nav_pgup:
    sub bx, PAGE_ROWS
    js .to0
    jmp show_page
.to0:
    xor bx, bx
    jmp show_page

nav_pgdn:
    mov ax, bx
    add ax, PAGE_ROWS
    mov dx, [item_count]
    dec dx
    cmp ax, dx
    jbe .ok
    mov bx, dx
    jmp show_page
.ok:
    mov bx, ax
    jmp show_page

; --- Enter: якщо DIR -> cd, якщо file -> нічого (можна розширити "view")
act_enter:
    ; перевірити атрибут вибраного
    mov si, bx
    shl si, 1
    mov ax, [attr_table + si]      ; атрибут у AX (молодший байт)
    test al, 0x10                  ; DIR?
    jz main_loop                   ; файл — поки що нічого
    ; DS:DX -> ім'я каталогу (ASCIZ)
    mov dx, name_buf
    call GetNameByIndex            ; запише ім'я у name_buf
    mov ah, 0x3B                   ; CHDIR
    int 0x21
    jc  show_status_err
    jmp rescan_dir

; --- Backspace: cd ..
act_updir:
    mov dx, updir_txt              ; "..",0
    mov ah, 0x3B                   ; CHDIR
    int 0x21
    jc  show_status_err
    jmp rescan_dir

; --- Delete: видалити файл (для каталогу — ігноруємо, або можна додати rmdir)
act_del:
    ; якщо DIR — пропустити
    mov si, bx
    shl si, 1
    mov ax, [attr_table + si]
    test al, 0x10
    jnz main_loop
    ; Confirm (optional) — тут пропустимо і просто видалимо
    mov dx, name_buf
    call GetNameByIndex
    mov ah, 0x41                   ; DELETE file
    int 0x21
    jc  show_status_err
    jmp rescan_dir

show_status_err:
    call StatusLineError
    jmp show_page

quit:
    ; Відновити стару DTA і повернутися в DOS
    mov dx, [orig_dta_off]
    mov ds, [orig_dta_seg]
    mov ah, 0x1A
    int 0x21

    mov ax, 0x4C00
    int 0x21

; ----------------------------------------------------------------------
; LoadDir: наповнює items[] і attr_table[] і встановлює item_count
; ----------------------------------------------------------------------
LoadDir:
    push ds
    push es
    push si
    push di

    ; DS <- CS для наших рядків/буферів
    push cs
    pop ds

    ; Скинути лічильник
    xor ax, ax
    mov [item_count], ax

    ; FindFirst "*.*", CX=0x37 (R,H,S,D,A)
    mov dx, patt_all
    mov cx, 0x37
    mov ah, 0x4E
    int 0x21
    jc  .done                     ; немає файлів — ок

.collect:
    ; DTA -> беремо атрибут і ім'я
    ; DTA структура (DOS 3+): offset 0x15 атрибут, 0x1E (30) — ім'я (13 байт)
    mov si, dta_buf
    mov al, [si+0x15]
    ; зберегти атрибут
    mov bx, [item_count]
    shl bx, 1
    mov [attr_table + bx], ax

    ; копіювати ім’я 13 байт у таблицю імен
    mov di, [item_count]
    mov cx, NAME_LEN
    mov bx, di
    mov di, names_area
    mov dx, NAME_LEN
    mul dx                       ; AX = index * NAME_LEN (але ми в 16-біт, зробимо простіше)
    ; Простий покроковий підрахунок адреси:
    ; di = names_area + index*NAME_LEN
    ; Реалізуємо як петлю додавання
    mov di, names_area
    mov cx, [item_count]
    jcxz .addr_ok
.addr_loop:
    add di, NAME_LEN
    loop .addr_loop
.addr_ok:
    push si
    add si, 0x1E
    mov cx, NAME_LEN
.copy13:
    lodsb
    stosb
    loop .copy13
    pop si

    ; ++count, перевірка ліміту
    mov ax, [item_count]
    inc ax
    mov [item_count], ax
    cmp ax, MAX_ITEMS
    jae .done

    ; FindNext
    mov ah, 0x4F
    int 0x21
    jnc .collect

.done:
    pop di
    pop si
    pop es
    pop ds
    ret

; ----------------------------------------------------------------------
; DrawList: малює заголовок, шлях, список (з підсвіченням поточного BX)
;   Вхід: BX = обраний індекс
; ----------------------------------------------------------------------
DrawList:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call ClearBody               ; прибирає область списку
    ; шлях
    mov dx, path_lbl
    call PrintStr$
    call PrintCWD

    ; Вирахувати, з якого елемента показувати (скроль на сторінки)
    xor dx, dx
    mov ax, bx
    mov cx, PAGE_ROWS
    div cx                       ; AX=page, DX=offset_in_page
    mul cx                       ; AX=page*PAGE_ROWS
    mov si, ax                   ; si = first index on page
    xor di, di                   ; ді = рядок у вікні [0..PAGE_ROWS-1]

.row_loop:
    ; якщо вийшли за count — стоп
    mov ax, si
    cmp ax, [item_count]
    jae .done

    ; курсор у колонку 2, рядок = 3 + di
    mov dh, 3
    add dh, dl                   ; dl перезапишемо нижче; тримай різні регістри
    mov dh, 3
    add dh, di
    mov dl, 2
    call GotoXY

    ; намалювати ">" для поточного індекса
    mov ax, si
    cmp ax, bx
    jne .no_mark
    mov dl, '>'
    call PutChar
    mov dl, ' '
    call PutChar
    jmp .print_name
.no_mark:
    mov dl, ' '
    call PutChar
    mov dl, ' '
    call PutChar

.print_name:
    ; отримати ім’я в name_buf
    push bx
    mov bx, si
    mov dx, name_buf
    call GetNameByIndex
    pop bx

    ; якщо DIR — додати '/'
    mov ax, [attr_table + si*2]
    test al, 0x10
    jz .as_file
    ; "[DIR] name"
    mov dx, dir_tag
    call PrintStr$
    mov dx, name_buf
    call PrintStrZ
    jmp .next_row
.as_file:
    mov dx, name_buf
    call PrintStrZ

.next_row:
    inc si
    inc di
    cmp di, PAGE_ROWS
    jb .row_loop

.done:
    ; статус
    mov dh, 23
    mov dl, 0
    call GotoXY
    mov dx, help_line
    call PrintStr$

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------
; GetNameByIndex: копіює ім’я з таблиці у буфер DS:DX (ASCIZ)
;   Вхід: BX=index, DS=CS, DX=dest
; ----------------------------------------------------------------------
GetNameByIndex:
    push si
    push di
    push cx
    push ds

    push cs
    pop ds

    ; di = names_area + index*NAME_LEN
    mov di, names_area
    mov cx, bx
    jcxz .addr_ok
.addr_loop:
    add di, NAME_LEN
    loop .addr_loop
.addr_ok:
    mov si, di
    mov di, dx
    mov cx, NAME_LEN
    rep movsb

    pop ds
    pop cx
    pop di
    pop si
    ret

; ----------------------------------------------------------------------
; PrintCWD: друк поточного каталогу (AH=47h)
; ----------------------------------------------------------------------
PrintCWD:
    push ax
    push bx
    push dx
    push ds

    push cs
    pop ds
    mov dl, 0                ; поточний диск
    mov si, cwd_buf
    mov byte [si], 64        ; макс. довжина (перша позиція)
    mov dx, si
    mov ah, 0x47
    int 0x21
    jc .done
    ; DOS кладе довжину в [buf], рядок з 1-го байта,
    ; перетворимо в $-terminated для PrintStr$
    mov cl, [cwd_buf]
    mov [cwd_buf], '$'       ; тимчасово поставимо '$' зліва
    inc si
    mov dx, si
    call PrintStrRawLen      ; надрукувати cl байт
    mov dl, 13               ; CRLF
    call PutChar
    mov dl, 10
    call PutChar
.done:
    pop ds
    pop dx
    pop bx
    pop ax
    ret

; ----------------------------------------------------------------------
; UI helpers
; ----------------------------------------------------------------------
ClearScreen:
    ; INT 10h, AH=06h scroll up, AL=0 = clear
    mov ax, 0x0600
    mov bh, 0x07
    mov cx, 0x0000
    mov dx, 0x184F
    int 0x10
    ret

ClearBody:
    ; очистити рядки 3..22
    mov ax, 0x0600
    mov bh, 0x07
    mov cx, (3<<8)|0
    mov dx, (22<<8)|79
    int 0x10
    ret

GotoXY:                        ; DH=row, DL=col
    push bx
    mov bh, 0
    mov ah, 0x02
    int 0x10
    pop bx
    ret

PutChar:                       ; DL=char
    push ax
    push bx
    xor  bh, bh
    mov  ah, 0x0E
    mov  al, dl
    mov  bl, 0x07
    int  0x10
    pop  bx
    pop  ax
    ret

PrintStr$:                     ; DS:DX -> '$'-terminated
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

PrintStrZ:                     ; DS:DX -> ASCIIZ
    push ax
    push dx
.next:
    lodsb
    or al, al
    jz .done
    push dx
    mov dl, al
    call PutChar
    pop dx
    jmp .next
.done:
    pop dx
    pop ax
    ret

; друк рядка фіксованої довжини (CL=len), DS:DX -> буфер
PrintStrRawLen:
    push ax
    push cx
    push dx
    jcxz .done
.more:
    lodsb
    push cx
    mov dl, al
    call PutChar
    pop cx
    loop .more
.done:
    pop dx
    pop cx
    pop ax
    ret

GetKeyEx:                      ; повертає AL=ASCII, AH=scancode
    mov ah, 0x10
    int 0x16
    ret

StatusLineError:
    mov dh, 23
    mov dl, 0
    call GotoXY
    mov dx, err_line
    call PrintStr$
    ret

; ----------------------------------------------------------------------
; Дані
; ----------------------------------------------------------------------
title       db 'Nano File Manager (NFM) 0.1  -  ^Up/^Down Select, Enter Open, Backspace Up, Del Delete, Esc Quit',13,10,'$'
path_lbl    db 'Path: ', '$'
dir_tag     db '[DIR] ', '$'
help_line   db 'Enter: open  Backspace: up  Del: delete  Esc: quit', '$'
err_line    db 'Error (DOS carry=1)! Press any key...', '$'
updir_txt   db '..',0
patt_all    db '*.*',0

orig_dta_off dw 0
orig_dta_seg dw 0

cwd_buf     db 64 dup(0)

dta_buf     rb 128                   ; місце під DTA

item_count  dw 0
attr_table  dw MAX_ITEMS dup(0)

names_area  rb MAX_ITEMS * NAME_LEN
name_buf    rb NAME_LEN
