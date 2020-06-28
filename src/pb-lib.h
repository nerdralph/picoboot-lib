// picoboot-lib include

/*
__attribute__ ((naked, used))
__attribute__ ((section (".init1")))
void pb_lib(void)
{
    // picoboot-lib starts at the last 256 bytes of flash
    asm("rcall __vectors - 256");
}
*/

// TxByte wrapper
inline void pb_txbyte(char c)
{
    register char ch asm("r18") = c;    // arg in r18
    asm volatile ("rcall __vectors - 40" : "+r"(ch) :: "r19");
}

// RxByte wrapper
inline char pb_rxbyte()
{
    register char c asm("r23");
    asm volatile ("rcall __vectors - 80" : "=r"(c) :: "r19");
    return c;
}

