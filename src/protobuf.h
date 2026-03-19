/*
 * protobuf.h — 轻量级 protobuf 手动解码器 (header-only)
 *
 * 支持 proto3 wire format 的基础解码：varint、length-delimited、
 * fixed32/64 的读取和跳过。用于解析 V2Ray/Xray 的 geoip.dat /
 * geosite.dat 文件，无需 protoc 或 libprotobuf。
 */

#ifndef PROTOBUF_H
#define PROTOBUF_H

#include <stddef.h>
#include <stdint.h>

/* Wire types */
enum {
    WIRE_VARINT            = 0,
    WIRE_64BIT             = 1,
    WIRE_LENGTH_DELIMITED  = 2,
    WIRE_32BIT             = 5,
};

/* 带位置追踪的字节缓冲区 */
typedef struct {
    const uint8_t *data;
    size_t         len;
    size_t         pos;
} buf_t;

/* protobuf tag (field_number + wire_type) */
typedef struct {
    uint32_t field;
    uint32_t wire;
} pb_tag_t;

/* length-delimited 子消息的指针 + 长度 */
typedef struct {
    const uint8_t *data;
    size_t         len;
} pb_bytes_t;

/* ------------------------------------------------------------------ */
/*  Inline implementations                                             */
/* ------------------------------------------------------------------ */

static inline void buf_init(buf_t *b, const uint8_t *data, size_t len)
{
    b->data = data;
    b->len  = len;
    b->pos  = 0;
}

static inline int buf_eof(const buf_t *b)
{
    return b->pos >= b->len;
}

/*
 * 读取 varint，成功返回 0，到达末尾或溢出返回 -1。
 */
static inline int pb_read_varint(buf_t *b, uint64_t *out)
{
    uint64_t result = 0;
    int shift = 0;
    while (b->pos < b->len) {
        uint8_t byte = b->data[b->pos++];
        result |= (uint64_t)(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            *out = result;
            return 0;
        }
        shift += 7;
        if (shift >= 64) return -1; /* overflow */
    }
    return -1; /* unexpected EOF */
}

/*
 * 读取 tag。成功返回 0，到达末尾返回 -1。
 */
static inline int pb_read_tag(buf_t *b, pb_tag_t *tag)
{
    uint64_t v;
    if (pb_read_varint(b, &v) < 0) return -1;
    tag->field = (uint32_t)(v >> 3);
    tag->wire  = (uint32_t)(v & 0x07);
    return 0;
}

/*
 * 读取 length-delimited 字段，返回指向数据的指针和长度。
 */
static inline int pb_read_bytes(buf_t *b, pb_bytes_t *out)
{
    uint64_t len;
    if (pb_read_varint(b, &len) < 0) return -1;
    if (b->pos + len > b->len) return -1;
    out->data = b->data + b->pos;
    out->len  = (size_t)len;
    b->pos   += (size_t)len;
    return 0;
}

/*
 * 跳过一个字段（根据 wire_type）。
 */
static inline int pb_skip_field(buf_t *b, uint32_t wire_type)
{
    switch (wire_type) {
    case WIRE_VARINT: {
        uint64_t dummy;
        return pb_read_varint(b, &dummy);
    }
    case WIRE_64BIT:
        if (b->pos + 8 > b->len) return -1;
        b->pos += 8;
        return 0;
    case WIRE_LENGTH_DELIMITED: {
        pb_bytes_t dummy;
        return pb_read_bytes(b, &dummy);
    }
    case WIRE_32BIT:
        if (b->pos + 4 > b->len) return -1;
        b->pos += 4;
        return 0;
    default:
        return -1;
    }
}

#endif /* PROTOBUF_H */
