; ====================================================================
; Project:   DiskBuddy64 - Fast IEC Implementation for 1541 - Writing
; Version:   v1.3.2
; Year:      2022
; Author:    Stefan Wagner
; Github:    https://github.com/wagiminator
; EasyEDA:   https://easyeda.com/wagiminator
; License:   http://creativecommons.org/licenses/by-sa/3.0/
; ====================================================================
;
; Description:
; ------------
; Simple fast writing by accelerating the IEC communication due to
; the use of an asynchronous 2-bit parallel protocol. This program is
; loaded into the memory of the floppy disk drive and communicates
; from there with the DiskBuddy64 adapter.
; This implementation writes a list of sectors to the specified track
; on the disk.
;
; References:
; -----------
; Michael Steil: https://www.pagetable.com/?p=568
;
; Assembling Instructions:
; ------------------------
; ca65 -l -t c64 fastwrite.a65
; ld65 -t c64 -o fastwrite.bin fastwrite.o
;
; Operating Instructions:
; -----------------------
; "M-E"<addrLow><addrHigh><track><#sectors><sector1><sector2>...
;
; $0200 - $0202 "M-E"       Memory Execute command
; $0203 - $0204 <addrL/H>   start address of this program in RAM ($0503)
; $0205         <track>     track on disk to write to
; $0206         <#sectors>  number of sectors in the following list
; $0207 - ...   <sectorX>   list of sectors to write in order


.setcpu "6502"
.org $0500

    jmp writejob      ; jump to write job (called by job loop)

; ====================================================================
; Start Routine (start program here)
; ====================================================================

; Initial setup
; -------------
start:
    lda $1c00         ; read port B
    and #$10          ; isolate bit for 'WRITE PROTECT'
    beq finish        ; 'WRITE PROTECT' -> finish
    lda $0205         ; get track from command buffer
    cmp #41           ; track >= 41?
    bcs finish        ; 'WRONG TRACK' -> finish
    sta $0a           ; set track for disk operation
    lda #$00          ; sector index start value (#$00)
    sta $05           ; store in $05
    jsr $c118         ; turn on DRIVE LED
    lda #$12          ; speed up stepper
    sta $1c07
    jsr $c63d         ; check drive and initialize
    bne finish        ; 'WRITE ERROR' -> finish

; Write sectors to disk
; ---------------------
    lda #$e0          ; write job at $0500
    sta $02           ; set job -> start disk operation
waitcomplete:
    lda $02           ; read job status
    bmi waitcomplete  ; wait for job to complete

; Finish all up
; -------------
finish:
    lda #$3a          ; stepper back to normal speed
    sta $1c07
    lda $1c00         ; turn off DRIVE LED
    and #$F7
    sta $1c00
    rts               ; end of mission


; ====================================================================
; Fast IEC Function (receives one data byte)
; ====================================================================

receivebyte:
    lda #$08          ; 2 mark 'READY TO RECEIVE':
    sta $1800         ; 4 -> pull CLK LOW
    lda #$01          ; 2 wait for 'READY TO SEND':
waitready:
    bit $1800         ; 4 test DATA line
    beq waitready     ; 2 wait for DATA LOW
    lsr               ; 2 mark 'LETS GO':
    sta $1800         ; 4 -> release CLK HIGH
    lda $1800         ; 4 bits 3 and 1
    asl               ; 2
    ora $1800         ; 4 bits 2 and 0
    and #$0F          ; 2
    sta $10           ; 3 store low nibble
    lda $1800         ; 4 bits 7 and 5
    asl               ; 2
    ora $1800         ; 4 bits 6 and 4
    asl               ; 2
    asl               ; 2
    asl               ; 2
    asl               ; 2 high nibble
    ora $10           ; 3 combine with low nibble
    rts               ; 6 return


; ====================================================================
; Job Function (reads sectors via fast IEC and writes them on track)
; ====================================================================

; Receive GCR-encoded block (325 bytes) from adapter via fast IEC
; ---------------------------------------------------------------
writejob:    
    ldy #$bb          ; bytes $01bb bis $01ff
rloop1:
    jsr receivebyte   ; get byte from IEC
    sta $0100,y       ; write into overflow buffer ($01bb-$01ff)
    iny               ; increase buffer index
    bne rloop1        ; repeat for 69 bytes
rloop2:
    jsr receivebyte   ; get byte from IEC
    sta $0300,y       ; write into data buffer ($0300 - $03ff)
    iny               ; increase buffer index
    bne rloop2        ; repeat for 256 bytes

; Find block header on disk
; -------------------------
    ldy $05           ; get sector index
    lda $0207,y       ; get sector from list in command buffer
    sta $0b           ; set sector for disk operation
    jsr $f510         ; find block header

; Skip 9 bytes (GAP)
; ------------------
    ldy #$09          ; 9 bytes gap after header
gaploop:
    bvc *             ; byte received?
    clv
    dey               ; decrease GAP byte counter
    bne gaploop       ; repeat for 9 GAP bytes

; Switch head to write mode
; -------------------------
    lda #$ce          ; change PCR
    sta $1c0c         ; to output
    lda #$ff          ; port A (read/write head)
    sta $1c03         ; to output

; Write 5 times SYNC byte (#$ff)
; ------------------------------
    lda #$ff          ; SYNC byte: #$ff
    ldy #$05          ; SYNC byte counter: 5 times
    sta $1c01         ; set byte to be written
    clv
syncloop:
    bvc *             ; wait for SYNC byte to be written
    clv
    dey               ; decrease SYNC byte conter
    bne syncloop      ; repeat for 5 SYNC bytes

; Write GCR coded data block
; --------------------------
    ldy #$bb          ; index overflow buffer
gcrloop:
    lda $0100,y       ; get byte from overflow buffer ($01bb-$01ff)
    bvc *             ; wait for previous byte to be written
    clv
    sta $1c01         ; set byte to be written
    iny               ; increase buffer index
    bne gcrloop       ; repeat for 69 bytes
dataloop:
    lda $0300,y       ; get byte from data buffer ($0300 - $03ff)
    bvc *             ; wait for previous byte to be written
    clv
    sta $1c01         ; set byte to be written
    iny               ; increase buffer index
    bne dataloop      ; repeat for 256 bytes

; Switch head back to read mode
; -----------------------------
    bvc *             ; wait for last byte to be written
    jsr $fe00         ; switch to reading

; Prepare next sector
; --------------------
nextsector:
    inc $05           ; increment sector index
    dec $0206         ; decrement number of sectors left
    bne writejob      ; repeat for all sectors

; Set return code and terminate job
; ---------------------------------
    lda #$01          ; return code 'OK'
    jmp $f969         ; finish job
