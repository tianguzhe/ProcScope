#ifndef ProcBridge_h
#define ProcBridge_h
#include <libproc.h>
#include <sys/proc_info.h>
static inline uint32_t procscope_path_buffer_size(void) { return PROC_PIDPATHINFO_MAXSIZE; }
#endif
