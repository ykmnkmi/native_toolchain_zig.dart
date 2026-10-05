#ifndef CIMPORT_STRESS_H
#define CIMPORT_STRESS_H

#include "cimport_callbacks.h"

#ifdef __cplusplus
extern "C" {
#endif

CImportPacket cimport_make_packet(CImportKind kind, int32_t x, int32_t y);
CImportPoint cimport_point_make(int32_t x, int32_t y);
CImportValue cimport_value_from_int(int64_t value);
CImportValue cimport_value_from_double(double value);
CImportValue cimport_value_from_string(const char *value);

CImportNode *cimport_node_create(int32_t id, CImportKind kind, CImportPoint point, CImportValue value);
CImportNode *cimport_node_append(CImportNode *head, CImportNode *node);
void cimport_node_destroy(CImportNode *node);
size_t cimport_node_count(const CImportNode *node);
int64_t cimport_node_sum(const CImportNode *node);

int64_t cimport_sum_points(const CImportPoint *points, size_t len);
int32_t cimport_fold_points(const CImportPoint *points, size_t len, CImportFoldFn fold, void *user);
void cimport_visit_points(const CImportPoint *points, size_t len, CImportVisitFn visit, void *user);
const char *cimport_kind_name(CImportKind kind);
size_t cimport_packet_checksum(CImportPacket packet);

#ifdef __cplusplus
}
#endif

#endif
