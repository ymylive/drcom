ifeq ($(origin CC), default)
CC := gcc
endif

EXEEXT :=
ifeq ($(OS),Windows_NT)
EXEEXT := .exe
RMFILES := cmd /C del /Q /F
CLEAN_REDIRECT := 2>NUL
else
RMFILES := $(RM)
CLEAN_REDIRECT :=
endif

TARGET ?= dogcom$(EXEEXT)
CPPFLAGS += -I.
CFLAGS += -std=gnu99 -Wno-unused-result
LDFLAGS +=
LDLIBS +=

ifeq ($(debug),y)
CFLAGS += -DDEBUG -g
endif

ifeq ($(win32),y)
LDLIBS += -lws2_32
endif

ifeq ($(static),y)
LDFLAGS += -static
endif

ifeq ($(force_encrypt),y)
CFLAGS += -DFORCE_ENCRYPT
endif

SOURCES := $(wildcard *.c) $(wildcard libs/*.c)
OBJECTS := $(patsubst %.c,%.o,$(SOURCES))
TEST_PARSER_BIN := tests/parser_smoke$(EXEEXT)
TEST_PARSER_SOURCES := tests/parser_smoke.c configparse.c

ifeq ($(OS),Windows_NT)
CLEAN_OBJECTS := $(subst /,\,$(OBJECTS))
CLEAN_TARGETS := $(subst /,\,$(TARGET)) $(subst /,\,$(TEST_PARSER_BIN))
else
CLEAN_OBJECTS := $(OBJECTS)
CLEAN_TARGETS := $(TARGET) $(TEST_PARSER_BIN)
endif

all: $(TARGET)

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) $(LDFLAGS) $(LDLIBS) -o $@

$(TEST_PARSER_BIN): $(TEST_PARSER_SOURCES) configparse.h debug.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(TEST_PARSER_SOURCES) -o $(TEST_PARSER_BIN)

test-parser: $(TEST_PARSER_BIN)
	./$(TEST_PARSER_BIN)

clean:
	-$(RMFILES) $(CLEAN_OBJECTS) $(CLEAN_TARGETS) $(CLEAN_REDIRECT)

.PHONY: all clean test-parser
