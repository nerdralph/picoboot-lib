/* picoboot-lib arduino compatible bootloader library
 * (c) Ralph Doncaster 2020 MIT license
 *
 * based on picoboot https://github.com/nerdralph/picoboot

 * 20200615 v0.1 prototype
 */

/* needed for <avr/io.h> to give io constant addresses */
#define __SFR_OFFSET 0 

#include <avr/io.h>

#define LEDPIN 4

/* UART defines */
#define UART_PORT PORTB
#define UART_DDR (UART_PORT - 1)
#define UART_PIN (UART_PORT - 2)
#define UART_Tx 0
#define UART_Rx 1

#include "stk500.h"

#define loTemp r2
#define Command r16
#define Temp r17
#define txData r18
#define pgLen r19
#define SpmArg r20
#define delayArg r22
#define rxData r25
#define rxWord r24

.section .version
.equiv picoboot_version, 256*0 + 1

; call bootloader before main
.section .init1
    rcall BootLoader

/*
.section .text
.weak main
main:
    sbi DDRB, LEDPIN
    sbi PINB, LEDPIN
    rcall BootLoader
    rjmp main
*/

.section .bootloader,"ax"
; for devices with up to 8kB flash
; use -Wl,--section-start=.bootloader=0x1F00
BootLoader:
    sbi UART_PORT, UART_Rx              ; pullup rx for noise immunity
    sbi UART_PORT, UART_Tx              ; pullup tx
    sbi UART_DDR, UART_Tx
    ;sbi UART_DDR, UART_Tx               ; pulldown tx

    clr XL
    clr XH

    ; wait for start bit of first message
    ldi YL, 70                          ; 70 * 2^16 =~ 4s @8Mhz
WaitStart:
    sbiw ZL, 1
    sbci YL, 0
    sbis UART_PIN, UART_Rx
    rjmp CommandLoop
    brcc WaitStart
JStartApp:
    rjmp StartApp                       ; bootloader timout

CommandLoop:
    ; ignore the rest of STK500 message
    ; longest msg is SET_DEVICE at 22 bytes; wait at least that long
    ; at 8Mhz and 57.6kbps, wait 31,000 cycles
    ldi YL, 41                          ; 41 * 768 = 38488
1:  rcall Delay3Cycle
    dec YL
    brne 1b

forever:
    ;rjmp forever                        ; for debug
    ;rcall RxByte                        ; read command
    ;ldi txData, 0x55
    ;rcall TxByte
    ;cbi UART_PORT, UART_Tx              ; start bit
    ;ldi delayArg, TXDELAY
    ;rcall TxDelay
    ;sbi UART_PORT, UART_Tx              ; start bit

    ;rjmp CommandLoop

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

StartApp:
    cbi UART_PORT, UART_Rx              ; turn off rx pullup
    ;cbi UART_DDR, 1               ; turn off Tx
    ret

; todo: add eeprom write support
ProgPage:
    cpi Command, STK_PROG_PAGE
    brne ReadPage
    rcall GetPageParams
    cpi rxData, 'F'                     ; check for memtype flash
    brne Default                        ; only flash supported
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
ReadByte:
    out EEARL, ZL
#ifdef EEARH
    out EEARH, ZH
#endif
    lpm txData, Z+
ReadEEPROM:
    cpi rxData, 'E'                     ; check for memtype EEPROM
    brne SendByte
ReadEEByte:
    sbi EECR, EERE
    in txData, EEDR
SendByte:
    rcall PBTxByte
    dec pgLen
    brne ReadByte

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
    out SPMCSR, SpmArg
    spm
    ret


/* half-duplex bit-bang UART code */

.extern TXDELAY
.extern RXSTART
.extern RXDELAY

.equ TXDELAY, 42
.equ RXSTART, 65
.equ RXDELAY, 42

; transmit STK_INSYNC if first byte in message
; I bit in SREG used as first byte flag 
PBTxByte:
    brid TxByte
    mov r2, txData
    ldi txData, STK_INSYNC
    rcall TxByte
    cli
    mov txData, r2
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
    sbic UART_PIN, UART_Rx
    ori rxData, 0x80
    brcc RxBit
    ret

