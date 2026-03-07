CC ?= gcc
TARGET ?= dogcom
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

all: $(TARGET)

%.o: %.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(TARGET): $(OBJECTS)
	$(CC) $(OBJECTS) $(LDFLAGS) $(LDLIBS) -o $@

clean:
	rm -f $(OBJECTS) $(TARGET)

.PHONY: all clean