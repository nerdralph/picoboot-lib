MCU     ?= attiny85
CC      = avr-gcc
OPTIONS = -mmcu=$(MCU) -nostartfiles -Wl,--section-start=.bootloader=0x1F00
#OPTIONS += -DCLOCKSLOW
TARGET  = pblib-$(MCU).elf

$(TARGET): *.[cS]
	$(CC) $(OPTIONS) $^ -o $@
	avr-size $@

PROGRAMMER ?= usbasp -B 4
flash:  $(TARGET)
	avrdude -C /etc/avrdude.conf -p $(DEVICE) -c $(PROGRAMMER) -U flash:w:$(TARGET):e

.PHONY: $(TARGET)

