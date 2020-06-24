# picoboot-lib
picoboot Arduino library

picoboot-lib is based on [picobootArduino](https://github.com/nerdralph/picoboot/tree/master/arduino), modified for tiny AVRs without hardward bootloader support.  The bootloader uses a busy-loop timeout defaulting to 4 seconds, so there is no impact on the watchdog timer and MCUSR.

# Installation
With a usbasp programmer connected to an attiny85, run 'make flash'.  For a different AVR, set MCU, such as 'MCU=attiny84 make flash'.

# Configuration
PB0 is used for transmit, and PB1 is used for receive.  Change UART_Tx and UART_Rx in pb-lib.S to use different GPIOs.  The serial baud rate is fixed at 0.0072x the MCU clock rate, which is 57.6kbps for 8Mhz. Building with -DCLOCKSLOW will slow the timing by 1.5%.

# Use
After installing picoboot-lib in the Arduino/libraries folder, choose "Include Library", "picoboot-lib", from the "Sketch" menu.  The boards.txt must have upload.protocol set to "arduino", and upload.speed must be set to 57600.

