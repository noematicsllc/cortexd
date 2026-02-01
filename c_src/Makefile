# Makefile for peercred NIF

ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS = -fPIC -shared -O2 -Wall
LDFLAGS = -shared

ifeq ($(shell uname), Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
endif

all: ../priv/peercred_nif.so

../priv/peercred_nif.so: peercred_nif.c
	@mkdir -p ../priv
	$(CC) $(CFLAGS) -I$(ERLANG_PATH) -o $@ $< $(LDFLAGS)

clean:
	rm -f ../priv/peercred_nif.so

.PHONY: all clean
