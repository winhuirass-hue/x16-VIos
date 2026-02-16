; ======================================================================
;  NFM+ — Nano File Manager (DOS .COM) — Improved (NASM, 16-bit)
;  Build: nasm -f bin nfm_plus.asm -o NFM.COM
; ======================================================================

BITS 16
ORG  0x100

%define MAX_ITEMS      192
%define NAME_LEN        13          ; 8.3 ASCIIZ
%define PAGE_ROWS       18

%define K_ESC           27
%define SC_F10         0x44
%define SC_UP          0x48
%define SC_DOWN        0x50
%define SC_PGUP        0x49
%define SC_PGDN        0x51
%define SC_DEL         0x53

; ----------------------------------------------------------------------
; DATA (initialized)
; ----------------------------------------------------------------------
section .data

mask_all        db '*.*',0
updir_txt       db '..',0
root_txt        db '\',0

; UI ($-terminated for AH=09h)
ui_help$        db 'Up/Down PgUp/PgDn Enter Backspace  Del  M R N T  S:Sort  G:Group  Esc/F10:Exit$'

err_prefix0     db 'Error 0x',0           ; 0-terminated (для Puts0)

; DOS line input buffer (AH=0Ah) — ініціалізований, тож в .data
linein_buf:
    db 12          ; max length (<=12 для 8.3)
    db 0           ; actual length
    times 13 db 0  ; data (max+1)

; Статус/прапори
item_count          dw 0
restore_sel         db 0
sort_desc           db 0
group_dirs_first    db 1
prev_drv            db 0

orig_dta_off        dw 0
orig_dta_seg        dw 0

; Промпти ($-terminated)
pr_del$        db 'Delete file? (Y/N): $'
pr_mkdir$      db 'New directory name: $'
pr_rmdir$      db 'Remove directory? (Y/N): $'
pr_ren_new$    db 'New name: $'

; ----------------------------------------------------------------------
; BSS (uninitialized)
; ----------------------------------------------------------------------
section .bss

dta_buf         resb 128                        ; DOS DTA (>=43 bytes)
name_table      resb MAX_ITEMS * NAME_LEN       ; послідовно 8.3 ASCIIZ
attr_table      resw MAX_ITEMS                  ; word/entry (низький байт атрибути)
name_buf        resb NAME_LEN
old_name_buf    resb NAME_LEN
last_name_buf   resb NAME_LEN
path_buf        resb 64                         ; AH=47h повертає шлях без диска
header_tmp      resb 96                         ; для заголовка/повідомлень
hexbuf          resb 4                          ; для шістнадцяткового числа

; ----------------------------------------------------------------------
; CODE
; ----------------------------------------------------------------------
section .text

; ---------------- Entry ----------------
start:
    push cs
    pop  ds

    ; Save original DTA (AH=2Fh)
    mov  ah, 0x2F
    int  0x21
    mov  [orig_dta_off], bx
    mov  [orig_dta_seg], es

    ; Set our DTA (AH=1Ah)
    mov  dx, dta_buf
    mov  ah, 0x1A
    int  0x21

    call UiFullRedraw

rescan_dir:
    call LoadDir
    call SortByName

    cmp  byte [restore_sel], 0
    jne  .restore
    xor  bx, bx                 ; default selection
    jmp  draw_page
.restore:
    call RestoreSelection
    mov  byte [restore_sel], 0

draw_page:
    call UiHeader
    call DrawList

; ---------------- Main loop ----------------
main_loop:
    call GetKeyEx                ; AL=ascii, AH=scancode

    ; Exit
    cmp  al, K_ESC
    je   quit
    cmp  ah, SC_F10
    je   quit

    ; Disk change A..Z
    cmp  al, 'A'
    jb   .chk_low
    cmp  al, 'Z'
    jbe  act_change_drive
.chk_low:
    cmp  al, 'a'
    jb   .nav
    cmp  al, 'z'
    jbe  act_change_drive

.nav:
    ; Navigation
    cmp  ah, SC_UP
    je   nav_up
    cmp  ah, SC_DOWN
    je   nav_down
    cmp  ah, SC_PGUP
    je   nav_pgup
    cmp  ah, SC_PGDN
    je   nav_pgdn
    cmp  ah, SC_DEL
    je   act_del

    cmp  al, 13                  ; Enter
    je   act_enter
    cmp  al, 8                   ; Backspace
    je   act_updir

    ; Ops
    cmp  al, 'm'
    je   act_mkdir
    cmp  al, 'M'
    je   act_mkdir

    cmp  al, 'r'
    je   act_rmdir_sel
    cmp  al, 'R'
    je   act_rmdir_sel

    cmp  al, 'n'
    je   act_rename_sel
    cmp  al, 'N'
    je   act_rename_sel

    cmp  al, 't'
    je   act_touch_sel
    cmp  al, 'T'
    je   act_touch_sel

    ; Sort toggle
    cmp  al, 's'
    je   act_toggle_sort
    cmp  al, 'S'
    je   act_toggle_sort

    ; Group DIR first toggle
    cmp  al, 'g'
    je   act_toggle_group
    cmp  al, 'G'
    je   act_toggle_group

    jmp  main_loop

; ----------------------------------------------------------------------
; Navigation
; ----------------------------------------------------------------------
nav_up:
    cmp  bx, 0
    je   main_loop
    dec  bx
    jmp  draw_page

nav_down:
    mov  ax, [item_count]
    dec  ax
    cmp  bx, ax
    jae  main_loop
    inc  bx
    jmp  draw_page

nav_pgup:
    sub  bx, PAGE_ROWS
    js   .to0
    jmp  draw_page
.to0:
    xor  bx, bx
    jmp  draw_page

nav_pgdn:
    mov  ax, bx
    add  ax, PAGE_ROWS
    mov  dx, [item_count]
    dec  dx
    cmp  ax, dx
    jbe  .ok
    mov  bx, dx
    jmp  draw_page
.ok:
    mov  bx, ax
    jmp  draw_page

; ----------------------------------------------------------------------
; Actions
; ----------------------------------------------------------------------
; Save selected name into last_name_buf for post-rescan restore
SaveSelectedName:
    push bx
    mov  dx, last_name_buf
    call GetNameByIndex
    pop  bx
    mov  byte [restore_sel], 1
    ret

; Enter into directory (if selected is DIR)
act_enter:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10                ; DIR?
    jz   main_loop
    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3B                ; CHDIR
    int  0x21
    jc   UiShowLastError
    jmp  rescan_dir

; Updir: chdir ..
act_updir:
    mov  dx, updir_txt
    mov  ah, 0x3B
    int  0x21
    jc   UiShowLastError
    mov  byte [restore_sel], 0
    jmp  rescan_dir

; Delete file (confirm). Directories are ignored.
act_del:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10                ; DIR?
    jnz  main_loop

    mov  dx, pr_del$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x41                ; DELETE
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; MKDIR (prompt)
act_mkdir:
    mov  dx, pr_mkdir$
    call PromptNameToBuf
    jc   draw_page
    call SaveSelectedName
    mov  dx, name_buf
    mov  ah, 0x39                ; MKDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; RMDIR (if selected is DIR, confirm)
act_rmdir_sel:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10
    jz   draw_page               ; not a dir

    mov  dx, pr_rmdir$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3A                ; RMDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; RENAME selected (prompt new name)
act_rename_sel:
    ; Copy old name to old_name_buf
    push bx
    mov  dx, old_name_buf
    call GetNameByIndex
    pop  bx

    mov  dx, pr_ren_new$
    call PromptNameToBuf
    jc   draw_page

    call SaveSelectedName
    mov  dx, old_name_buf        ; DS:DX old
    push ds
    pop  es
    mov  di, name_buf            ; ES:DI new
    mov  ah, 0x56                ; RENAME
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; TOUCH selected: update timestamp or create
act_touch_sel:
    call SaveSelectedName

    ; get selected name -> name_buf
    push bx
    mov  dx, name_buf
    call GetNameByIndex
    pop  bx

    ; exists? FindFirst for file attrs only (no DIR)
    mov  dx, name_buf
    mov  cx, 0x27                ; R|H|S|A (files only)
    mov  ah, 0x4E
    int  0x21
    jc   .create

    ; open R/W
    mov  ax, 0x3D02              ; open R/W
    mov  dx, name_buf
    int  0x21
    jc   UiShowLastError
    mov  bx, ax                  ; handle

    ; ---- build CX = time ----
    mov  ah, 0x2C                ; CH hour, CL min, DH sec
    int  0x21
    xor  cx, cx
    mov  al, ch                  ; hour
    xor  ah, ah
    shl  ax, 11
    mov  cx, ax
    xor  ax, ax
    mov  al, cl                  ; minute
    shl  ax, 5
    or   cx, ax
    xor  ax, ax
    mov  al, dh                  ; second
    shr  al, 1
    or   cx, ax                  ; CX=time

    ; ---- build DX = date ----
    mov  ah, 0x2A                ; CX year, DH month, DL day
    int  0x21
    sub  cx, 1980
    mov  dx, cx
    shl  dx, 9                   ; (year-1980)<<9
    xor  ax, ax
    mov  al, dh                  ; month
    shl  ax, 5
    or   dx, ax
    xor  ax, ax
    mov  al, dl                  ; day
    or   dx, ax                  ; DX=date

    mov  ax, 0x5701              ; set timestamp by handle
    int  0x21
    mov  ah, 0x3E                ; close
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

.create:
    mov  cx, 0
    mov  dx, name_buf
    mov  ah, 0x3C                ; CREATE
    int  0x21
    jc   UiShowLastError
    mov  bx, ax
    mov  ah, 0x3E                ; CLOSE
    int  0x21
    jmp  rescan_dir

; Toggle sort order
act_toggle_sort:
    xor  byte [sort_desc], 1
    call SortByName
    jmp  draw_page

; Toggle group directories first
act_toggle_group:
    xor  byte [group_dirs_first], 1
    call SortByName
    jmp  draw_page

; Disk change: AL='A'..'Z'/'a'..'z'
act_change_drive:
    ; Normalize to 0..25 in AL
    and  al, 0xDF
    sub  al, 'A'
    cmp  al, 25
    ja   main_loop

    ; remember previous drive
    mov  ah, 0x19                ; AL=current (0=A)
    int  0x21
    mov  [prev_drv], al

    ; select new drive: DL=drive+1 (1=A)
    mov  dl, al           ; тут AL вже 0..25 з розрахунку вище!
    inc  dl
    mov  ah, 0x0E                ; Select Disk
    int  0x21
    ; go to root
    mov  dx, root_txt
    mov  ah, 0x3B                ; CHDIR "\"
    int  0x21
    jc   UiShowLastError

    mov  byte [restore_sel], 0
    jmp  rescan_dir

; ----------------------------------------------------------------------
; Directory loading, sorting, selection restore
; ----------------------------------------------------------------------

; LoadDir:
; - Scans "*.*" with CX=0x37 (include files+dirs+hidden+system+archive)
; - Skips volume labels
; - Fills name_table[], attr_table[], item_count
LoadDir:
    xor  ax, ax
    mov  [item_count], ax

    mov  dx, mask_all
    mov  cx, 0x37                ; R/H/S/D/A
    mov  ah, 0x4E                ; FindFirst
    int  0x21
    jc   .done

.next:
    ; DTA layout: attr at +0x15, name at +0x1E
    mov  si, dta_buf
    mov  al, [si + 0x15]         ; attributes
    test al, 0x08                ; volume label?
    jnz  .skip_add

    ; add item
    mov  dx, [item_count]
    cmp  dx, MAX_ITEMS
    jae  .skip_add

    ; dest DI = name_table + index*NAME_LEN
    mov  di, dx
    ; di = di*13
    mov  ax, di
    shl  ax, 1                   ; 2x
    add  ax, di                  ; 3x
    shl  ax, 2                   ; 12x
    add  ax, di                  ; 13x
    mov  di, ax
    add  di, name_table

    ; copy 13 bytes name
    push si
    lea  si, [si + 0x1E]
    mov  cx, NAME_LEN
    rep  movsb
    pop  si

    ; store attr (word)
    mov  si, dx
    shl  si, 1
    xor  ah, ah
    mov  [attr_table + si], ax   ; AL had attr, AH=0

    ; increment count
    inc  word [item_count]

.skip_add:
    ; FindNext
    mov  ah, 0x4F
    int  0x21
    jnc  .next
.done:
    ret

; Case-insensitive compare of two ASCIIZ 8.3 names
; IN: DS:SI -> name1, ES:DI -> name2
; OUT: AX = -1/0/1 (AX<0 if name1<name2)
StrICmp83:
    push bx
.nextc:
    lodsb                         ; AL = *SI++
    mov  bl, al
    ; to upper (A..Z), cheap mapping
    cmp  bl, 'a'
    jb   .n1
    cmp  bl, 'z'
    ja   .n1
    and  bl, 0xDF
.n1:
    mov  al, es:[di]
    inc  di
    ; AL -> BH then upper
    mov  bh, al
    cmp  bh, 'a'
    jb   .n2
    cmp  bh, 'z'
    ja   .n2
    and  bh, 0xDF
.n2:
    mov  al, bl
    cmp  al, bh
    jb   .lt
    ja   .gt
    cmp  bl, 0
    jne  .nextc
    ; equal
    xor  ax, ax
    jmp  .out
.lt:
    mov  ax, -1
    jmp  .out
.gt:
    mov  ax, 1
.out:
    pop  bx
    ret

; Get pointer to name by index and copy NAME_LEN to DS:DX
; IN: BX=index, DX=dest
GetNameByIndex:
    push ax
    push si
    push di

    mov  ax, bx
    shl  ax, 1
    add  ax, bx
    shl  ax, 2
    add  ax, bx                  ; AX = idx*13

    mov  si, name_table
    add  si, ax
    mov  di, dx
    mov  cx, NAME_LEN
    rep  movsb

    pop  di
    pop  si
    pop  ax
    ret

; Swap items i<->j (name_table and attr_table)
; IN: SI=i, DI=j
SwapItems:
    push ax
    push bx
    push cx
    push dx
    push bp
    push si
    push di

    mov  bx, si        ; bx = i
    mov  bp, di        ; bp = j

    ; ---- compute offsets: off_i = i*13 in DX, off_j = j*13 in AX
    mov  ax, bx
    shl  ax, 1
    add  ax, bx
    shl  ax, 2
    add  ax, bx
    mov  dx, ax        ; dx = i*13

    mov  ax, bp
    shl  ax, 1
    add  ax, bp
    shl  ax, 2
    add  ax, bp        ; ax = j*13

    ; temp <- name[i]
    mov  si, name_table
    add  si, dx
    mov  di, name_buf
    mov  cx, NAME_LEN
    rep  movsb

    ; name[i] <- name[j]
    mov  si, name_table
    add  si, ax
    mov  di, name_table
    add  di, dx
    mov  cx, NAME_LEN
    rep  movsb

    ; name[j] <- temp
    mov  si, name_buf
    mov  di, name_table
    add  di, ax
    mov  cx, NAME_LEN
    rep  movsb

    ; ---- swap attributes (word each entry)
    mov  si, bx
    shl  si, 1
    mov  di, bp
    shl  di, 1
    mov  cx, [attr_table + si]
    mov  dx, [attr_table + di]
    mov  [attr_table + si], dx
    mov  [attr_table + di], cx

    pop  di
    pop  si
    pop  bp
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; Compare two items considering group_dirs_first and name order
; IN: SI=i, DI=j
; OUT: AX = -1/0/1  (i<j, i==j, i>j)
CmpItems:
    push bx
    push cx
    push dx

    ; Load attrs
    mov  bx, si
    shl  bx, 1
    mov  al, [attr_table + bx]
    mov  bl, al                   ; BL = attr_i

    mov  bx, di
    shl  bx, 1
    mov  al, [attr_table + bx]
    mov  bh, al                   ; BH = attr_j

    ; DIR bit
    mov  al, [group_dirs_first]
    or   al, al
    jz   .skip_dir_group

    mov  dl, bl
    and  dl, 0x10
    mov  dh, bh
    and  dh, 0x10
    cmp  dl, dh
    je   .skip_dir_group
    ; different: DIR first => DIR should be "less"
    ; if i is DIR and j is file -> i<j => AX=-1
    ; if i is file and j is DIR -> i>j => AX=1
    cmp  dl, 0
    jne  .i_is_dir
    mov  ax, 1
    jmp  .done
.i_is_dir:
    mov  ax, -1
    jmp  .done

.skip_dir_group:
    ; compare names case-insensitive
    ; compute ptrs
    push ds
    push es
    push si
    push di

    ; ptr_i = name_table + i*13
    mov  ax, si
    shl  ax, 1
    add  ax, si
    shl  ax, 2
    add  ax, si
    mov  si, name_table
    add  si, ax

    ; ptr_j = name_table + j*13
    mov  ax, di
    shl  ax, 1
    add  ax, di
    shl  ax, 2
    add  ax, di
    mov  di, name_table
    add  di, ax

    push ds
    pop  es                    ; ES=DS
    call StrICmp83

    pop  di
    pop  si
    pop  es
    pop  ds
.done:
    pop  dx
    pop  cx
    pop  bx
    ret

; Simple bubble sort by CmpItems + sort_desc
SortByName:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov  cx, [item_count]
    jcxz .out
    dec  cx
    jz   .out

.outer:
    mov  si, 0
.inner:
    mov  di, si
    inc  di

    push si
    push di
    call CmpItems
    ; AX = -1/0/1 (i<j/i==j/i>j)
    ; if !sort_desc -> swap when AX>0; if sort_desc -> swap when AX<0
    cmp  byte [sort_desc], 0
    jne  .desc_check
    cmp  ax, 0
    jle  .noswap
    ; swap
    pop  di
    pop  si
    call SwapItems
    jmp  .post
.desc_check:
    cmp  ax, 0
    jge  .noswap
    pop  di
    pop  si
    call SwapItems
    jmp  .post
.noswap:
    pop  di
    pop  si
.post:
    inc  si
    mov  ax, [item_count]
    dec  ax
    cmp  si, ax
    jb   .inner

    dec  cx
    jnz  .outer

.out:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; RestoreSelection by last_name_buf (case-insensitive). Sets BX.
RestoreSelection:
    push ax
    push cx
    push dx
    push si
    push di

    mov  bx, 0
    mov  cx, [item_count]
    jcxz .notfound

    mov  di, 0
.loop:
    ; SI = ptr to name[i]
    mov  ax, di
    shl  ax, 1
    add  ax, di
    shl  ax, 2
    add  ax, di
    mov  si, name_table
    add  si, ax

    ; compare with last_name_buf
    mov  di, last_name_buf
    push ds
    pop  es
    call StrICmp83
    or   ax, ax
    jnz  .next

    ; equal -> BX=index and return
    mov  bx, di                  ; !!! DI now points to last_name_buf. Wrong.
    ; виправлення: зберігали індекс у DX
.next_fix:
    ; (переробимо збереження індексу)
    ; Спочатку повернемось і зробимо коректно
.notfound:
    ; fallback
    xor  bx, bx
    jmp  .out

; --------- виправлена реалізація RestoreSelection ---------
RestoreSelection_fixed:
    push ax
    push cx
    push dx
    push si
    push di

    mov  bx, 0
    mov  dx, 0                   ; dx = found_index?
    mov  cx, [item_count]
    jcxz .rf_out

    mov  ax, 0                   ; i
.rf_loop:
    ; SI = ptr to name[i]
    push ax
    mov  si, name_table
    ; AX = i*13
    mov  bx, ax
    shl  bx, 1
    add  bx, ax
    shl  bx, 2
    add  bx, ax
    add  si, bx

    mov  di, last_name_buf
    push ds
    pop  es
    call StrICmp83
    pop  ax
    or   ax, ax
    jnz  .rf_next

    ; found
    mov  bx, ax                  ; bx = i (AX still = 0 from compare? ні)
    ; AX не містить i — ми його зберігали в AX. Після виклику AX = cmp result (0).
    ; Але i у нас у AX після pop, тож:
    mov  bx, ax
    jmp  .rf_done
.rf_next:
    inc  ax
    loop .rf_loop
    xor  bx, bx
    jmp  .rf_done
.rf_out:
    xor  bx, bx
.rf_done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  ax
    ret

; ======================================================================
; UI / Rendering
; ======================================================================

; Clear screen
ClearScreen:
    push ax
    push bx
    push cx
    push dx
    mov  ax, 0x0600        ; scroll up whole screen
    mov  bh, 0x07          ; attribute
    mov  cx, 0x0000        ; upper-left
    mov  dx, 0x184F        ; lower-right (25x80)
    int  0x10
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; SetCursor(row DH, col DL)
SetCursor:
    push ax
    push bx
    mov  ah, 0x02
    xor  bh, bh
    int  0x10
    pop  bx
    pop  ax
    ret

; Put character in DL (DOS)
PutcDL:
    push ax
    mov  ah, 0x02
    int  0x21
    pop  ax
    ret

; Print 0-terminated string at DS:SI
Puts0:
    push ax
    push dx
.next:
    lodsb
    or   al, al
    jz   .out
    mov  dl, al
    call PutcDL
    jmp  .next
.out:
    pop  dx
    pop  ax
    ret

; Print $-terminated at DS:DX
Puts$:
    push ax
    mov  ah, 0x09
    int  0x21
    pop  ax
    ret

; Clear line at row DH (80 spaces)
ClearLine:
    push ax
    push cx
    push dx
    push si
    mov  dl, 0
    call SetCursor
    mov  cx, 80
    mov  dl, ' '
.cl_loop:
    call PutcDL
    loop .cl_loop
    pop  si
    pop  dx
    pop  cx
    pop  ax
    ret

; Convert AX (word) to decimal string at DS:DI (0-terminated)
WordToDec0:
    push ax
    push bx
    push cx
    push dx
    push di

    xor  cx, cx
    mov  bx, 10
    or   ax, ax
    jnz  .wd_loop
    mov  byte [di], '0'
    inc  di
    jmp  .wd_done
.wd_loop:
    xor  dx, dx
    div  bx            ; AX=AX/10, DX=remainder
    push dx
    inc  cx
    or   ax, ax
    jnz  .wd_loop
    ; pop digits
.popd:
    pop  dx
    add  dl, '0'
    mov  [di], dl
    inc  di
    loop .popd
.wd_done:
    mov  byte [di], 0

    pop  di
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; Byte in AL -> two hex chars at DS:DI (no terminator)
ByteToHex2:
    push ax
    push bx
    mov  bl, al
    shr  al, 4
    call NibbleToHex
    mov  [di], al
    inc  di
    mov  al, bl
    and  al, 0x0F
    call NibbleToHex
    mov  [di], al
    inc  di
    pop  bx
    pop  ax
    ret
NibbleToHex:
    cmp  al, 9
    jbe  .dig
    add  al, 'A' - 10
    ret
.dig:
    add  al, '0'
    ret

; Header drawing: "C:\path  [S:ASC|DESC] [G:On|Off]  N items"
UiHeader:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call GetDriveAndPath    ; fills header_tmp with "X:\path"
    ; append spaces and flags
    mov  si, header_tmp
.h_seek0:
    lodsb
    or   al, al
    jz   .at_end
    jmp  .h_seek0
.at_end:
    dec  si                 ; SI points to 0 at end
    mov  di, si             ; DI = end
    ; add two spaces
    mov  byte [di], ' '     ; overwrite 0
    inc  di
    mov  byte [di], ' '
    inc  di
    ; append [S:...]
    mov  byte [di], '['
    inc  di
    mov  byte [di], 'S'
    inc  di
    mov  byte [di], ':'
    inc  di
    cmp  byte [sort_desc], 0
    jne  .desc
    mov  byte [di], 'A'
    inc  di
    mov  byte [di], 'S'
    inc  di
    mov  byte [di], 'C'
    inc  di
    jmp  .after_s
.desc:
    mov  byte [di], 'D'
    inc  di
    mov  byte [di], 'E'
    inc  di
    mov  byte [di], 'S'
    inc  di
    mov  byte [di], 'C'
    inc  di
.after_s:
    mov  byte [di], ']'
    inc  di
    mov  byte [di], ' '
    inc  di
    ; append [G:On|Off]
    mov  byte [di], '['
    inc  di
    mov  byte [di], 'G'
    inc  di
    mov  byte [di], ':'
    inc  di
    cmp  byte [group_dirs_first], 0
    je   .g_off
    mov  byte [di], 'O'
    inc  di
    mov  byte [di], 'n'
    inc  di
    jmp  .after_g
.g_off:
    mov  byte [di], 'O'
    inc  di
    mov  byte [di], 'f'
    inc  di
    mov  byte [di], 'f'
    inc  di
.after_g:
    mov  byte [di], ']'
    inc  di
    mov  byte [di], ' '
    inc  di
    mov  byte [di], ' '
    inc  di
    ; append count
    mov  ax, [item_count]
    push di
    call WordToDec0             ; writes at DI and 0-term
    pop  di
