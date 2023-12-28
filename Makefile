PROD_EXE_SOURCES = ./src/prodmain.c
PROD_LIB_SOURCES = ./src/add.c ./src/port.c
TEST_LIB_SOURCES = ./test/testmain.c ./test/testrunner.c \
    ./test/test_add.c ./test/test_add_runner.c

INCLUDE_DIRS = -I./include/

PROD_EXE_HEADERS =
PROD_LIB_HEADERS = ./include/add.h ./include/port.h
TEST_LIB_HEADERS =

FRAMEWORK_INCLUDE_DIRS = -I./dep/unity/src/ -I./dep/unity/extras/fixture/src/
FRAMEWORK_HEADERS = ./dep/unity/src/unity.h ./dep/unity/src/unity_internals.h \
    ./dep/unity/extras/fixture/src/unity_fixture.h \
    ./dep/unity/extras/fixture/src/unity_fixture_internals.h
FRAMEWORK_SOURCES = ./dep/unity/src/unity.c \
    ./dep/unity/extras/fixture/src/unity_fixture.c

DIR = build
CC = avr-gcc
CFLAGS = \
    -mmcu=atmega2560 -Os -g3 \
    -std=c99 -pedantic -Wall -Wextra -Wundef -Werror \
    -fdata-sections -ffunction-sections \
    -DUNITY_FIXTURE_NO_EXTRAS -Wno-error
LDFLAGS = -Wl,--gc-sections

# Black magic necessary to make things work on Windows too.
ifeq ($(OS),Windows_NT)
    # Windows
    SERIAL = COM0
    ifeq ($(ComSpec),C:\Windows\system32\cmd.exe)
        # CMD, Powershell
        MKDIR_BUILD_DIR = mkdir $(DIR) >nul 2>&1 || exit 0
        SIM_TIMEOUT = 1
        BACKGROUND_QEMU = START /B
        AUTOKILL_QEMU = && timeout -t $(SIM_TIMEOUT) >nul && taskkill -IM qemu-system-avr.exe -F
        # TODO: Generate an exit status based on Qemu output (as it is done in Linux and Git Bash implementation)
    else
        # Git Bash
        MKDIR_BUILD_DIR = mkdir -p $(DIR)
        SIM_TIMEOUT = 0.1
        BACKGROUND_QEMU =
        AUTOKILL_QEMU = | (timeout $(SIM_TIMEOUT) sed -Ee '/^(OK|FAIL)$$/{q}'; RET=$$?; taskkill -IM qemu-system-avr.exe -F; exit $$RET)
    endif
else
    # Linux
    SERIAL = /dev/ttyACM0
    MKDIR_BUILD_DIR = mkdir -p $(DIR)
    SIM_TIMEOUT = 0.1
    BACKGROUND_QEMU =
    AUTOKILL_QEMU = | (timeout $(SIM_TIMEOUT) sed -Ee '/^(OK|FAIL)$$/{q}'; RET=$$?; pkill qemu-system-avr || killall qemu-system-avr; exit $$RET)
endif

all: test_build prod_build

clean:
	rm -fr $(DIR)

$(DIR)/test.elf: Makefile $(PROD_LIB_SOURCES) $(TEST_LIB_SOURCES) $(FRAMEWORK_SOURCES) $(PROD_LIB_HEADERS) $(TEST_LIB_HEADERS) $(FRAMEWORK_HEADERS)
	@-$(MKDIR_BUILD_DIR)
	$(CC) -o $@ $(CFLAGS) $(PROD_LIB_SOURCES) $(TEST_LIB_SOURCES) $(FRAMEWORK_SOURCES) $(INCLUDE_DIRS) $(FRAMEWORK_INCLUDE_DIRS) $(LDFLAGS)
	avr-objcopy -O ihex $@ $(@:%.elf=%.hex)
	avr-size $@

$(DIR)/prod.elf: Makefile $(PROD_LIB_SOURCES) $(PROD_EXE_SOURCES) $(PROD_LIB_HEADERS) $(PROD_EXE_HEADERS)
	@-$(MKDIR_BUILD_DIR)
	$(CC) -o $@ $(CFLAGS) $(PROD_LIB_SOURCES) $(PROD_EXE_SOURCES) $(INCLUDE_DIRS) $(LDFLAGS)
	avr-objcopy -O ihex $@ $(@:%.elf=%.hex)
	avr-size $@

test_build: $(DIR)/test.elf
prod_build: $(DIR)/prod.elf

test_flash: $(DIR)/test.elf
	avrdude -p atmega2560 -c stk500v2 -P $(SERIAL) -b 115200 -D -V -U flash:w:$(@:%.elf=%.hex)

prod_flash: $(DIR)/prod.elf
	avrdude -p atmega2560 -c stk500v2 -P $(SERIAL) -b 115200 -D -V -U flash:w:$(@:%.elf=%.hex)

test_sim: $(DIR)/test.elf
	@echo
	@echo "| COMMAND              | DESCRIPTION |"
	@echo "|----------------------|-------------|"
	@echo "| Ctrl+A (release) + X | Quit        |"
	@echo
	$(BACKGROUND_QEMU) qemu-system-avr -machine mega2560 -nographic -serial mon:stdio -bios $(DIR)/test.elf \
	$(AUTOKILL_QEMU)

prod_sim: $(DIR)/prod.elf
	@echo
	@echo "| COMMAND              | DESCRIPTION |"
	@echo "|----------------------|-------------|"
	@echo "| Ctrl+A (release) + X | Quit        |"
	@echo
	qemu-system-avr -machine mega2560 -nographic -serial mon:stdio -bios $(DIR)/prod.elf

    # Qemu commands:
    # Ctrl+A (release) + X
    #
    # Qemu options:
    # -serial mon:stdio
    # -serial tcp:127.0.0.1:6000
    # -serial tcp:127.0.0.1:6000,server=on,wait=on
    # -s -S -- avr-gdb build/main_avr.elf -ex 'target remote :1234'
