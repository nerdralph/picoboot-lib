/* picoboot-lib arduino compatible bootloader library
 * (c) Ralph Doncaster 2020 MIT license
 *
 * based on picoboot https://github.com/nerdralph/picoboot

 * 20200615 v0.1 prototype
 * 20200624 v0.2 first working version
 * 20200624 v0.3 with OSCCAL autotune 
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

#define Command r16
#define txData r18
#define pgLen r19
#define SpmArg r20
#define delayArg r22
#define rxData r25
#define rxWord r24

#ifndef SPMEN
#define SPMEN SELFPRGEN
#endif

.section .version
.equiv picoboot_version, 256*0 + 3

.section .text
__vectors:
    sbi UART_PORT, UART_Rx              ; pullup rx for noise immunity
    clr delayArg
    rcall Delay3Cycle                   ; wait 768 cycles for pullup

    sbi UART_DDR, LEDPIN
    sbi UART_PIN, LEDPIN
    rcall Tune0x30
    rcall ReadWord                      ; ignore rest of GET_SYNC msg
    rcall Tune0x30

; now write tuned OSCCAL value (saved in r17) to 0xFF
    ldi ZL, 0xFF
    ldi ZH, 0xFF
    movw r0, ZL
    ldi ZL, 0 - SPM_PAGESIZE
    ldi SpmArg, (1<<SPMEN)              ; fill page buffer
Fill0xFF:
    rcall DoSPM
    adiw ZL, 2                          ; increment Z pointer
    cpi ZL, 0xFE
    brne Fill0xFF 
    mov r1, r17                         ; r17 = OSCCAL
    rcall DoSPM
    ldi SpmArg, (1<<PGWRT)|(1<<SPMEN)
    rcall DoSPM                         ; write OSCCAL to 0xFFFF
    rjmp CommandLoop                    ; enter bootloader

; adjust OSCCAL based on timing of STK_GET_SYNC(0x30) command
; low period is 5 bits * 138.89 cycles = 694.4 cycles
; count loop is 4 cycles, so ideal count = 173.6 (694.4 / 4)
Tune0x30:
    sbic UART_PIN, UART_Rx
    rjmp Tune0x30                       ; wait for start bit
    clr r16
count:
    inc r16
    sbis UART_PIN, UART_Rx              ; wait for rx hi
    rjmp count
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
    sbi UART_PORT, UART_Rx              ; pullup rx for noise immunity
    ;clr delayArg
    ;rcall Delay3Cycle                   ; wait 768 cycles for pullup

    ldi ZL, 0xFF
    ldi ZH, 0xFF
    lpm r0, Z
    sts OSCCAL, r17                     ; set OSCCAL to tuned value

    ; wait for start bit of first message
    ldi YL, 70                          ; 70 * 2^16 * 7c =~ 4s @8Mhz
WaitStart:
    sbiw ZL, 1
    sbci YL, 0
    sbis UART_PIN, UART_Rx
    rjmp CommandLoop
    brcc WaitStart
Timeout:
    cbi UART_PORT, UART_Rx              ; turn off rx pullup
    ret

CommandLoop:
    ; ignore the rest of STK500 message
    ; longest msg is SET_DEVICE at 22 bytes; wait at least that long
    ; at 8Mhz and 57.6kbps, wait >30,588 cycles
    ldi YL, 41                          ; 41 * 768 = 31488
1:  rcall Delay3Cycle
    dec YL
    brne 1b

    ; reply OK
    ldi txData, STK_OK
    rcall PBTxByte 

; start of new message from programmer
    rcall RxByte                        ; read command
    mov Command, rxData
    sei                                 ; flag to tx STK_INSYNC

    cpi Command, STK_LOAD_ADDRESS
    brne Universal
    rcall ReadWord
    movw ZL, rxWord                     ; Z stores address for page load
    lsl ZL
    rol ZH                              ; convert from word to byte address

Universal:
    cpi Command, STK_UNIVERSAL
    breq 1f                             ; dummy reply
GetParam:
    cpi Command, STK_GET_PARAMETER
    brne ReadSig
    ; command ignored - send dummy 0x00 for Universal/Version Param
1:  ldi txData, 0
    rcall PBTxByte

ReadSig:
    cpi Command, STK_READ_SIGN
    brne Quit
    ldi txData, SIGNATURE_0
    rcall PBTxByte
    ldi txData, SIGNATURE_1
    rcall PBTxByte
    ldi txData, SIGNATURE_2
    rcall PBTxByte

Quit:
    cpi Command, STK_LEAVE_PROGMODE
    brne ProgPage
    ldi txData, STK_OK
    rcall PBTxByte
    pop r0 $ pop r0                     ; return address unused
    cbi UART_PORT, UART_Rx              ; turn off rx pullup
    rjmp __vectors                      ; restart

; todo: add eeprom write support
; could be rewritten to eliminiate Z rollback?
ProgPage:
    cpi Command, STK_PROG_PAGE
    brne ReadPage
    rcall GetPageParams
    ;cpi rxData, 'F'                     ; check for memtype flash
    ;brne Default                        ; only flash supported
PageFill:
    rcall ReadWord
    movw r0, rxWord                     ; data in r1:r0
    ldi SpmArg, (1<<SPMEN)              ; fill page buffer
    rcall DoSPM
    adiw ZL, 2                          ; increment Z pointer
    subi pgLen, 2
    brne PageFill
    sbiw ZL, 2                          ; roll Z back
    ; erase then write page
    ldi SpmArg, (1<<PGERS)|(1<<SPMEN)
    rcall DoSPM
    ldi SpmArg, (1<<PGWRT)|(1<<SPMEN)
    rcall DoSPM

ReadPage:
    cpi Command, STK_READ_PAGE
    brne Default 
    rcall GetPageParams
    ; read both flash and EE, but only send memtype that was requested
    ; reduces code to one loop instead of two 
ReadMem:
    out EEARL - 0x20, ZL
    out EEARL - 0x20 + 1, ZH
    lpm txData, Z+                      ; read flash
ReadEEPROM:
    cpi rxData, 'E'                     ; check for memtype EEPROM
    brne SendByte
    sbi EECR - 0x20, EERE
    in txData, EEDR                     ; read EEPROM
SendByte:
    rcall PBTxByte
    dec pgLen
    brne ReadMem

Default:
    rjmp CommandLoop

; get length and flash type for write or read page
GetPageParams:
    rcall RxByte                        ; ignore block size hi byte
    rcall ReadWord
    mov pgLen, rxWord                   ; block size
    ret

ReadWord:                               ; read word into rxWord
    rcall RxByte
    mov rxWord, rxData                  ; rxWord lo
    rjmp RxByte                         ; rxWord hi

DoSPM:
    out SPMCSR - 0x20, SpmArg
    spm
    ret


/* half-duplex bit-bang UART code */

/* fixed timings for 57.6@8M/115.2@16M = 138.9 cycles/bit */
.equ TXDELAY, 41
.equ RXSTART, 64
.equ RXDELAY, 41

; transmit STK_INSYNC if first byte in message
; I bit in SREG used as first byte flag 
PBTxByte:
    brid TxByte
    push txData
    ldi txData, STK_INSYNC
    rcall TxByte
    cli
    pop txData
; transmit byte contained in txData
.global TxByte
TxByte:
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
    ; fall into delay for stop bit
TxDelay:
    ldi delayArg, TXDELAY
; delay (3 cycle * delayArg) -1 + 4 cycles (ret instruction)
Delay3Cycle:
    dec delayArg
    brne Delay3Cycle
#ifndef CLOCKSLOW
    ; 2 cycle tweak for best 57.6 timing @ 8Mhz
    rjmp .
#endif
    ret

; receive byte into rxData
.global RxByte
RxByte:
    sbis UART_PIN, UART_Rx              ; wait for idle
    rjmp RxByte
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
    ret

.byte 0x70, 0xFF                        ; 'p' = picoboot-lib signature

