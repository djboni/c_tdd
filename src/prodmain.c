#include "add.h"
#include <stdio.h>
#include <stdlib.h>

#ifdef __AVR__
#    include "port.h"
#endif /* __AVR__ */

int main(int argc, const char **argv) {
#ifdef __AVR__
    const char *my_argv[] = {"exec", "1", "2"};
    int my_argc = sizeof(my_argv) / sizeof(my_argv[0]);

    argc = my_argc;
    argv = my_argv;

    port_init();
    serial_init(115200);
    port_enable_tick_interrupt();
    INTERRUPTS_ENABLE();
#endif /* __AVR__ */

    int a, b, result;

    if (argc != 3) {
        fprintf(stderr, "Usage: %s A B\n", argv[0]);
        fprintf(stderr, "ERROR: expected two arguments\n");
        return 1;
    }

    a = atoi(argv[1]);
    b = atoi(argv[2]);

    result = add(a, b);

    printf("%d\n", result);

#ifdef __AVR__
    while (1) {
        idle_wait_interrupt();
    }
#endif /* __AVR__ */

    return 0;
}
