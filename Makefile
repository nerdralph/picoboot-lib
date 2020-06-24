MCU     ?= attiny85 
CC      = avr-gcc
OPTIONS = -mmcu=$(MCU) -DBUILD_MAIN -Wl,--section-start=.bootloader=0x1F00
TARGET  = pb-lib

$(TARGET): *.[cS]
	$(CC) $(OPTIONS) $^ -o $@
	avr-size $@

PROGRAMMER ?= usbasp -B 4
flash:  $(TARGET)
	avrdude -C /etc/avrdude.conf -p $(DEVICE) -c $(PROGRAMMER) -U flash:w:$(TARGET):e

.PHONY: $(TARGET)

