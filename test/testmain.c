#include "unity_fixture.h"

#ifdef __AVR__
#    include "port.h"
#endif /* __AVR__ */

void run_all_tests(void);

int main(int argc, const char **argv) {
#ifdef __AVR__
    const char *my_argv[] = {"test", "-s"};
    int my_argc = sizeof(my_argv) / sizeof(my_argv[0]);

    argc = my_argc;
    argv = my_argv;

    port_init();
    serial_init(115200);
    port_enable_tick_interrupt();
    INTERRUPTS_ENABLE();
#endif /* __AVR__ */

    int retval = UnityMain(argc, argv, run_all_tests);

#ifdef __AVR__
    while (1) {
        idle_wait_interrupt();
    }
#endif /* __AVR__ */

    return retval;
}
