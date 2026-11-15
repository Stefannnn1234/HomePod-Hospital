// syscfgset — probe/read/write the HomePod SysCfg diagnostics node.
//
// The SSH ramdisk is tvOS (Apple TV donor) and the tvOS SDK ships no IOKit — so
// we don't link or include IOKit at all. We declare the few IOKit calls we need
// and resolve them at runtime from the pod's own IOKit.framework via dlsym. Only
// CoreFoundation (present in the tvOS SDK) is linked, for CFSTR/CFData/CFDict.
//
// Read is proven. Write tests: setProperties({"AppleDiagnosticDataSysCfg": blob}).
// SAFETY: default read-only; `write` needs --i-understand and a 'gfCS' signature.
// First test: write the SAME bytes you just read back (no-op round-trip).
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <mach/mach.h>            // mach_port_t, kern_return_t, mach_error_string
#include <CoreFoundation/CoreFoundation.h>

// Minimal IOKit types (normally from <IOKit/IOKitLib.h>).
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_registry_entry_t;
typedef char io_name_t[128];

// IOKit calls resolved at runtime.
static CFMutableDictionaryRef (*p_IOServiceMatching)(const char *);
static io_service_t (*p_IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef);
static CFTypeRef (*p_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
static kern_return_t (*p_IOObjectRelease)(io_object_t);
static kern_return_t (*p_IOObjectGetClass)(io_object_t, io_name_t);
static kern_return_t (*p_IORegistryEntrySetCFProperties)(io_registry_entry_t, CFTypeRef);

static const char *kClass = "AppleDiagnosticDataAccessReadOnly";
#define KEY CFSTR("AppleDiagnosticDataSysCfg")

static int load_iokit(void) {
    const char *paths[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
        "IOKit", NULL };
    void *h = NULL;
    for (int i = 0; paths[i] && !h; i++) h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
    if (!h) h = RTLD_DEFAULT;
    p_IOServiceMatching            = dlsym(h, "IOServiceMatching");
    p_IOServiceGetMatchingService  = dlsym(h, "IOServiceGetMatchingService");
    p_IORegistryEntryCreateCFProperty = dlsym(h, "IORegistryEntryCreateCFProperty");
    p_IOObjectRelease              = dlsym(h, "IOObjectRelease");
    p_IOObjectGetClass             = dlsym(h, "IOObjectGetClass");
    p_IORegistryEntrySetCFProperties = dlsym(h, "IORegistryEntrySetCFProperties");
    return p_IOServiceMatching && p_IOServiceGetMatchingService &&
           p_IORegistryEntryCreateCFProperty && p_IOObjectRelease;
}

static io_service_t find_node(void) {
    // kIOMainPortDefault == MACH_PORT_NULL (0) on modern systems.
    return p_IOServiceGetMatchingService(0, p_IOServiceMatching(kClass));
}

static io_service_t find_service(const char *cls) {
    return p_IOServiceGetMatchingService(0, p_IOServiceMatching(cls));
}

// Unlock NAND writes on a ramdisk-booted pod: ASPStorage force-locks the NAND
// read-only when root is a ramdisk; setProperties({"ASPSetWritable": true}) on
// the ASPStorage node clears it (kernel sends ASP firmware cmd 0x81).
static int do_unlock(void) {
    if (!p_IORegistryEntrySetCFProperties) { fprintf(stderr, "setProperties unavailable\n"); return 6; }
    io_service_t asp = find_service("ASPStorage");
    if (!asp) { fprintf(stderr, "ASPStorage node not found\n"); return 8; }
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("ASPSetWritable"), kCFBooleanTrue);
    kern_return_t kr = p_IORegistryEntrySetCFProperties(asp, d);
    CFRelease(d);
    if (p_IOObjectRelease) p_IOObjectRelease(asp);
    printf("unlock (ASPSetWritable) -> 0x%x (%s)\n", kr, kr==0 ? "SUCCESS" : mach_error_string(kr));
    return kr==0 ? 0 : 9;
}

static CFDataRef read_blob(io_service_t svc) {
    CFTypeRef v = p_IORegistryEntryCreateCFProperty(svc, KEY, kCFAllocatorDefault, 0);
    if (v && CFGetTypeID(v) == CFDataGetTypeID()) return (CFDataRef)v;
    if (v) CFRelease(v);
    return NULL;
}

static int do_probe(io_service_t svc) {
    io_name_t cls = {0};
    if (p_IOObjectGetClass) p_IOObjectGetClass(svc, cls);
    printf("node class: %s\n", cls[0] ? cls : "(unknown)");
    CFDataRef d = read_blob(svc);
    if (!d) { printf("no AppleDiagnosticDataSysCfg property\n"); return 2; }
    printf("SysCfg blob: %ld bytes, sig %.4s\n", (long)CFDataGetLength(d), (const char*)CFDataGetBytePtr(d));
    CFRelease(d);
    printf("setprops symbol: %s\n", p_IORegistryEntrySetCFProperties ? "resolved" : "NOT FOUND");
    return 0;
}

static int do_read(io_service_t svc, const char *path) {
    CFDataRef d = read_blob(svc);
    if (!d) { fprintf(stderr, "read failed: no blob\n"); return 2; }
    FILE *f = fopen(path, "wb");
    if (!f) { perror("fopen"); CFRelease(d); return 3; }
    fwrite(CFDataGetBytePtr(d), 1, CFDataGetLength(d), f);
    fclose(f);
    printf("wrote %ld bytes to %s\n", (long)CFDataGetLength(d), path);
    CFRelease(d);
    return 0;
}

static int do_write(io_service_t svc, const char *path) {
    if (!p_IORegistryEntrySetCFProperties) { fprintf(stderr, "setProperties not available\n"); return 6; }
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return 3; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n < 8) { fprintf(stderr, "blob too small\n"); fclose(f); return 4; }
    UInt8 *buf = malloc(n);
    if (fread(buf, 1, n, f) != (size_t)n) { fprintf(stderr, "short read\n"); fclose(f); free(buf); return 3; }
    fclose(f);
    if (memcmp(buf, "gfCS", 4) != 0) { fprintf(stderr, "refusing: not a SysCfg blob ('gfCS')\n"); free(buf); return 4; }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, n);
    free(buf);
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, KEY, data);
    kern_return_t kr = p_IORegistryEntrySetCFProperties(svc, props);
    CFRelease(props); CFRelease(data);
    printf("set result: 0x%x (%s)\n", kr, kr == 0 ? "SUCCESS" : mach_error_string(kr));
    return kr == 0 ? 0 : 5;
}

int main(int argc, char **argv) {
    if (!load_iokit()) { fprintf(stderr, "couldn't resolve IOKit from the pod\n"); return 7; }
    const char *cmd = argc > 1 ? argv[1] : "probe";
    io_service_t svc = find_node();
    if (!svc) { fprintf(stderr, "no SysCfg diagnostics node found\n"); return 1; }
    int rc;
    if (!strcmp(cmd, "probe")) rc = do_probe(svc);
    else if (!strcmp(cmd, "read") && argc > 2) rc = do_read(svc, argv[2]);
    else if (!strcmp(cmd, "unlock")) rc = do_unlock();
    else if (!strcmp(cmd, "write") && argc > 3 && !strcmp(argv[3], "--i-understand")) rc = do_write(svc, argv[2]);
    else if (!strcmp(cmd, "writeunlock") && argc > 3 && !strcmp(argv[3], "--i-understand")) {
        rc = do_unlock();
        if (rc == 0) rc = do_write(svc, argv[2]);
    }
    else if (!strcmp(cmd, "write") || !strcmp(cmd, "writeunlock")) { fprintf(stderr, "needs: %s <in.bin> --i-understand\n", cmd); rc = 64; }
    else { fprintf(stderr, "usage: syscfgset probe | read <out> | unlock | write <in> --i-understand | writeunlock <in> --i-understand\n"); rc = 64; }
    if (p_IOObjectRelease) p_IOObjectRelease(svc);
    return rc;
}
