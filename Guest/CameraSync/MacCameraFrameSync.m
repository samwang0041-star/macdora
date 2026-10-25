#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <unistd.h>

typedef int (*StartCapturingIMP)(id, SEL, const char *, int, int, const char *);
typedef int (*ReadFrameIMP)(id, SEL, void *, float, float, float, float, int);

static StartCapturingIMP gOrigStartCapturing = NULL;
static ReadFrameIMP gOrigReadFrame = NULL;

static Ivar gCaptureDeviceIvar = NULL;
static ptrdiff_t gOffsetFrameUpdated = -1;

static void configureDeviceFrameRate(AVCaptureDevice *device) {
    if (!device || ![device isKindOfClass:[AVCaptureDevice class]]) {
        return;
    }
    AVCaptureDeviceFormat *format = device.activeFormat;
    if (!format) {
        return;
    }
    AVFrameRateRange *selectedRange = nil;
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        if (range.maxFrameRate >= 29.9) {
            selectedRange = range;
            break;
        }
        if (!selectedRange || range.maxFrameRate > selectedRange.maxFrameRate) {
            selectedRange = range;
        }
    }
    if (!selectedRange) {
        return;
    }
    NSError *error = nil;
    if ([device lockForConfiguration:&error]) {
        @try {
            CMTime targetDuration = selectedRange.minFrameDuration;
            if (selectedRange.maxFrameRate >= 29.9 && selectedRange.minFrameRate <= 30.0) {
                targetDuration = CMTimeMake(1, 30);
            }
            device.activeVideoMinFrameDuration = targetDuration;
            device.activeVideoMaxFrameDuration = targetDuration;
        } @catch (__unused NSException *exception) {
        } @finally {
            [device unlockForConfiguration];
        }
    }
}

static int swizzled_startCapturing(id self, SEL _cmd, const char *name, int width, int height, const char *direction) {
    int rc = gOrigStartCapturing(self, _cmd, name, width, height, direction);
    if (rc == 0 && gCaptureDeviceIvar != NULL) {
        id devObj = object_getIvar(self, gCaptureDeviceIvar);
        if ([devObj isKindOfClass:[AVCaptureDevice class]]) {
            configureDeviceFrameRate((AVCaptureDevice *)devObj);
        }
    }
    return rc;
}

static int swizzled_readFrame(
    id self,
    SEL _cmd,
    void *resultFrame,
    float rScale,
    float gScale,
    float bScale,
    float expComp,
    int sensorOrientation
) {
    if (gOffsetFrameUpdated < 0) {
        return gOrigReadFrame(
            self, _cmd, resultFrame, rScale, gScale, bScale, expComp, sensorOrientation);
    }

    uint8_t *raw = (uint8_t *)(__bridge void *)self;
    volatile uint8_t *updatedPtr = (volatile uint8_t *)(raw + gOffsetFrameUpdated);

    if (*updatedPtr == 0) {
        for (int i = 0; i < 12; i++) {
            usleep(1000);
            if (*updatedPtr != 0) {
                break;
            }
        }
    }

    return gOrigReadFrame(self, _cmd, resultFrame, rScale, gScale, bScale, expComp, sensorOrientation);
}

__attribute__((constructor))
static void initMacCameraFrameSync(void) {
    Class cls = objc_getClass("MacCamera");
    if (!cls) {
        return;
    }

    gCaptureDeviceIvar = class_getInstanceVariable(cls, "captureDevice_");

    Ivar updatedIvar = class_getInstanceVariable(cls, "outputFrameUpdated_");
    if (updatedIvar) {
        gOffsetFrameUpdated = ivar_getOffset(updatedIvar);
    }

    Method startMethod = class_getInstanceMethod(cls, @selector(startCapturing:width:height:direction:));
    if (startMethod) {
        gOrigStartCapturing = (StartCapturingIMP)method_setImplementation(
            startMethod,
            (IMP)swizzled_startCapturing
        );
    }

    Method readMethod = class_getInstanceMethod(cls, @selector(readFrame:rScale:gScale:bScale:expComp:sensorOrientation:));
    if (readMethod) {
        gOrigReadFrame = (ReadFrameIMP)method_setImplementation(
            readMethod,
            (IMP)swizzled_readFrame
        );
    }
}
