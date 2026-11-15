/*
 * syscfg_write.c  —  HomePod (AudioAccessory1,1 / b238 / A8) SysCfg writer
 *
 * Writes a SysCfg region through Apple's own writable diagnostics driver,
 * AppleDiagnosticDataAccess, the way the factory diags image does. This is the
 * class that only ships in internal/diags builds; the production ReadOnly class
 * refuses writes. Run this on a booted 11.2 diags kernel (checkm8) AFTER the
 * writable kext is loaded (kextload AppleDiagnosticDataAccess.kext).
 *
 * Purpose: restore a repaired HomePod's OWN factory identity (serial, Wi-Fi/BT
 * MAC, region, housing color) to a freshly replaced NAND. It writes whatever
 * bytes you hand it to the named region at the given offset. There is no
 * "unlock" trick here — it uses the real Apple write path.
 *
 * Reverse-engineered IOKit contract (from AppleDiagnosticDataAccess::setProperties):
 *   setProperties(OSDictionary) on the AppleDiagnosticDataAccess service, caller
 *   must be root, with keys:
 *     "AppleDiagnosticDataSet"    = OSString  region name (e.g. AppleDiagnosticDataSysCfg)
 *     "AppleDiagnosticDataOffset" = OSNumber  byte offset into the region
 *     "AppleDiagnosticDataBuffer" = OSData    bytes to write
 *     "AppleDiagnosticDataCommit" = OSBoolean true => flush the region to NAND
 *   Flow: setProperties -> _writeBuffer (memmove into the cached region buffer)
 *         -> if commit, _writeRegion -> AppleEffaceableStorage::setBytes (NAND).
 *   Reads come back from the read-only property "AppleDiagnosticDataSysCfg".
 *
 * Build:   see build.sh (targets arm64 iPhoneOS; IOKit resolved via dlsym).
 *
 * SAFETY: dry-run by default (stages into the buffer, does NOT flush). You must
 * pass --commit AND --i-understand to actually write NAND. A bad SysCfg can make
 * a board fail to activate; always keep a copy of the source identity.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

/* ---- IOKit, resolved at runtime (the build SDK may lack IOKit headers) ---- */
typedef unsigned int  io_object_t;
typedef io_object_t   io_registry_entry_t;
typedef io_object_t   io_service_t;
typedef int           kern_return_t;
typedef unsigned int  mach_port_t;
#define KERN_SUCCESS 0

static CFMutableDictionaryRef (*p_IOServiceMatching)(const char *);
static io_service_t          (*p_IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef);
static kern_return_t         (*p_IORegistryEntrySetCFProperties)(io_registry_entry_t, CFTypeRef);
static CFTypeRef             (*p_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
static kern_return_t         (*p_IOObjectRelease)(io_object_t);

static int load_iokit(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!h) { fprintf(stderr, "cannot dlopen IOKit: %s\n", dlerror()); return -1; }
    p_IOServiceMatching              = dlsym(h, "IOServiceMatching");
    p_IOServiceGetMatchingService    = dlsym(h, "IOServiceGetMatchingService");
    p_IORegistryEntrySetCFProperties = dlsym(h, "IORegistryEntrySetCFProperties");
    p_IORegistryEntryCreateCFProperty= dlsym(h, "IORegistryEntryCreateCFProperty");
    p_IOObjectRelease                = dlsym(h, "IOObjectRelease");
    if (!p_IOServiceMatching || !p_IOServiceGetMatchingService ||
        !p_IORegistryEntrySetCFProperties || !p_IORegistryEntryCreateCFProperty ||
        !p_IOObjectRelease) { fprintf(stderr, "IOKit symbols missing\n"); return -1; }
    return 0;
}

/* Keys (exact strings from the driver). */
#define K_SET    "AppleDiagnosticDataSet"
#define K_OFF    "AppleDiagnosticDataOffset"
#define K_BUF    "AppleDiagnosticDataBuffer"
#define K_COMMIT "AppleDiagnosticDataCommit"
#define REGION_SYSCFG  "AppleDiagnosticDataSysCfg"
#define REGION_DISPLAY "AppleDiagnosticDataDisplay"

/* The writable node matches on class AppleDiagnosticDataAccess. */
#define WRITABLE_CLASS "AppleDiagnosticDataAccess"
#define READONLY_CLASS "AppleDiagnosticDataAccessReadOnly"

static io_service_t find_node(const char *cls) {
    CFMutableDictionaryRef m = p_IOServiceMatching(cls);
    if (!m) return 0;
    return p_IOServiceGetMatchingService(0 /*kIOMasterPortDefault*/, m);
}

static CFStringRef s(const char *c){ return CFStringCreateWithCString(NULL,c,kCFStringEncodingUTF8); }

static unsigned char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return NULL; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); fprintf(stderr, "empty/invalid file\n"); return NULL; }
    unsigned char *b = malloc(n);
    if (fread(b, 1, n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
    fclose(f); *out_len = (size_t)n; return b;
}

static CFDataRef read_region(io_service_t node, const char *region) {
    CFStringRef k = s(region);
    CFTypeRef v = p_IORegistryEntryCreateCFProperty(node, k, NULL, 0);
    CFRelease(k);
    if (v && CFGetTypeID(v) == CFDataGetTypeID()) return (CFDataRef)v;
    if (v) CFRelease(v);
    return NULL;
}

static void usage(const char *a0){
    fprintf(stderr,
      "usage:\n"
      "  %s info\n"
      "  %s read   <region> <out.bin>\n"
      "  %s write  <region> <in.bin> [--offset N] [--commit --i-understand]\n"
      "  %s verify <region> <expected.bin>\n"
      "\n"
      "  <region> = syscfg | display | <literal AppleDiagnosticData* name>\n"
      "  write is a DRY RUN (stage only, no NAND flush) unless --commit --i-understand.\n",
      a0,a0,a0,a0);
}

static const char *resolve_region(const char *r){
    if (!strcmp(r,"syscfg"))  return REGION_SYSCFG;
    if (!strcmp(r,"display")) return REGION_DISPLAY;
    return r; /* allow a literal region name */
}

int main(int argc, char **argv){
    if (argc < 2) { usage(argv[0]); return 2; }
    if (load_iokit()) return 1;

    const char *cmd = argv[1];

    if (!strcmp(cmd,"info")) {
        io_service_t w = find_node(WRITABLE_CLASS);
        io_service_t ro= find_node(READONLY_CLASS);
        printf("writable node (%s): %s\n", WRITABLE_CLASS, w ? "PRESENT" : "absent");
        printf("readonly node (%s): %s\n", READONLY_CLASS, ro ? "present" : "absent");
        if (!w) printf("  -> writable node absent: load the kext first "
                       "(kextload AppleDiagnosticDataAccess.kext) and confirm root.\n");
        io_service_t probe = w ? w : ro;
        if (probe) {
            CFDataRef d = read_region(probe, REGION_SYSCFG);
            if (d) { printf("SysCfg region readable: %ld bytes\n", (long)CFDataGetLength(d)); CFRelease(d); }
        }
        if (w) p_IOObjectRelease(w);
        if (ro) p_IOObjectRelease(ro);
        return 0;
    }

    if (!strcmp(cmd,"read") && argc == 4) {
        const char *region = resolve_region(argv[2]);
        io_service_t node = find_node(WRITABLE_CLASS);
        if (!node) node = find_node(READONLY_CLASS);
        if (!node) { fprintf(stderr,"no diagnostics node found\n"); return 1; }
        CFDataRef d = read_region(node, region);
        p_IOObjectRelease(node);
        if (!d) { fprintf(stderr,"region '%s' not readable\n", region); return 1; }
        FILE *o = fopen(argv[3],"wb");
        if (!o) { fprintf(stderr,"open out: %s\n", strerror(errno)); CFRelease(d); return 1; }
        fwrite(CFDataGetBytePtr(d), 1, CFDataGetLength(d), o);
        fclose(o);
        printf("read %ld bytes from '%s' -> %s\n", (long)CFDataGetLength(d), region, argv[3]);
        CFRelease(d);
        return 0;
    }

    if (!strcmp(cmd,"verify") && argc == 4) {
        const char *region = resolve_region(argv[2]);
        size_t elen=0; unsigned char *exp = read_file(argv[3], &elen);
        if (!exp) return 1;
        io_service_t node = find_node(WRITABLE_CLASS);
        if (!node) node = find_node(READONLY_CLASS);
        if (!node) { fprintf(stderr,"no diagnostics node found\n"); free(exp); return 1; }
        CFDataRef d = read_region(node, region);
        p_IOObjectRelease(node);
        if (!d) { fprintf(stderr,"region not readable\n"); free(exp); return 1; }
        long got = CFDataGetLength(d);
        int ok = (got == (long)elen) && (memcmp(CFDataGetBytePtr(d), exp, elen) == 0);
        printf("verify '%s': on-NAND=%ld bytes, expected=%zu bytes -> %s\n",
               region, got, elen, ok ? "MATCH" : "DIFFER");
        CFRelease(d); free(exp);
        return ok ? 0 : 3;
    }

    if (!strcmp(cmd,"write") && argc >= 4) {
        const char *region = resolve_region(argv[2]);
        const char *infile = argv[3];
        long offset = 0; int commit = 0, understood = 0;
        for (int i=4;i<argc;i++){
            if (!strcmp(argv[i],"--commit")) commit = 1;
            else if (!strcmp(argv[i],"--i-understand")) understood = 1;
            else if (!strcmp(argv[i],"--offset") && i+1<argc) offset = strtol(argv[++i],NULL,0);
            else { fprintf(stderr,"unknown arg: %s\n", argv[i]); return 2; }
        }
        int do_flush = commit && understood;

        size_t len=0; unsigned char *buf = read_file(infile, &len);
        if (!buf) return 1;

        io_service_t node = find_node(WRITABLE_CLASS);
        if (!node) {
            fprintf(stderr,"writable node absent. Load the kext (kextload "
                           "AppleDiagnosticDataAccess.kext) on a diags kernel, run as root.\n");
            free(buf); return 1;
        }

        /* Build the setProperties dict. */
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFStringRef kset=s(K_SET), koff=s(K_OFF), kbuf=s(K_BUF), kcom=s(K_COMMIT);
        CFStringRef rname = s(region);
        int64_t off64 = offset;
        CFNumberRef offn = CFNumberCreate(NULL, kCFNumberSInt64Type, &off64);
        CFDataRef data = CFDataCreate(NULL, buf, len);
        CFDictionarySetValue(dict, kset, rname);
        CFDictionarySetValue(dict, koff, offn);
        CFDictionarySetValue(dict, kbuf, data);
        CFDictionarySetValue(dict, kcom, do_flush ? kCFBooleanTrue : kCFBooleanFalse);

        printf("region  : %s\n", region);
        printf("offset  : 0x%lx\n", offset);
        printf("length  : %zu bytes\n", len);
        printf("commit  : %s\n", do_flush ? "YES (flush to NAND)" :
               (commit ? "requested but --i-understand missing -> staging only" : "no (dry run)"));

        kern_return_t kr = p_IORegistryEntrySetCFProperties(node, dict);

        CFRelease(dict); CFRelease(kset); CFRelease(koff); CFRelease(kbuf);
        CFRelease(kcom); CFRelease(rname); CFRelease(offn); CFRelease(data);
        p_IOObjectRelease(node);
        free(buf);

        if (kr != KERN_SUCCESS) {
            fprintf(stderr,"setProperties failed: 0x%08x\n", (unsigned)kr);
            if ((unsigned)kr == 0xe00002c1u) fprintf(stderr,"  (kIOReturnNotPrivileged — run as root)\n");
            if ((unsigned)kr == 0xe00002c4u) fprintf(stderr,"  (kIOReturnNotWritable — ReadOnly node; writable kext not loaded)\n");
            if ((unsigned)kr == 0xe00002c7u) fprintf(stderr,"  (kIOReturnUnsupported — provider write path not present; not a diags kernel)\n");
            return 1;
        }
        printf("setProperties OK%s\n", do_flush ? " — committed. Re-read to verify." :
               " — staged only (no NAND change). Re-run with --commit --i-understand to flush.");
        return 0;
    }

    usage(argv[0]);
    return 2;
}
