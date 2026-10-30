/*
 * PandoraAudio.driver -- an AudioServerPlugIn that drives bsd/dev/PandoraAudio.cpp directly.
 *
 * Why: iOS's own HAL plug-in (VirtualAudio) never opened our IOAudio2Device (12 replugs, no "opened by",
 * 2026-10-30 h1-h5), and its routing database only knows the devices of the real phone. This plug-in is the
 * HAL instead: it declares one 48 kHz / 2 ch / s32 "Pandora Speaker" output and, in StartIO, talks to the
 * kernel service the same way the HAL used to:
 *
 *   IOServiceMatching("IOAudio2Device") ... property "device UID" == "Speaker"
 *   IOServiceOpen, map memory type 0 (engine status page) and 0x10000001 (stream 1's ring)
 *   method 6 (set stream active: stream 1, active 1), method 0 (engine start)
 *   DoIOOperation(WriteMix) -> convert float32 -> s32 into the ring at mOutputTime.mSampleTime
 *
 * IOKit is called through dlsym(RTLD_DEFAULT) so the bundle needs no link-time dependency on it: it runs
 * inside mediaserverd, which already has it.
 *
 * Diagnostics go to stderr, which launchd points at /dev/null; the kernel's `sweetnull=mediaserverd`
 * boot-arg tees that into the kernel log, so every line shows up as "|mediaserverd| PANDORA HAL: ...".
 */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFBundle.h>
#include <dlfcn.h>
#include <math.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>

/* ------------------------------------------------------------------ constants */

#define PA_RATE          48000.0
#define PA_CHANNELS      2
#define PA_RING_FRAMES   16384u
#define PA_STREAM_ID     1u

#define kPAObjectPlugIn  1u
#define kPAObjectDevice  2u
#define kPAObjectStream  3u

#define PA_4CC(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

#define PA_UID           "PandoraSpeaker"
#define PA_DEVICE_NAME   "Pandora Speaker"
#define PA_MANUFACTURER  "Pandora"
#define PA_BUNDLE_ID     "com.pandora.PandoraAudio"

/* ------------------------------------------------------------------ logging */

static void
pa_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("PANDORA HAL: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

/* ------------------------------------------------------------------ IOKit through dlsym */

typedef uint32_t IOOptionBits;              /* IOKit/IOTypes.h, not pulled in here */
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_iterator_t;
typedef io_object_t io_connect_t;
typedef kern_return_t (*fn_get_matching)(mach_port_t, CFDictionaryRef, io_iterator_t *);
typedef io_object_t (*fn_iter_next)(io_iterator_t);
typedef kern_return_t (*fn_obj_release)(io_object_t);
typedef CFMutableDictionaryRef (*fn_service_matching)(const char *);
typedef CFTypeRef (*fn_reg_prop)(io_object_t, CFStringRef, CFAllocatorRef, IOOptionBits);
typedef kern_return_t (*fn_open)(io_service_t, task_port_t, uint32_t, io_connect_t *);
typedef kern_return_t (*fn_close)(io_connect_t);
typedef kern_return_t (*fn_call_scalar)(io_connect_t, uint32_t, const uint64_t *, uint32_t, uint64_t *, uint32_t *);
typedef kern_return_t (*fn_map_memory64)(io_connect_t, uint32_t, task_port_t, mach_vm_address_t *, mach_vm_size_t *,
    IOOptionBits);

typedef struct {
	fn_service_matching service_matching;
	fn_get_matching     get_matching;
	fn_iter_next        iterator_next;
	fn_obj_release      object_release;
	fn_reg_prop         registry_prop;
	fn_open             service_open;
	fn_close            service_close;
	fn_call_scalar      call_scalar;
	fn_map_memory64     map_memory64;
	bool                ok;
} pa_iokit_t;

static pa_iokit_t g_iokit;

static void
pa_iokit_load(void)
{
	if (g_iokit.ok) {
		return;
	}
	g_iokit.service_matching = (fn_service_matching)dlsym(RTLD_DEFAULT, "IOServiceMatching");
	g_iokit.get_matching = (fn_get_matching)dlsym(RTLD_DEFAULT, "IOServiceGetMatchingServices");
	g_iokit.iterator_next = (fn_iter_next)dlsym(RTLD_DEFAULT, "IOIteratorNext");
	g_iokit.object_release = (fn_obj_release)dlsym(RTLD_DEFAULT, "IOObjectRelease");
	g_iokit.registry_prop = (fn_reg_prop)dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
	g_iokit.service_open = (fn_open)dlsym(RTLD_DEFAULT, "IOServiceOpen");
	g_iokit.service_close = (fn_close)dlsym(RTLD_DEFAULT, "IOServiceClose");
	g_iokit.call_scalar = (fn_call_scalar)dlsym(RTLD_DEFAULT, "IOConnectCallScalarMethod");
	g_iokit.map_memory64 = (fn_map_memory64)dlsym(RTLD_DEFAULT, "IOConnectMapMemory64");
	g_iokit.ok = g_iokit.service_matching && g_iokit.get_matching && g_iokit.iterator_next &&
	    g_iokit.object_release && g_iokit.registry_prop && g_iokit.service_open && g_iokit.service_close &&
	    g_iokit.call_scalar && g_iokit.map_memory64;
	if (!g_iokit.ok) {
		pa_log("IOKit symbols not available, cannot reach the device");
	}
}

/* ------------------------------------------------------------------ driver state */

typedef struct {
	AudioServerPlugInDriverInterface *iface;      /* must stay first: the host holds this pointer */
	UInt32                            refs;
	AudioServerPlugInHostRef          host;
	Boolean                           initialized;

	/* IO */
	pthread_mutex_t                   lock;
	io_connect_t                      conn;
	bool                              running;
	uint64_t                          started_host;      /* host time when IO started */
	uint64_t                          frames_written;
	volatile int32_t                 *status;            /* engine status page: sample, host, seed, ... */
	volatile int32_t                 *ring;              /* PA_RING_FRAMES * 2 s32 */
	mach_vm_size_t                    status_size, ring_size;
	uint32_t                          io_buffer_frames;
} pa_driver_t;

static pa_driver_t g_driver;

static UInt32 g_refs = 1;

static AudioServerPlugInDriverInterface g_iface;          /* the table itself is defined near the end */
static AudioServerPlugInDriverInterface *g_iface_ptr = &g_iface;

static ULONG STDMETHODCALLTYPE pa_AddRef(void *inDriver);
static ULONG STDMETHODCALLTYPE pa_Release(void *inDriver);

/* ------------------------------------------------------------------ helpers */

static void *
pa_alloc(UInt32 size)
{
	void *p = calloc(1, size ? size : 1);
	return p;
}

static OSStatus
pa_write_u32(UInt32 *outSize, void *out, const void *src, UInt32 n)
{
	if (*outSize < n) {
		*outSize = n;
		return kAudioHardwareBadPropertySizeError;
	}
	memcpy(out, src, n);
	*outSize = n;
	return noErr;
}

static OSStatus
pa_write_cf(UInt32 *outSize, void *out, CFTypeRef value)
{
	if (*outSize < sizeof(CFTypeRef)) {
		*outSize = sizeof(CFTypeRef);
		return kAudioHardwareBadPropertySizeError;
	}
	*(CFTypeRef *)out = value;                        /* the host releases it */
	*outSize = sizeof(CFTypeRef);
	return noErr;
}

static CFStringRef
pa_cfstr(const char *s)
{
	return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

/* ------------------------------------------------------------------ properties */

/* The host walks the property space before it creates devices; log the first few so a silent plug-in is
 * visible in the kernel log ("|mediaserverd| PANDORA HAL: prop ..."). */
static unsigned g_prop_logs;

static void
pa_log_prop(const char *what, AudioObjectID id, const AudioObjectPropertyAddress *a, OSStatus err)
{
	if (g_prop_logs >= 40) {
		return;
	}
	g_prop_logs++;
	char sel[5] = { (char)(a->mSelector >> 24), (char)(a->mSelector >> 16), (char)(a->mSelector >> 8),
		(char)a->mSelector, 0 };
	char sc[5] = { (char)(a->mScope >> 24), (char)(a->mScope >> 16), (char)(a->mScope >> 8), (char)a->mScope, 0 };
	pa_log("prop %s id %u %s/%s elem %u -> %d", what, (unsigned)id, sel, sc, (unsigned)a->mElement, (int)err);
}

static OSStatus
pa_plugin_data(UInt32 *size, void *out, const AudioObjectPropertyAddress *a)
{
	UInt32 one = 1;
	switch (a->mSelector) {
	case kAudioObjectPropertyClass: {
		AudioClassID c = kAudioPlugInClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyBaseClass: {
		AudioClassID c = kAudioObjectClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyOwner: {
		AudioObjectID o = kAudioObjectUnknown;
		return pa_write_u32(size, out, &o, sizeof(o));
	}
	case kAudioObjectPropertyName:
		return pa_write_cf(size, out, pa_cfstr("Pandora Audio"));
	case kAudioPlugInPropertyBundleID:
		return pa_write_cf(size, out, pa_cfstr(PA_BUNDLE_ID));
	case kAudioPlugInPropertyDeviceList: {
		AudioObjectID ids[1] = { kPAObjectDevice };
		return pa_write_u32(size, out, ids, sizeof(ids));
	}
	case kAudioPlugInPropertyTranslateUIDToDevice: {
		AudioObjectID id = kPAObjectDevice;                 /* only one device */
		return pa_write_u32(size, out, &id, sizeof(id));
	}
	case kAudioPlugInPropertyResourceBundle: {
		CFURLRef url = CFBundleCopyBundleURL(CFBundleGetMainBundle());
		CFStringRef path = url ? CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) : NULL;
		if (url) {
			CFRelease(url);
		}
		return pa_write_cf(size, out, path);
	}
	default:
		(void)one;
		return kAudioHardwareUnknownPropertyError;
	}
}

static OSStatus
pa_device_data(UInt32 *size, void *out, const AudioObjectPropertyAddress *a)
{
	switch (a->mSelector) {
	case kAudioObjectPropertyClass: {
		AudioClassID c = kAudioDeviceClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyBaseClass: {
		AudioClassID c = kAudioObjectClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyOwner: {
		AudioObjectID o = kPAObjectPlugIn;
		return pa_write_u32(size, out, &o, sizeof(o));
	}
	case kAudioObjectPropertyName:
		return pa_write_cf(size, out, pa_cfstr(PA_DEVICE_NAME));
	case kAudioObjectPropertyManufacturer:
		return pa_write_cf(size, out, pa_cfstr(PA_MANUFACTURER));
	case kAudioDevicePropertyDeviceUID:
		return pa_write_cf(size, out, pa_cfstr(PA_UID));
	case kAudioDevicePropertyModelUID:
		return pa_write_cf(size, out, pa_cfstr("PandoraAudioModel"));
	case kAudioDevicePropertyTransportType: {
		UInt32 t = kAudioDeviceTransportTypeBuiltIn;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyClockDomain: {
		UInt32 t = 0;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyDeviceIsAlive: {
		UInt32 t = 1;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyDeviceIsRunning: {
		UInt32 t = g_driver.running ? 1 : 0;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyDeviceCanBeDefaultDevice:
#ifdef kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
	case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
#endif
	{
		UInt32 t = 1;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyLatency: {
		UInt32 t = 0;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertySafetyOffset: {
		UInt32 t = 960;                                    /* 20 ms, what the kernel reads ahead */
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioDevicePropertyStreams: {
		AudioObjectID ids[1] = { kPAObjectStream };         /* only the output scope is asked for */
		return pa_write_u32(size, out, ids, sizeof(ids));
	}
	case kAudioDevicePropertyStreamConfiguration: {
		/* one buffer, two channels: { mNumberBuffers = 1, b[0] = { 2, 8, NULL } } */
		struct {
			UInt32      n;
			AudioBuffer b[1];
		} cfg;
		memset(&cfg, 0, sizeof(cfg));
		cfg.n = 1;
		cfg.b[0].mNumberChannels = PA_CHANNELS;
		cfg.b[0].mDataByteSize = PA_CHANNELS * sizeof(float);
		cfg.b[0].mData = NULL;
		return pa_write_u32(size, out, &cfg, sizeof(cfg));
	}
	case kAudioDevicePropertyNominalSampleRate: {
		Float64 r = PA_RATE;
		return pa_write_u32(size, out, &r, sizeof(r));
	}
	case kAudioDevicePropertyAvailableNominalSampleRates: {
		AudioValueRange r = { PA_RATE, PA_RATE };
		return pa_write_u32(size, out, &r, sizeof(r));
	}
	case kAudioDevicePropertyBufferFrameSize: {
		UInt32 f = g_driver.io_buffer_frames ? g_driver.io_buffer_frames : 512;
		return pa_write_u32(size, out, &f, sizeof(f));
	}
	case kAudioDevicePropertyBufferFrameSizeRange: {
		AudioValueRange r = { 32, 4096 };
		return pa_write_u32(size, out, &r, sizeof(r));
	}
	case kAudioDevicePropertyZeroTimeStampPeriod: {
		UInt32 p = PA_RING_FRAMES;
		return pa_write_u32(size, out, &p, sizeof(p));
	}
	case kAudioDevicePropertyPreferredChannelLayout: {
		/* two channels, left/right */
		struct {
			AudioChannelLayout l;
			AudioChannelDescription d[2];
		} layout;
		memset(&layout, 0, sizeof(layout));
		layout.l.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
		layout.l.mNumberChannelDescriptions = 0;
		return pa_write_u32(size, out, &layout.l, sizeof(layout.l));
	}
	case kAudioObjectPropertyControlList: {
		*size = 0;
		return noErr;
	}
	case kAudioObjectPropertyOwnedObjects: {
		AudioObjectID ids[1] = { kPAObjectStream };
		return pa_write_u32(size, out, ids, sizeof(ids));
	}
	default:
		return kAudioHardwareUnknownPropertyError;
	}
}

static OSStatus
pa_stream_data(UInt32 *size, void *out, const AudioObjectPropertyAddress *a)
{
	static const AudioStreamBasicDescription fmt = {
		.mSampleRate = PA_RATE,
		.mFormatID = kAudioFormatLinearPCM,
		.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
		.mBytesPerPacket = PA_CHANNELS * sizeof(float),
		.mFramesPerPacket = 1,
		.mBytesPerFrame = PA_CHANNELS * sizeof(float),
		.mChannelsPerFrame = PA_CHANNELS,
		.mBitsPerChannel = 32,
	};

	switch (a->mSelector) {
	case kAudioObjectPropertyClass: {
		AudioClassID c = kAudioStreamClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyBaseClass: {
		AudioClassID c = kAudioObjectClassID;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioObjectPropertyOwner: {
		AudioObjectID o = kPAObjectDevice;
		return pa_write_u32(size, out, &o, sizeof(o));
	}
	case kAudioStreamPropertyDirection: {
		UInt32 d = 0;                                      /* output */
		return pa_write_u32(size, out, &d, sizeof(d));
	}
	case kAudioStreamPropertyTerminalType: {
		UInt32 t = kAudioStreamTerminalTypeSpeaker;
		return pa_write_u32(size, out, &t, sizeof(t));
	}
	case kAudioStreamPropertyStartingChannel: {
		UInt32 c = 1;
		return pa_write_u32(size, out, &c, sizeof(c));
	}
	case kAudioStreamPropertyVirtualFormat:
	case kAudioStreamPropertyPhysicalFormat:
		return pa_write_u32(size, out, &fmt, sizeof(fmt));
	case kAudioStreamPropertyAvailableVirtualFormats:
	case kAudioStreamPropertyAvailablePhysicalFormats: {
		AudioStreamRangedDescription r;
		memset(&r, 0, sizeof(r));
		r.mFormat = fmt;
		r.mSampleRateRange.mMinimum = PA_RATE;
		r.mSampleRateRange.mMaximum = PA_RATE;
		return pa_write_u32(size, out, &r, sizeof(r));
	}
	default:
		return kAudioHardwareUnknownPropertyError;
	}
}

static OSStatus
pa_object_data(UInt32 *size, void *out, AudioObjectID id, const AudioObjectPropertyAddress *a)
{
	switch (id) {
	case kPAObjectPlugIn:
		return pa_plugin_data(size, out, a);
	case kPAObjectDevice:
		return pa_device_data(size, out, a);
	case kPAObjectStream:
		return pa_stream_data(size, out, a);
	default:
		return kAudioHardwareBadObjectError;
	}
}

/* ------------------------------------------------------------------ kernel bridge */

static void
pa_kernel_stop(void)
{
	if (g_driver.conn) {
		if (g_driver.running) {
			uint64_t in[2] = { PA_STREAM_ID, 0 };
			if (g_iokit.call_scalar) {
				(void)g_iokit.call_scalar(g_driver.conn, 6, in, 2, NULL, NULL);   /* set stream inactive */
				(void)g_iokit.call_scalar(g_driver.conn, 1, NULL, 0, NULL, NULL); /* engine stop */
			}
			pa_log("IO stopped (%llu frames written)", (unsigned long long)g_driver.frames_written);
		}
		g_iokit.service_close(g_driver.conn);
		g_driver.conn = 0;
	}
	g_driver.running = false;
	g_driver.ring = NULL;
	g_driver.status = NULL;
}

static bool
pa_kernel_start(void)
{
	if (g_driver.conn) {
		return true;
	}
	pa_iokit_load();
	if (!g_iokit.ok) {
		return false;
	}
	CFMutableDictionaryRef match = g_iokit.service_matching("IOAudio2Device");
	if (match == NULL) {
		pa_log("IOServiceMatching failed");
		return false;
	}
	io_iterator_t it = 0;
	if (g_iokit.get_matching(0, match, &it) != KERN_SUCCESS || it == 0) {   /* kIOMasterPortDefault == 0 */
		pa_log("no IOAudio2Device in the registry");
		return false;
	}
	io_service_t svc = 0, found = 0;
	while ((svc = g_iokit.iterator_next(it)) != 0) {
		CFTypeRef uid = g_iokit.registry_prop(svc, CFSTR("device UID"), kCFAllocatorDefault, 0);
		if (uid != NULL && CFGetTypeID(uid) == CFStringGetTypeID() &&
		    CFStringCompare((CFStringRef)uid, CFSTR("Speaker"), 0) == kCFCompareEqualTo) {
			found = svc;
			CFRelease(uid);
			break;
		}
		if (uid) {
			CFRelease(uid);
		}
		g_iokit.object_release(svc);
	}
	g_iokit.object_release(it);
	if (found == 0) {
		pa_log("the Speaker device is not registered (pandora_audio=1?)");
		return false;
	}
	if (g_iokit.service_open(found, mach_task_self(), 0, &g_driver.conn) != KERN_SUCCESS) {
		pa_log("IOServiceOpen refused");
		g_iokit.object_release(found);
		return false;
	}
	g_iokit.object_release(found);

	mach_vm_address_t addr = 0;
	mach_vm_size_t sz = 0;
	if (g_iokit.map_memory64(g_driver.conn, 0, mach_task_self(), &addr, &sz, 0) != KERN_SUCCESS) {
		pa_log("mapping the engine status page failed");
		pa_kernel_stop();
		return false;
	}
	g_driver.status = (volatile int32_t *)addr;
	g_driver.status_size = sz;
	addr = 0;
	sz = 0;
	if (g_iokit.map_memory64(g_driver.conn, (1u << 28) | PA_STREAM_ID, mach_task_self(), &addr, &sz, 0) !=
	    KERN_SUCCESS) {
		pa_log("mapping the IO ring failed");
		pa_kernel_stop();
		return false;
	}
	g_driver.ring = (volatile int32_t *)addr;
	g_driver.ring_size = sz;
	pa_log("device opened: status page %llu B, ring %llu B", (unsigned long long)g_driver.status_size,
	    (unsigned long long)g_driver.ring_size);

	/* method 0 = engine start, then method 6 = set stream active (stream 1, active 1) */
	uint64_t in[2] = { PA_STREAM_ID, 1 };
	if (g_iokit.call_scalar(g_driver.conn, 0, NULL, 0, NULL, NULL) != KERN_SUCCESS) {
		pa_log("engine start refused");
	}
	(void)g_iokit.call_scalar(g_driver.conn, 6, in, 2, NULL, NULL);
	g_driver.running = true;
	g_driver.frames_written = 0;
	return true;
}

/* ------------------------------------------------------------------ interface */

static HRESULT STDMETHODCALLTYPE
pa_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
	(void)inDriver;
	if (outInterface == NULL) {
		return EINVAL;
	}
	/* Two different UUIDs are in play: kAudioServerPlugInTypeUUID is only the CFPlugIn type declared in
	 * Info.plist; QueryInterface must answer kAudioServerPlugInDriverInterfaceUUID (the interface this object
	 * conforms to). Answering the type UUID instead makes the host drop the driver right after the factory. */
	{
		const unsigned char *b = (const unsigned char *)&inUUID;
		pa_log("QueryInterface uuid %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
	}
	CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
	Boolean known = requested != NULL && (CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID) ||
	    CFEqual(requested, kAudioServerPlugInTypeUUID));
	pa_log("QueryInterface: %s -> %s", known ? "known uuid" : "unknown uuid", "S_OK (diagnostic)");
	if (requested != NULL) {
		CFRelease(requested);
	}
	/* Diagnostic round: answer every UUID and hand back the driver reference the host dereferences,
	 * so the log shows whether the crash is about the UUID or about the shape of the reference. */
	{
		AudioServerPlugInDriverInterface **ref = &g_iface_ptr;
		*outInterface = (void *)ref;
	}
	pa_AddRef(NULL);
	return S_OK;
	if (requested != NULL) {
		CFRelease(requested);
	}
	*outInterface = NULL;
	return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE
pa_AddRef(void *inDriver)
{
	(void)inDriver;
	return __sync_add_and_fetch(&g_refs, 1);
}

static ULONG STDMETHODCALLTYPE
pa_Release(void *inDriver)
{
	(void)inDriver;
	return __sync_sub_and_fetch(&g_refs, 1);
}

static OSStatus STDMETHODCALLTYPE
pa_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
	(void)inDriver;
	g_driver.host = inHost;
	g_driver.initialized = true;
	pa_log("plugin initialized (host %p)", (void *)inHost);
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
    const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID)
{
	pa_log("CreateDevice");
	if (outDeviceObjectID == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	*outDeviceObjectID = kPAObjectDevice;
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
	pa_log("DestroyDevice %u", (unsigned)inDeviceObjectID);
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo)
{
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    const AudioServerPlugInClientInfo *inClientInfo)
{
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo)
{
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
    UInt64 inChangeAction, void *inChangeInfo)
{
	return noErr;
}

static Boolean STDMETHODCALLTYPE
pa_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress)
{
	char dummy[512];
	UInt32 size = sizeof(dummy);
	return pa_object_data(&size, dummy, inObjectID, inAddress) == noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
	if (outIsSettable == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	*outIsSettable = false;
	if (inObjectID == kPAObjectDevice &&
	    (inAddress->mSelector == kAudioDevicePropertyBufferFrameSize ||
	        inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)) {
		*outIsSettable = true;
	}
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 *outDataSize)
{
	if (outDataSize == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	static char dummy[4096];
	UInt32 size = sizeof(dummy);
	OSStatus err = pa_object_data(&size, dummy, inObjectID, inAddress);
	pa_log_prop("size", inObjectID, inAddress, err);
	if (err != noErr) {
		return err;
	}
	*outDataSize = size;
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
	if (outDataSize == NULL || outData == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	UInt32 size = inDataSize;
	OSStatus err = pa_object_data(&size, outData, inObjectID, inAddress);
	pa_log_prop("get", inObjectID, inAddress, err);
	if (err == noErr) {
		*outDataSize = size;
	}
	return err;
}

static OSStatus STDMETHODCALLTYPE
pa_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData,
    UInt32 inDataSize, const void *inData)
{
	if (inObjectID == kPAObjectDevice && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize &&
	    inDataSize == sizeof(UInt32)) {
		g_driver.io_buffer_frames = *(const UInt32 *)inData;
		pa_log("buffer frame size set to %u", (unsigned)g_driver.io_buffer_frames);
		return noErr;
	}
	return kAudioHardwareUnknownPropertyError;
}

static OSStatus STDMETHODCALLTYPE
pa_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	pthread_mutex_lock(&g_driver.lock);
	bool ok = pa_kernel_start();
	g_driver.started_host = mach_absolute_time();
	pthread_mutex_unlock(&g_driver.lock);
	pa_log("StartIO client %u -> %s", (unsigned)inClientID, ok ? "running" : "no device");
	return ok ? noErr : kAudioHardwareNotRunningError;
}

static OSStatus STDMETHODCALLTYPE
pa_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
	pthread_mutex_lock(&g_driver.lock);
	pa_kernel_stop();
	pthread_mutex_unlock(&g_driver.lock);
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
	if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	/* Use the kernel's own clock when it is running: the status page carries the sample time and host time of
	 * the last ring wrap the kernel published, which is what the DSP side is following. */
	uint64_t sample = 0, host = g_driver.started_host;
	if (g_driver.status != NULL) {
		sample = ((volatile uint64_t *)g_driver.status)[0];
		host = ((volatile uint64_t *)g_driver.status)[1];
	}
	if (host == 0) {
		host = g_driver.started_host;
	}
	*outSampleTime = (Float64)sample;
	*outHostTime = host;
	*outSeed = 0x50414e44;                            /* 'PAND' */
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
	if (outWillDo == NULL || outWillDoInPlace == NULL) {
		return kAudioHardwareIllegalOperationError;
	}
	*outWillDo = false;
	*outWillDoInPlace = true;
	if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
		*outWillDo = true;
	}
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
    UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer)
{
	if (inOperationID != kAudioServerPlugInIOOperationWriteMix || ioMainBuffer == NULL ||
	    g_driver.ring == NULL) {
		return noErr;
	}
	/* float32 stereo -> s32 stereo into the kernel ring, at the position the output time stamp names. */
	const float *src = (const float *)ioMainBuffer;
	Float64 t = inIOCycleInfo->mOutputTime.mSampleTime;
	int64_t base = (int64_t)floor(t);
	uint32_t pos = (uint32_t)(base % (int64_t)PA_RING_FRAMES);
	if (pos < 0) {
		pos += PA_RING_FRAMES;
	}
	for (UInt32 f = 0; f < inIOBufferFrameSize; f++) {
		for (UInt32 c = 0; c < PA_CHANNELS; c++) {
			float v = src[(size_t)f * PA_CHANNELS + c];
			if (v > 1.0f) {
				v = 1.0f;
			} else if (v < -1.0f) {
				v = -1.0f;
			}
			int32_t s = (int32_t)lrintf(v * 2147483647.0f);
			g_driver.ring[(size_t)((pos + f) % PA_RING_FRAMES) * PA_CHANNELS + c] = s;
		}
	}
	g_driver.frames_written += inIOBufferFrameSize;
	return noErr;
}

static OSStatus STDMETHODCALLTYPE
pa_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
    UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
	return noErr;
}

static AudioServerPlugInDriverInterface g_iface = {
	.QueryInterface = pa_QueryInterface,
	.AddRef = pa_AddRef,
	.Release = pa_Release,
	.Initialize = pa_Initialize,
	.CreateDevice = pa_CreateDevice,
	.DestroyDevice = pa_DestroyDevice,
	.AddDeviceClient = pa_AddDeviceClient,
	.RemoveDeviceClient = pa_RemoveDeviceClient,
	.PerformDeviceConfigurationChange = pa_PerformDeviceConfigurationChange,
	.AbortDeviceConfigurationChange = pa_AbortDeviceConfigurationChange,
	.HasProperty = pa_HasProperty,
	.IsPropertySettable = pa_IsPropertySettable,
	.GetPropertyDataSize = pa_GetPropertyDataSize,
	.GetPropertyData = pa_GetPropertyData,
	.SetPropertyData = pa_SetPropertyData,
	.StartIO = pa_StartIO,
	.StopIO = pa_StopIO,
	.GetZeroTimeStamp = pa_GetZeroTimeStamp,
	.WillDoIOOperation = pa_WillDoIOOperation,
	.BeginIOOperation = pa_BeginIOOperation,
	.DoIOOperation = pa_DoIOOperation,
	.EndIOOperation = pa_EndIOOperation,
};

/* ------------------------------------------------------------------ factory */

__attribute__((visibility("default"))) void *
PandoraAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
	if (inRequestedTypeUUID == NULL || !CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
		return NULL;
	}
	memset(&g_driver, 0, sizeof(g_driver));
	g_driver.iface = &g_iface;
	g_driver.refs = 1;
	g_driver.io_buffer_frames = 512;
	pthread_mutex_init(&g_driver.lock, NULL);
	pa_log("factory: driver created");
	return &g_iface_ptr;                                      /* AudioServerPlugInDriverInterface** */
}
