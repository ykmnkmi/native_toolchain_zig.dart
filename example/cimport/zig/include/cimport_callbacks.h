#ifndef CIMPORT_CALLBACKS_H
#define CIMPORT_CALLBACKS_H

#include <stddef.h>
#include <stdint.h>

#include "cimport_types.h"

typedef int32_t (*CImportFoldFn)(CImportPoint point, void *user);
typedef void (*CImportVisitFn)(const CImportPoint *point, void *user);

typedef struct CImportAccumulator {
    CImportFoldFn fold;
    void *user;
} CImportAccumulator;

#endif
