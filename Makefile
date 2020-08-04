MCU     ?= attiny85
CC      = avr-gcc
BOOTADDR = 0x1EC0
OPTIONS = -mmcu=$(MCU) -nostartfiles -Wl,--section-start=.bootloader=$(BOOTADDR) -DBOOTADDR=$(BOOTADDR)
#OPTIONS += -DCLOCKSLOW
TARGET  = pblib-$(MCU).elf

$(TARGET): *.[cS]
	$(CC) $(OPTIONS) $^ -o $@
	avr-size $@

PROGRAMMER ?= usbasp -B 4
flash:  $(TARGET)
	avrdude -C /etc/avrdude.conf -p $(MCU) -c $(PROGRAMMER) -U flash:w:$(TARGET):e

.PHONY: $(TARGET)

