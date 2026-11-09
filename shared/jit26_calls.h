#pragma once
#include <stddef.h>

#define JIT26_LEGACY_UNIVERSAL_MAGIC 0x690000E0UL

void JIT26Detach(void);
void *JIT26PrepareRegion(void *addr, size_t len);
void BreakSendJITScript(const char *script, size_t len);
void JIT26SetDetachAfterFirstBr(long value);
void JIT26PrepareRegionForPatching(void *addr, size_t size);
void *JIT26CreateRegionLegacy(size_t len);
