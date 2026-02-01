# Top-level Makefile for NIF compilation

ERLANG_PATH = $(shell erl -eval 'io:format("~s", [lists:concat([code:root_dir(), "/erts-", erlang:system_info(version), "/include"])])' -s init stop -noshell)
CFLAGS = -fPIC -O2 -Wall -I$(ERLANG_PATH)

ifeq ($(shell uname), Darwin)
	LDFLAGS = -bundle -undefined dynamic_lookup
else
	LDFLAGS = -shared
endif

PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/peercred_nif.so

all: $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(NIF_SO): c_src/peercred_nif.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
