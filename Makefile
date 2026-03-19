# Makefile — geoip2nftset / geosite2nftset C 工具
#
# 用法:
#   make                        # 本地编译 (macOS / Linux)
#   make CC=aarch64-openwrt-linux-musl-gcc LDFLAGS="-static"  # 交叉编译
#   make clean

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=c11
LDFLAGS ?=

SRCDIR  = src
TARGETS = geoip2nftset geosite2nftset

.PHONY: all clean

all: $(TARGETS)

geoip2nftset: $(SRCDIR)/geoip2nftset.c $(SRCDIR)/protobuf.h $(SRCDIR)/util.h
	$(CC) $(CFLAGS) $(LDFLAGS) -I$(SRCDIR) -o $@ $(SRCDIR)/geoip2nftset.c

geosite2nftset: $(SRCDIR)/geosite2nftset.c $(SRCDIR)/protobuf.h $(SRCDIR)/util.h
	$(CC) $(CFLAGS) $(LDFLAGS) -I$(SRCDIR) -o $@ $(SRCDIR)/geosite2nftset.c

clean:
	rm -f $(TARGETS)
