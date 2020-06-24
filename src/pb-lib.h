// picoboot-lib include

__attribute__ ((naked, used))
__attribute__ ((section (".init1")))
void pb_lib(void)
{
    // picoboot-lib starts at the last 256 bytes of flash
    asm("rcall __vectors - 256");
}
