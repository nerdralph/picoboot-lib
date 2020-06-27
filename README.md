# picoboot-lib
picoboot Arduino library - a serial bootloader using only 256 bytes of flash.  The ATtiny85, ATtiny84, and ATtiny88 series MCUs are supported.

picoboot-lib is based on [picobootArduino](https://github.com/nerdralph/picoboot/tree/master/arduino), modified for tiny AVRs without hardward bootloader support.  The bootloader uses a busy-loop timeout defaulting to 4 seconds, so there is no impact on the watchdog timer and MCUSR.

To ensure reliable, high-speed serial communication, automatic OSCCAL tuning is included.  The first time the host communicates to the bootloader, OSCCAL is adjusted based on the timing of the incoming serial data.  The tuned OSCCAL value is saved in the bootloader flash space, and is used every subsequent time the bootloader runs.

## Installation
With a usbasp programmer connected to an attiny85, run 'make flash'.  For a different AVR, set MCU, such as 'MCU=attiny84 make flash'.

## Configuration
PB0 is used for transmit, and PB1 is used for receive.  Change UART_Tx and UART_Rx in pb-lib.S to use different GPIOs.  The serial baud rate is fixed at 0.0072x the MCU clock rate, which is 57.6kbps for 8Mhz.  Building with -DCLOCKSLOW will slow the timing by 1.5%.

## Use
After installing picoboot-lib in the Arduino/libraries folder, choose "Include Library", "picoboot-lib", from the "Sketch" menu.  The boards.txt must have upload.protocol set to "arduino", and upload.speed must be set to 57600.

To use picoboot-lib's half-duplex UART functions, call pb_txbyte() to transmit 1 byte, and pb_rxbyte() to receive 1 byte.  The receive function is blocking.  The frame format is 8N1.

## Development plan
A future release will include size-optimized Serial.print() functions using picoboot-lib's UART transmit function.  It should be possible to re-use much of the code from [debugSerial](https://github.com/nerdralph/debugSerial).

