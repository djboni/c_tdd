/* Copyright (c) 2023 Djones A. Boni - MIT License */

#ifndef PORT_H_
#define PORT_H_

#ifdef __cplusplus
extern "C" {
#endif

#define __ASSERT_USE_STDERR
#include <assert.h>
#include <stdint.h>

#define INTERRUPTS_VAL()
#define INTERRUPTS_DISABLE() __asm __volatile("cli" :: \
                                                  : "memory")
#define INTERRUPTS_ENABLE() __asm __volatile("sei" :: \
                                                 : "memory")

#define CRITICAL_VAL() uint8_t __istate_val
#define CRITICAL_ENTER() \
    __asm __volatile( \
        "in %0, __SREG__ \n\t" \
        "cli             \n\t" \
        : "=r"(__istate_val)::"memory")
#define CRITICAL_EXIT() \
    __asm __volatile("out __SREG__, %0 \n\t" ::"r"(__istate_val) \
                     : "memory")

#define ASSERT(expr, msg) assert(expr)

#define F_CPU 16000000
#define TIMER_PRESCALER 64
#define TICK_PERIOD (256.0 * TIMER_PRESCALER / F_CPU)
#define TICKS_PER_SECOND ((tick_t)(1.0 / TICK_PERIOD + 0.5))

typedef uint32_t tick_t;
typedef int32_t difftick_t;

void port_init(void);
void port_enable_tick_interrupt(void);
tick_t port_get_tick(void);
void idle_wait_interrupt(void);

void led_config(void);
void led_write(uint8_t value);
void led_toggle(void);

void serial_init(uint32_t speed);
void serial_write_byte(uint8_t data);
int16_t serial_read(void);

#ifdef __cplusplus
}
#endif

#endif /* PORT_H_ */
