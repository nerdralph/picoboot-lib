/* pb-tiny arduino compatible bootloader for t84, t85 & t88
 * (c) Ralph Doncaster 2020 MIT license
 *
 * based on picoboot https://github.com/nerdralph/picoboot

 * 20200615 v0.1 prototype
 * 20200624 v0.2 first working version
 * 20200627 v0.3 with OSCCAL autotune 
 * 20200627 v0.4 optimize autotune, expose RxByte and TxByte
 * 20200628 v0.5 match with custom pcrt.S
 * 20200727 v0.6 bulk erase flash, remove EE read
 * 20200803 v0.7 implement virtual reset vector
 */

#include <avr/io.h>

#define LEDPIN 4

/* UART defines */
#define UART_PORT (PORTB - 0x20)
#define UART_DDR (UART_PORT - 1)
#define UART_PIN (UART_PORT - 2)
#define UART_Tx 0
#define UART_Rx 1

#include "stk500.h"

#define command r16
#define pgLen r17
#define txData r18
#define delayArg r19
#define SpmArg r20
#define hiTmp r21
#define rxWord r22
#define rxData r23
#define rstSavLo r24
#define rstSavHi r25

#ifndef SPMEN
#define SPMEN SELFPRGEN
#endif

#ifndef CLOCKSLOW
; 2 cycle tweak for best 57.6 timing @ 8Mhz
#define DELAYADJUST rjmp .
#else
#define DELAYADJUST
#endif

.section .version
.equiv picoboot_version, 256*0 + 7

.section .text
__vectors:
    sbi UART_PORT, UART_Rx              ; pullup rx for noise immunity
    clr delayArg
    rcall Delay3Cycle                   ; wait 768 cycles for pullup

    sbi UART_DDR, LEDPIN
    sbi UART_PORT, LEDPIN
Retry:
    rcall Tune0x30
    rcall ReadWord                      ; ignore rest of GET_SYNC msg
    tst r17
    breq Retry
    rcall Tune0x30

; now save tuned OSCCAL value (saved in r17) to bootloader
    ldi r22, 0xFF
    ldi r23, 0xFF
    ldi ZL, (BOOTADDR & 0xFF)           ; bootloader start address
    ldi ZH, (BOOTADDR >> 8)
    ;ldi SpmArg, (1<<SPMEN)              ; fill page buffer
    ;rcall DoSPM
    ;adiw ZL, 2                          ; increment Z pointer
    ; 1st bootloader instruction is ldi rd, osccal
    ; opcode = 1110 KKKK dddd KKKK
    ; tuned OSCCAL value was saved in r17
    push r17
    ori r17, 0xF0
    mov r0, r17                         ; lo byte of ldi instruction
    pop r17 
    swap r17
    ori r17, 0xF0
    mov r1, r17                         ; hi byte of ldi instruction
    ldi SpmArg, (1<<SPMEN)              ; fill page buffer
    rcall DoSPM
    movw r0, r22                        ; 0xFFFF does not modify flash
Fill0xFF:
    adiw ZL, 2                          ; increment Z pointer
    rcall DoSPM
    cpi ZL, (BOOTADDR & 0xFF) + SPM_PAGESIZE - 2
    brne Fill0xFF 
    ldi SpmArg, (1<<PGWRT)|(1<<SPMEN)
    rcall DoSPM                         ; write page
    cbi UART_PORT, LEDPIN
    ; tuning done so erase tuner (0x0000 - 0x0080)
    clr ZH 
    ldi ZL, 0x80
    ldi command, STK_UNIVERSAL
    rjmp ChipErase                      ; enter bootloader

; adjust OSCCAL based on timing of STK_GET_SYNC(0x30) command
; low period is 5 bits * 138.89 cycles = 694.4 cycles
; count loop is 4 cycles, so ideal count = 173.6 (694.4 / 4)
; adjusted OSCCAL returned in r17, 0 = tuning failed
Tune0x30:
    sbic UART_PIN, UART_Rx
    rjmp Tune0x30                       ; wait for start bit
    clr r16
count:
    inc r16
    sbis UART_PIN, UART_Rx              ; wait for rx hi
    rjmp count
    ; does the timing roughly match STK_GET_SYNC +/- 10%?
    mov hiTmp, r16
    subi hiTmp, 174
    sbrc hiTmp, 7                       ; hiTmp = abs(hiTmp)
    neg hiTmp
    cpi hiTmp, 18
    brlt inRange                        ; within +- 10%
    clr r17                             ; failed
    ret
inRange:
    lsr r16                             ; count /= 2 
    subi r16, 174 / 2                   ; r16 = delta from ideal timing
    lds r17, OSCCAL
    sub r17, r16
    sts OSCCAL, r17                     ; adjust OSCCAL
    ret

.section .bootloader,"ax"
; for devices with up to 8kB flash
; use -Wl,--section-start=.bootloader=0x1F00
BootLoader:
    ldi delayArg, 0xFF                  ; 0xFF modified by tuner
    sts OSCCAL, delayArg                ; set OSCCAL to tuned value

    sbi UART_PORT, UART_Rx              ; pullup rx for noise immunity
    rcall Delay3Cycle                   ; wait for pullup and OSCCAL
    clr rstSavHi

    ; wait for start bit of first message
    ldi YL, 70                          ; 70 * 2^16 * 7c =~ 4s @8Mhz
WaitStart:
    sbiw ZL, 1
    sbci YL, 0
    sbis UART_PIN, UART_Rx
    rjmp CommandLoop
    brcc WaitStart
    ; timeout waiting for start bit - return from pb
StartApp:
    cbi UART_PORT, UART_Rx              ; turn off rx pullup
    rjmp __vectors + BOOTADDR - 2

CommandLoop:
    ; ignore the rest of STK500 message
    ; longest msg is SET_DEVICE at 22 bytes; wait at least that long
    ; at 8Mhz and 57.6kbps, wait >30,588 cycles
    ldi YL, 41                          ; 41 * 768 = 31488
1:  rcall Delay3Cycle
    dec YL
    brne 1b

CommandFast:                            ; skip delay
    ; STK_OK marks end of bootloader reply message 
    rcall TxSTK_OK

; start of new message from programmer
    rcall RxByte                        ; read command
    mov command, rxData
    clt                                 ; flag to tx STK_INSYNC

    cpi command, STK_LOAD_ADDRESS
    brne Universal
    rcall ReadWord
    movw ZL, rxWord                     ; Z stores address for page load
    lsl ZL
    rol ZH                              ; convert from word to byte address

Universal:
    cpi command, STK_UNIVERSAL
    brne GetParam
    rcall ReadWord
    cpi rxData, 0x80                    ; check for chip erase cmd
    brne 1f
    .equ LAST_USER_PAGE, (BOOTADDR - SPM_PAGESIZE)
    ldi ZL, lo8(LAST_USER_PAGE)
    ldi ZH, hi8(LAST_USER_PAGE)
    ; erase all pages before bootloader, highest first
ChipErase:
    ldi SpmArg, (1<<PGERS)|(1<<SPMEN)
    rcall DoSPM
    subi ZL, SPM_PAGESIZE
    sbci ZH, 0
    brcc ChipErase                      ; done after page 0 erased
    rjmp 1f                             ; dummy reply
GetParam:
    cpi command, STK_GET_PARAMETER
    brne ReadSig
    ; command ignored - send dummy 0x00 for Universal/Version Param
    ; txData should already be 0 from last tx
1:    rcall PBTxByte

ReadSig:
    cpi command, STK_READ_SIGN
    brne Quit
    ldi txData, SIGNATURE_0
    rcall PBTxByte
    ldi txData, SIGNATURE_1
    rcall PBTxByte
    ldi txData, SIGNATURE_2
    rcall PBTxByte

Quit:
    cpi command, STK_LEAVE_PROGMODE
    brne ProgPage
    rcall TxSTK_OK
    cbi UART_PORT, UART_Tx              ; disable Tx pullup
    rjmp StartApp

; todo: add eeprom write support
ProgPage:
    cpi command, STK_PROG_PAGE
    brne ReadPage
    rcall GetPageParams
    ;cpi rxData, 'F'                     ; check for memtype flash
    ;brne Default                        ; only flash supported
PageFill:
    rcall ReadWord
    sbiw ZL, 0
    brne 1f                             ; not reset vector
    movw rstSavLo, rxWord
    ; rjmp = 1100 kkkk kkkk kkkk, k = 12-bit relative word address
    ; bit 12 of BOOTADDR is set, so it works as an offset from 0x0000
    ldi rxData, 0xC0 + ((BOOTADDR / 2) >> 8)
    ldi rxWord, ((BOOTADDR - 2) / 2) & 0xFF
1:
    movw r0, rxWord                     ; data in r1:r0
    rcall DoSPMEN                       ; fill page buffer
    adiw ZL, 2                          ; increment Z one word
    subi pgLen, 2
    brne PageFill
    subi ZL, SPM_PAGESIZE               ; roll back Z 
    sbci ZH, 0
    ldi SpmArg, (1<<PGWRT)|(1<<SPMEN)
    rcall DoSPM
    ; if page == 0, save reset vector in last user page
    brne CommandFast
    movw XL, rstSavLo                   ; save for spoofing verify
    ldi ZL, (BOOTADDR - 2) & 0xFF
    ldi ZH, (BOOTADDR - 2) >> 8
    .equ vResetOffset, (BOOTADDR - 2) / 2
    ori rstSavHi, 0x10                  ; set for borrow from bit 12
    subi rstSavLo, vResetOffset & 0xFF
    sbci rstSavHi, vResetOffset >> 8
    movw r0, rstSavLo
    rcall DoSPMEN                       ; fill page buffer
    ldi SpmArg, (1<<PGWRT)|(1<<SPMEN)
    rcall DoSPM
    
ReadPage:
    cpi command, STK_READ_PAGE
    brne Default 
    rcall GetPageParams
    ; read both flash and EE, but only send memtype that was requested
    ; reduces code to one loop instead of two 
ReadMem:
    out EEARL - 0x20, ZL
    out EEARL - 0x20 + 1, ZH
    lpm txData, Z+                      ; read flash, inc Z
    cpi rxData, 'E'                     ; check for memtype EEPROM
    brne 1f                             ; memtype must be 'F'
    sbi EECR - 0x20, EERE
    in txData, EEDR - 0x20              ; read EEPROM
    rjmp SendByte
1:  ; do we need to spoof reset vector contents?
    cpi ZL, 1
    cpc ZH, YL                          ; YL == 0
    brne SendByte
    mov txData, XL
    rcall PBTxByte
    dec pgLen
    adiw ZL, 1
    mov txData, XH
SendByte:
    rcall PBTxByte
    dec pgLen
    brne ReadMem

Default:
    rjmp CommandLoop

; get length and flash type for write or read page
; could alias pgLen to rxWord and save 2 instr?
GetPageParams:
    rcall RxByte                        ; ignore block size hi byte
    rcall ReadWord                      ; block size and memtype
    mov pgLen, rxWord
    ret

DoSPMEN:
    ldi SpmArg, (1<<SPMEN)              ; fill page buffer
DoSPM:
    out SPMCSR - 0x20, SpmArg
    spm
    ret

ReadWord:                               ; read 2 bytes into rxWord
    rcall RxByte
    mov rxWord, rxData                  ; rxWord lo
    ; fall through to RxByte

/* half-duplex bit-bang UART code */
/* fixed timings for 57.6@8M/115.2@16M = 138.9 cycles/bit */
.equ TXDELAY, 41
.equ RXSTART, 64
.equ RXDELAY, 41

; receive byte into rxData
.global RxByte
RxByte:
    sbis UART_PIN, UART_Rx              ; wait for idle
    rjmp RxByte
    cli
1:  sbic UART_PIN, UART_Rx              ; wait for start edge
    rjmp 1b
    ldi rxData, 0x80                    ; bit shift counter
    ldi delayArg, RXSTART               ; 1.5 bit delay
RxBit:
    ; 7 cycle loop + ldi/delay = 7 + 7 + 3*DelayArg
    rcall Delay3Cycle                   ; delay and clear carry
    rjmp .                              ; 2-cycle delay to match TxByte
    ldi delayArg, RXDELAY 
    lsr rxData
    sbic UART_PIN, UART_Rx              ; sample rx bit
    ori rxData, 0x80
    brcc RxBit
    reti

TxSTK_OK:
    ldi txData, STK_OK
; transmit STK_INSYNC if first byte in message
; T bit in SREG used as first byte flag when clear
PBTxByte:
    brts TxByte
    push txData
    ldi txData, STK_INSYNC
    rcall TxByte
    pop txData
; transmit byte contained in txData
.global TxByte
TxByte:
    cli
    cbi UART_PORT, UART_Tx              ; disable pullup
    sbi UART_DDR, UART_Tx               ; start bit
    in r0, UART_PORT
    sec                                 ; hold stop bit in C
TxLoop:
    ; 7 cycle loop + TxDelay = 7 + 7 + 3*DelayArg
    rcall TxDelay
    bst txData, 0                       ; store lsb in T
    bld r0, UART_Tx
    ror txData                          ; shift for next bit
    clc
    out UART_PORT, r0
    brne TxLoop
    cbi UART_DDR, UART_Tx               ; set to input pullup mode
    sei
    ; fall into delay for stop bit
TxDelay:
    ldi delayArg, TXDELAY
; delay (3 cycle * delayArg) -1 + 4 cycles (ret instruction)
Delay3Cycle:
    dec delayArg
    brne Delay3Cycle
    DELAYADJUST
    ret

.byte 'p', 'b'                          ; 'pb' = picoboot-lib signature

