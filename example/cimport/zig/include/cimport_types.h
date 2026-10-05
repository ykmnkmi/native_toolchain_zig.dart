#ifndef CIMPORT_TYPES_H
#define CIMPORT_TYPES_H

#include <stddef.h>
#include <stdint.h>

#define CIMPORT_MAGIC 0x1f2e3d4c
#define CIMPORT_LABEL_MAX 32

typedef enum CImportKind {
    CImportKind_invalid = 0,
    CImportKind_point = 1,
    CImportKind_blob = 2,
    CImportKind_packet = 3,
} CImportKind;

typedef struct CImportPoint {
    int32_t x;
    int32_t y;
} CImportPoint;

typedef union CImportValue {
    int64_t as_i64;
    double as_f64;
    const char *as_str;
    CImportPoint as_point;
} CImportValue;

typedef struct CImportPacket {
    CImportKind kind;
    uint32_t flags;
    size_t count;
    uint8_t bytes[16];
    CImportPoint points[2];
    CImportValue value;
} CImportPacket;

typedef struct CImportNode {
    int32_t id;
    CImportKind kind;
    CImportPoint point;
    CImportValue value;
    struct CImportNode *next;
} CImportNode;

typedef struct CImportTable {
    size_t length;
    const CImportPacket *packets;
} CImportTable;

#endif
