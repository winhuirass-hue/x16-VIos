;
; ляляля
; примитивный десктоп, вызываем с предварительно зареганой команды в kernel.asm
; %INCLUDE "src/kernel/features/gui/desktop.asm" - не забыть импортировать
;
 
[BITS 16]
 
ICON_W equ 16
ICON_H equ 16
 
section .text
 
desktop_run:
    pusha
    push ds
    push es
 
.init_video:
    mov ax, 0012h
    int 10h
 
.redraw_all:
    mov ax, 0
    mov bx, 0
    mov si, 640
    mov di, 480
    mov cx, 1       
    call gui_draw_rect_fast
 
    mov ax, 0
    mov bx, 460
    mov si, 640
    mov di, 20
    mov cx, 7           
    call gui_draw_rect_fast
 
    call render_icons
    call draw_clock
 
    mov cx, 15           
    call draw_selector_logic
 
.input_loop:
    xor ah, ah
    int 16h
    cmp al, 27
    je .exit
    cmp al, 09h
    je .handle_tab
    cmp al, 13
    je .handle_enter
    jmp .input_loop
 
.handle_tab:
    mov cx, 1      
    call draw_selector_logic
    
    inc byte [selected_icon]
    cmp byte [selected_icon], 3
    jb .no_res
    mov byte [selected_icon], 1
.no_res:
    mov cx, 15       
    call draw_selector_logic
    jmp .input_loop
 
.handle_enter:
    mov ax, 200
    mov bx, 180
    mov si, 240
    mov di, 80
    mov cx, 7        
    call gui_draw_rect_fast
    
    mov ax, 200
    mov bx, 180
    mov si, 240
    mov di, 16
    mov cx, 9           
    call gui_draw_rect_fast
 
    mov cx, 27
    mov dx, 12
    mov si, msg_title
    call gui_draw_text_bios
 
    mov cx, 28
    mov dx, 15
    cmp byte [selected_icon], 1
    je .pc_txt
    mov si, txt_folder
    jmp .print_done
.pc_txt:
    mov si, txt_pc
.print_done:
    call gui_draw_text_bios
 
    xor ah, ah
    int 16h
    jmp .redraw_all
 
.exit:
    mov ax, 0003h
    int 10h
    pop es
    pop ds
    popa
    ret
 
gui_draw_rect_fast:
    pusha
    mov byte [.color_store], cl  
    mov dx, bx         
.y_loop_f:
    mov cx, ax          
    push si
.x_loop_f:
    push ax
    mov ah, 0Ch
    mov al, byte [.color_store]  
    xor bh, bh
    int 10h
    pop ax
    inc cx
    dec si
    jnz .x_loop_f
    pop si
    inc dx
    dec di
    jnz .y_loop_f
    popa
    ret
.color_store db 0
 
gui_draw_rect_simple:
    pusha
    mov bp, dx       
    mov dx, bx         
.y_loop_s:
    mov cx, ax       
    push si
.x_loop_s:
    push ax
    mov ah, 0Ch
    push bx
    mov bx, bp         
    mov al, bl        
    pop bx
    xor bh, bh
    int 10h
    pop ax
    inc cx
    dec si
    jnz .x_loop_s
    pop si
    inc dx
    dec di
    jnz .y_loop_s
    popa
    ret
 
render_icons:
    pusha
    mov ax, 40
    mov bx, 40
    mov si, sprite_computer
    call gui_draw_sprite
    
    mov cx, 4
    mov dx, 5
    mov si, txt_pc
    call gui_draw_text_bios
 
    mov ax, 40
    mov bx, 100
    mov si, sprite_folder
    call gui_draw_sprite
    
    mov cx, 5
    mov dx, 9
    mov si, txt_folder
    call gui_draw_text_bios
    popa
    ret
 
draw_clock:
    pusha
    mov ah, 02h
    int 1ah
    mov al, ch
    call bcd_to_char
    mov [time_str], ah
    mov [time_str+1], al
    mov al, cl
    call bcd_to_char
    mov [time_str+3], ah
    mov [time_str+4], al
    
    mov cx, 73
    mov dx, 29
    mov si, time_str
    call gui_draw_text_bios
    popa
    ret
 
bcd_to_char:
    mov ah, al
    and ax, 0F00Fh
    shr ah, 4
    add ax, 3030h
    ret
 
gui_draw_text_bios:
    pusha
.char:
    lodsb
    test al, al
    jz .done
    pusha
    mov ah, 02h
    xor bh, bh
    mov dh, dl
    mov dl, cl
    int 10h
    mov ah, 0Eh
    mov bl, 15
    int 10h
    popa
    inc cx
    jmp .char
.done:
    popa
    ret
 
draw_selector_logic:
    pusha
    mov byte [.color_temp], cl
    cmp byte [selected_icon], 1
    je .p1
    mov cx, 38
    mov dx, 98
    jmp .draw
.p1:
    mov cx, 38
    mov dx, 38
.draw:
    mov al, byte [.color_temp]
    mov si, 22
    call draw_box_outline
    popa
    ret
.color_temp db 0
 
draw_box_outline:
    pusha
    mov ah, 0Ch
    xor bh, bh
    push cx
    push dx
    
    mov di, si
.l1:
    int 10h
    inc cx
    dec di
    jnz .l1
    
    mov di, si
.l2:
    int 10h
    inc dx
    dec di
    jnz .l2
    
    mov di, si
.l3:
    int 10h
    dec cx
    dec di
    jnz .l3
    
    mov di, si
.l4:
    int 10h
    dec dx
    dec di
    jnz .l4
    
    pop dx
    pop cx
    popa
    ret
 
gui_draw_sprite:
    pusha
    mov bp, ax
    mov di, bx
    mov dx, di
.y: 
    mov cx, bp
.x: 
    lodsb
    cmp al, 0FFh
    je .s
    push dx
    push bx
    push ax
    mov dx, di
    mov ah, 0Ch
    xor bh, bh
    int 10h
    pop ax
    pop bx
    pop dx
.s: 
    inc cx
    mov ax, cx
    sub ax, bp
    cmp ax, ICON_W
    jl .x
    inc di
    mov ax, di
    sub ax, bx
    cmp ax, ICON_H
    jl .y
    popa
    ret
 
section .data
    selected_icon db 1
    time_str      db '00:00', 0
    txt_pc        db 'The x16-PRos-ideas version 0.1', 0
    txt_folder    db 'Files', 0
    msg_title     db 'x16-PRos Info', 0
 
    sprite_computer:
        db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        db 0,7,7,7,7,7,7,7,7,7,7,7,7,7,7,0
        db 0,7,15,15,15,15,15,15,15,15,15,15,15,15,7,0
        db 0,7,15,9,9,9,9,9,9,9,9,9,9,15,7,0
        db 0,7,15,9,9,9,9,9,9,9,9,9,9,15,7,0
        db 0,7,15,15,15,15,15,15,15,15,15,15,15,15,7,0
        db 0,7,7,7,7,7,7,7,7,7,7,7,7,7,7,0
        db 0,0,0,0,0,0,0,8,8,0,0,0,0,0,0,0
        db 0,0,0,0,0,0,8,15,15,8,0,0,0,0,0,0
        db 0,0,0,7,7,7,7,7,7,7,7,7,7,0,0,0
        db 0,0,7,15,15,15,15,15,15,15,15,15,15,7,0,0
        db 0,0,7,7,7,7,7,7,7,7,7,7,7,7,0,0
        times 16*4 db 0
 
    sprite_folder:
        times 16 db 0xFF
        db 0xFF,0xFF,14,14,14,14,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
        db 0xFF,14,15,15,15,15,14,14,14,14,14,14,14,14,0xFF,0xFF
        times 10*16 db 14
        times 4*16 db 0xFF
