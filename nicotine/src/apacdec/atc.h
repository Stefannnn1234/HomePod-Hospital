#pragma once
#include <stdint.h>
typedef struct { uint32_t type, subtype, manufacturer, flags, mask; } acd_t;
typedef struct { acd_t desc; void *factory; const char *name; } component_t;
typedef struct plugin { int (*Open)(void *self, void *instance); int (*Close)(void *self); void *(*Lookup)(int16_t selector); void *reserved; } plugin_t;
typedef struct { component_t *comp; plugin_t *plugin; } instance_t;
extern component_t g_components[]; extern int g_ncomponents;
