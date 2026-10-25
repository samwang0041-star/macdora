package local.androiduse.gpuprobe;

import android.app.Activity;
import android.graphics.Color;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLES31;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

/**
 * A self-contained GPU capability probe. It requires a real 3.1 context and
 * proves compute and pixel paths, rather than treating reported versions as a
 * pass.
 */
public final class MainActivity extends Activity {
    private static final String TAG = "AndroidUseGPUProbe";
    private static final int EGL_CONTEXT_MAJOR_VERSION = 0x3098;
    private static final int EGL_CONTEXT_MINOR_VERSION = 0x30FB;
    private static final int EGL_OPENGL_ES3_BIT = 0x00000040;
    private static final int ITEM_COUNT = 256;
    private static final int WORK_GROUP_SIZE = 64;
    private static final int WORK_GROUP_COUNT = 4;
    private static final int PROBE_WIDTH = 4;
    private static final int PROBE_HEIGHT = 4;
    private static final int CLEAR_R = 19;
    private static final int CLEAR_G = 137;
    private static final int CLEAR_B = 211;
    private static final int CLEAR_A = 255;

    private TextView statusView;
    private volatile boolean workerStarted;
    private String runId;
    private boolean includeLargeIndirect;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        runId = getIntent().getStringExtra("run_id");
        if (runId == null || runId.isEmpty()) { runId = UUID.randomUUID().toString(); }
        includeLargeIndirect = getIntent().getBooleanExtra("include_large_indirect", false);
        buildInterface();
        startProbe();
    }

    private void buildInterface() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setBackgroundColor(Color.rgb(248, 246, 241));
        int padding = dp(24);
        root.setPadding(padding, padding, padding, padding);

        TextView title = new TextView(this);
        title.setText("GPU 3.1 probe");
        title.setTextColor(Color.rgb(28, 42, 40));
        title.setTextSize(24);
        title.setGravity(Gravity.CENTER);
        root.addView(title);

        statusView = new TextView(this);
        statusView.setText("正在验证 GPU…");
        statusView.setTextColor(Color.rgb(70, 82, 78));
        statusView.setTextSize(16);
        statusView.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        statusParams.topMargin = dp(18);
        root.addView(statusView, statusParams);
        setContentView(root);
    }

    private void startProbe() {
        if (workerStarted) {
            return;
        }
        workerStarted = true;
        Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                ProbeResult result;
                try {
                    result = runProbe();
                } catch (Throwable throwable) {
                    result = ProbeResult.failure(
                            "unexpected", "uncaught: " + describe(throwable));
                }
                publishResult(result);
            }
        }, "GPUProbe");
        worker.start();
    }

    private ProbeResult runProbe() {
        EGLDisplay display = EGL14.EGL_NO_DISPLAY;
        EGLConfig config = null;
        EGLContext context = EGL14.EGL_NO_CONTEXT;
        EGLSurface surface = EGL14.EGL_NO_SURFACE;
        ProbeResult result = new ProbeResult();
        try {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            if (display == null || display.equals(EGL14.EGL_NO_DISPLAY)) {
                return result.fail("eglGetDisplay", "no default display", eglError());
            }

            int[] version = new int[2];
            if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
                return result.fail("eglInitialize", "eglInitialize returned false", eglError());
            }
            result.eglVersion = integerPair(version[0], version[1]);
            result.eglVendor = safeEglQuery(display, EGL14.EGL_VENDOR);
            result.eglExtensions = safeEglQuery(display, EGL14.EGL_EXTENSIONS);
            if (!EGL14.eglBindAPI(EGL14.EGL_OPENGL_ES_API)) {
                return result.fail(
                        "eglBindAPI", "could not bind OpenGL ES API", eglError());
            }

            int[] configAttributes = {
                    EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_NONE
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] configCount = new int[1];
            if (!EGL14.eglChooseConfig(
                    display, configAttributes, 0, configs, 0, 1, configCount, 0)
                    || configCount[0] < 1) {
                String selectionError = eglError();
                result.eglConfigs = describeConfigs(display);
                return result.fail(
                        "eglChooseConfig",
                        "no EGL config for ES 3.1 / pbuffer / RGBA8",
                        selectionError);
            }
            config = configs[0];
            result.eglConfigId = configId(display, config);

            int[] contextAttributes = {
                    EGL_CONTEXT_MAJOR_VERSION, 3,
                    EGL_CONTEXT_MINOR_VERSION, 1,
                    EGL14.EGL_NONE
            };
            context = EGL14.eglCreateContext(
                    display, config, EGL14.EGL_NO_CONTEXT, contextAttributes, 0);
            if (context == null || context.equals(EGL14.EGL_NO_CONTEXT)) {
                return result.fail(
                        "eglCreateContext",
                        "could not create OpenGL ES 3.1 context",
                        eglError());
            }

            int[] surfaceAttributes = {
                    EGL14.EGL_WIDTH, 16,
                    EGL14.EGL_HEIGHT, 16,
                    EGL14.EGL_NONE
            };
            surface = EGL14.eglCreatePbufferSurface(display, config, surfaceAttributes, 0);
            if (surface == null || surface.equals(EGL14.EGL_NO_SURFACE)) {
                return result.fail(
                        "eglCreatePbufferSurface", "could not create pbuffer", eglError());
            }
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                return result.fail(
                        "eglMakeCurrent", "could not make EGL context current", eglError());
            }

            int[] glMajor = new int[1];
            int[] glMinor = new int[1];
            GLES30.glGetIntegerv(GLES30.GL_MAJOR_VERSION, glMajor, 0);
            GLES30.glGetIntegerv(GLES30.GL_MINOR_VERSION, glMinor, 0);
            result.glMajor = glMajor[0];
            result.glMinor = glMinor[0];
            result.glVersion = safeGlString(GLES20.GL_VERSION);
            result.glslVersion = safeGlString(GLES20.GL_SHADING_LANGUAGE_VERSION);
            result.renderer = safeGlString(GLES20.GL_RENDERER);
            result.vendor = safeGlString(GLES20.GL_VENDOR);

            int glError = drainGlErrors();
            if (glError != GLES20.GL_NO_ERROR) {
                return result.fail(
                        "glVersionQuery",
                        "OpenGL error while querying version",
                        "0x" + Integer.toHexString(glError));
            }
            if (result.glMajor < 3 || (result.glMajor == 3 && result.glMinor < 1)) {
                return result.fail(
                        "glVersion",
                        "context did not provide GLES 3.1; got "
                                + result.glMajor + "." + result.glMinor,
                        null);
            }

            String computeFailure = runComputeProbe(result);
            if (computeFailure != null) {
                return result.fail("compute", computeFailure, glErrorHex());
            }

            String pixelFailure = runPixelProbe();
            if (pixelFailure != null) {
                return result.fail("pixels", pixelFailure, glErrorHex());
            }
            result.raster = RasterProbe.run(includeLargeIndirect);
            if (!result.raster.optBoolean("verified", false)) {
                return result.fail("raster", "flat interpolation or indexed drawing failed", glErrorHex());
            }

            int executionError = drainGlErrors();
            if (executionError != GLES20.GL_NO_ERROR) {
                return result.fail("glExecution", "OpenGL error during execution or cleanup",
                        "0x" + Integer.toHexString(executionError));
            }

            result.passed = true;
            return result;
        } catch (Throwable throwable) {
            return result.fail(
                    result.failureStage == null ? "unexpected" : result.failureStage,
                    "uncaught: " + describe(throwable),
                    glErrorHex());
        } finally {
            EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT);
            if (surface != null && !surface.equals(EGL14.EGL_NO_SURFACE)) {
                EGL14.eglDestroySurface(display, surface);
            }
            if (context != null && !context.equals(EGL14.EGL_NO_CONTEXT)) {
                EGL14.eglDestroyContext(display, context);
            }
            if (display != null && !display.equals(EGL14.EGL_NO_DISPLAY)) {
                EGL14.eglTerminate(display);
            }
            EGL14.eglReleaseThread();
        }
    }

    /**
     * Runs 64 * 4 invocations. Each invocation owns one uint item and computes
     * a value that cannot be supplied by a version string or CPU-side copy.
     */
    private String runComputeProbe(ProbeResult result) {
        int shader = 0;
        int program = 0;
        int[] buffers = new int[1];
        ByteBuffer input = null;
        ByteBuffer mapped = null;
        try {
            String source =
                    "#version 310 es\n"
                            + "layout(local_size_x = 64) in;\n"
                            + "layout(std430, binding = 0) buffer Values {\n"
                            + "  uint values[256];\n"
                            + "} resultBuffer;\n"
                            + "void main() {\n"
                            + "  uint i = gl_GlobalInvocationID.x;\n"
                            + "  resultBuffer.values[i] = (i * 37u + 11u) ^ (i << 3u);\n"
                            + "}\n";
            shader = GLES20.glCreateShader(GLES31.GL_COMPUTE_SHADER);
            if (shader == 0) {
                return "glCreateShader returned 0";
            }
            GLES20.glShaderSource(shader, source);
            GLES20.glCompileShader(shader);
            int[] compileStatus = new int[1];
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compileStatus, 0);
            if (compileStatus[0] == 0) {
                return "compute shader compile failed: "
                        + safeProgramLog(GLES20.glGetShaderInfoLog(shader));
            }

            program = GLES20.glCreateProgram();
            if (program == 0) {
                return "glCreateProgram returned 0";
            }
            GLES20.glAttachShader(program, shader);
            GLES20.glLinkProgram(program);
            int[] linkStatus = new int[1];
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0);
            if (linkStatus[0] == 0) {
                return "compute program link failed: "
                        + safeProgramLog(GLES20.glGetProgramInfoLog(program));
            }
            GLES20.glUseProgram(program);

            GLES20.glGenBuffers(1, buffers, 0);
            if (buffers[0] == 0) {
                return "glGenBuffers returned 0";
            }
            input = ByteBuffer.allocateDirect(ITEM_COUNT * 4)
                    .order(ByteOrder.nativeOrder());
            for (int i = 0; i < ITEM_COUNT; i++) {
                input.putInt(i * 4, 0);
            }
            GLES20.glBindBuffer(GLES31.GL_SHADER_STORAGE_BUFFER, buffers[0]);
            GLES20.glBufferData(
                    GLES31.GL_SHADER_STORAGE_BUFFER,
                    ITEM_COUNT * 4,
                    input,
                    GLES20.GL_DYNAMIC_DRAW);
            GLES31.glBindBufferBase(
                    GLES31.GL_SHADER_STORAGE_BUFFER, 0, buffers[0]);
            GLES31.glDispatchCompute(WORK_GROUP_COUNT, 1, 1);
            GLES31.glMemoryBarrier(
                    GLES31.GL_SHADER_STORAGE_BARRIER_BIT
                            | GLES31.GL_BUFFER_UPDATE_BARRIER_BIT);
            GLES20.glFinish();

            mapped = (ByteBuffer) GLES30.glMapBufferRange(
                    GLES31.GL_SHADER_STORAGE_BUFFER,
                    0,
                    ITEM_COUNT * 4,
                    GLES30.GL_MAP_READ_BIT);
            if (mapped == null) {
                return "glMapBufferRange returned null";
            }
            if (mapped.order() != ByteOrder.nativeOrder()) {
                mapped.order(ByteOrder.nativeOrder());
            }
            int mismatches = 0;
            int firstMismatchIndex = -1;
            int firstExpected = 0;
            int firstActual = 0;
            for (int i = 0; i < ITEM_COUNT; i++) {
                int expected = expectedComputeValue(i);
                int actual = mapped.getInt(i * 4);
                if (actual != expected) {
                    if (mismatches == 0) {
                        firstMismatchIndex = i;
                        firstExpected = expected;
                        firstActual = actual;
                    }
                    mismatches++;
                }
            }
            result.compute = new JSONObject();
            result.compute.put("verified", mismatches == 0);
            result.compute.put("itemCount", ITEM_COUNT);
            result.compute.put("workGroupSize", WORK_GROUP_SIZE);
            result.compute.put("workGroupCount", WORK_GROUP_COUNT);
            result.compute.put("invocations", ITEM_COUNT);
            result.compute.put("mismatchCount", mismatches);
            if (mismatches > 0) {
                result.compute.put("firstMismatchIndex", firstMismatchIndex);
                result.compute.put("firstExpected", firstExpected);
                result.compute.put("firstActual", firstActual);
                return "compute readback mismatch in " + mismatches + " of "
                        + ITEM_COUNT + " items";
            }
            result.compute.put("readback", "glMapBufferRange");
            result.compute.put("formula", "(i * 37 + 11) xor (i << 3), uint32 wrap");
            boolean contentsValid = GLES30.glUnmapBuffer(GLES31.GL_SHADER_STORAGE_BUFFER);
            mapped = null;
            if (!contentsValid) {
                result.compute.put("verified", false);
                return "glUnmapBuffer reported invalid buffer contents";
            }
            return null;
        } catch (Throwable throwable) {
            return "compute exception: " + describe(throwable);
        } finally {
            if (mapped != null) {
                GLES30.glUnmapBuffer(GLES31.GL_SHADER_STORAGE_BUFFER);
            }
            if (buffers[0] != 0) {
                GLES20.glDeleteBuffers(1, buffers, 0);
            }
            if (program != 0) {
                GLES20.glDeleteProgram(program);
            }
            if (shader != 0) {
                GLES20.glDeleteShader(shader);
            }
            GLES20.glUseProgram(0);
        }
    }

    private String runPixelProbe() {
        int[] framebuffers = new int[1];
        int[] textures = new int[1];
        ByteBuffer pixels = null;
        boolean framebufferCreated = false;
        try {
            GLES20.glGenFramebuffers(1, framebuffers, 0);
            GLES20.glGenTextures(1, textures, 0);
            if (framebuffers[0] == 0 || textures[0] == 0) {
                return "could not allocate framebuffer/texture";
            }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[0]);
            GLES20.glTexImage2D(
                    GLES20.GL_TEXTURE_2D,
                    0,
                    GLES30.GL_RGBA8,
                    PROBE_WIDTH,
                    PROBE_HEIGHT,
                    0,
                    GLES20.GL_RGBA,
                    GLES20.GL_UNSIGNED_BYTE,
                    null);
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffers[0]);
            framebufferCreated = true;
            GLES20.glFramebufferTexture2D(
                    GLES20.GL_FRAMEBUFFER,
                    GLES20.GL_COLOR_ATTACHMENT0,
                    GLES20.GL_TEXTURE_2D,
                    textures[0],
                    0);
            int status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER);
            if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
                return "framebuffer incomplete: 0x" + Integer.toHexString(status);
            }
            GLES20.glViewport(0, 0, PROBE_WIDTH, PROBE_HEIGHT);
            GLES20.glClearColor(
                    CLEAR_R / 255.0f,
                    CLEAR_G / 255.0f,
                    CLEAR_B / 255.0f,
                    CLEAR_A / 255.0f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
            GLES20.glFinish();

            pixels = ByteBuffer.allocateDirect(PROBE_WIDTH * PROBE_HEIGHT * 4)
                    .order(ByteOrder.nativeOrder());
            GLES20.glReadPixels(
                    0,
                    0,
                    PROBE_WIDTH,
                    PROBE_HEIGHT,
                    GLES20.GL_RGBA,
                    GLES20.GL_UNSIGNED_BYTE,
                    pixels);
            GLES20.glFinish();
            int mismatches = 0;
            for (int i = 0; i < PROBE_WIDTH * PROBE_HEIGHT; i++) {
                int offset = i * 4;
                if (pixels.get(offset) != (byte) CLEAR_R
                        || pixels.get(offset + 1) != (byte) CLEAR_G
                        || pixels.get(offset + 2) != (byte) CLEAR_B
                        || pixels.get(offset + 3) != (byte) CLEAR_A) {
                    mismatches++;
                }
            }
            if (mismatches != 0) {
                return "glReadPixels mismatch in " + mismatches + " of "
                        + (PROBE_WIDTH * PROBE_HEIGHT) + " pixels";
            }
            return null;
        } catch (Throwable throwable) {
            return "pixel exception: " + describe(throwable);
        } finally {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
            if (framebufferCreated) {
                GLES20.glDeleteFramebuffers(1, framebuffers, 0);
            }
            GLES20.glDeleteTextures(1, textures, 0);
        }
    }

    private void publishResult(ProbeResult result) {
        if (result.passed) {
            result.pixels = new JSONObject();
            try {
                result.pixels.put("verified", true);
                result.pixels.put("width", PROBE_WIDTH);
                result.pixels.put("height", PROBE_HEIGHT);
                result.pixels.put(
                        "rgba",
                        new JSONArray(new int[]{CLEAR_R, CLEAR_G, CLEAR_B, CLEAR_A}));
                result.pixels.put("readback", "glClear + glReadPixels");
            } catch (Exception ignored) {
                result = ProbeResult.failure("pixels", "could not encode pixel result");
            }
        }
        result.finishedAt = System.currentTimeMillis();
        try {
            writeJson(result);
        } catch (Throwable throwable) {
            Log.e(TAG, "Could not write result.json: " + describe(throwable));
            result = ProbeResult.failure("resultFile", "result.json write failed");
            result.finishedAt = System.currentTimeMillis();
        }
        result.logStatus();
        final String label = result.passed
                ? "完成：GPU 3.1 compute 与像素读回均通过"
                : "失败：" + result.failureStage + " · " + result.failureMessage;
        final boolean passed = result.passed;
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                if (statusView != null) {
                    statusView.setText(label);
                    statusView.setTextColor(passed
                            ? Color.rgb(28, 111, 84)
                            : Color.rgb(174, 58, 43));
                }
            }
        });
    }

    private void writeJson(ProbeResult result) throws Exception {
        JSONObject root = new JSONObject();
        root.put("schemaVersion", 1);
        root.put("runId", runId);
        root.put("package", getPackageName());
        root.put("passed", result.passed);
        root.put("startedAt", result.startedAt);
        root.put("finishedAt", result.finishedAt);
        root.put("durationMs", Math.max(0, result.finishedAt - result.startedAt));
        root.put("egl", result.eglJson());
        root.put("gl", result.glJson());
        if (result.compute != null) {
            root.put("compute", result.compute);
        }
        if (result.pixels != null) {
            root.put("pixels", result.pixels);
        }
        if (result.raster != null) { root.put("raster", result.raster); }
        if (result.failureStage != null) {
            JSONObject failure = new JSONObject();
            failure.put("stage", result.failureStage);
            failure.put("message", result.failureMessage);
            if (result.failureDetail != null) {
                failure.put("detail", result.failureDetail);
            }
            root.put("failure", failure);
        }
        File target = new File(getFilesDir(), "result.json");
        File temporary = new File(getFilesDir(), "result.json.tmp");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(root.toString(2).getBytes(StandardCharsets.UTF_8));
            output.write('\n');
            output.getFD().sync();
        }
        if (!temporary.renameTo(target)) {
            if (target.exists() && !target.delete()) {
                throw new IOException("could not replace existing result.json");
            }
            if (!temporary.renameTo(target)) {
                throw new IOException("could not rename result.json.tmp");
            }
        }
    }

    private static int expectedComputeValue(int i) {
        return (i * 37 + 11) ^ (i << 3);
    }

    private static JSONArray describeConfigs(EGLDisplay display) throws Exception {
        int[] count = new int[1];
        JSONArray description = new JSONArray();
        if (!EGL14.eglGetConfigs(display, null, 0, 0, count, 0)) {
            description.put(new JSONObject().put("diagnosticError", "eglGetConfigs count").put("eglError", eglError()));
            return description;
        }
        EGLConfig[] configs = new EGLConfig[count[0]];
        if (!EGL14.eglGetConfigs(display, configs, 0, configs.length, count, 0)) {
            description.put(new JSONObject().put("diagnosticError", "eglGetConfigs list").put("eglError", eglError()));
            return description;
        }
        int[] attributes = {EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_RED_SIZE, EGL14.EGL_GREEN_SIZE, EGL14.EGL_BLUE_SIZE, EGL14.EGL_ALPHA_SIZE};
        String[] names = {"renderableBits", "surfaceBits", "red", "green", "blue", "alpha"};
        for (int i = 0; i < count[0]; i++) {
            JSONObject item = new JSONObject();
            for (int j = 0; j < attributes.length; j++) {
                int[] value = new int[1];
                if (EGL14.eglGetConfigAttrib(display, configs[i], attributes[j], value, 0)) {
                    item.put(names[j], value[0]);
                } else {
                    item.put(names[j] + "Error", eglError());
                }
            }
            description.put(item);
        }
        return description;
    }

    private static String describe(Throwable throwable) {
        String message = throwable.getMessage();
        return throwable.getClass().getSimpleName()
                + (message == null || message.isEmpty() ? "" : ": " + message);
    }

    private static String integerPair(int first, int second) {
        return first + "." + second;
    }

    private static String configId(EGLDisplay display, EGLConfig config) {
        int[] value = new int[1];
        if (!EGL14.eglGetConfigAttrib(
                display, config, EGL14.EGL_CONFIG_ID, value, 0)) {
            return null;
        }
        return Integer.toString(value[0]);
    }

    private static String safeEglQuery(EGLDisplay display, int name) {
        try {
            return EGL14.eglQueryString(display, name);
        } catch (Throwable throwable) {
            return null;
        }
    }

    private static String safeGlString(int name) {
        try {
            return GLES20.glGetString(name);
        } catch (Throwable throwable) {
            return null;
        }
    }

    private static String safeProgramLog(String log) {
        return log == null ? "(no log)" : log;
    }

    private static int drainGlErrors() {
        int error = GLES20.GL_NO_ERROR;
        for (int i = 0; i < 16; i++) {
            int next = GLES20.glGetError();
            if (next == GLES20.GL_NO_ERROR) {
                break;
            }
            error = next;
        }
        return error;
    }

    private static String glErrorHex() {
        int error = GLES20.glGetError();
        return error == GLES20.GL_NO_ERROR
                ? null
                : "0x" + Integer.toHexString(error);
    }

    private static String eglError() {
        int error = EGL14.eglGetError();
        return error == EGL14.EGL_SUCCESS
                ? null
                : "0x" + Integer.toHexString(error);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private static final class ProbeResult {
        final long startedAt = System.currentTimeMillis();
        long finishedAt;
        boolean passed;
        String eglVersion;
        String eglVendor;
        String eglExtensions;
        String eglConfigId;
        JSONArray eglConfigs;
        int glMajor = -1;
        int glMinor = -1;
        String glVersion;
        String glslVersion;
        String renderer;
        String vendor;
        JSONObject compute;
        JSONObject pixels;
        JSONObject raster;
        String failureStage;
        String failureMessage;
        String failureDetail;

        ProbeResult fail(String stage, String message, String detail) {
            if (failureStage == null) {
                failureStage = stage;
                failureMessage = message;
                failureDetail = detail;
            }
            passed = false;
            return this;
        }

        static ProbeResult failure(String stage, String message) {
            ProbeResult result = new ProbeResult();
            return result.fail(stage, message, null);
        }

        JSONObject eglJson() throws Exception {
            JSONObject egl = new JSONObject();
            egl.put("version", jsonValue(eglVersion));
            egl.put("vendor", jsonValue(eglVendor));
            egl.put("configId", jsonValue(eglConfigId));
            if (eglConfigs != null) { egl.put("availableConfigs", eglConfigs); }
            egl.put("requestedContext", "3.1");
            egl.put("requestedSurface", "pbuffer 16x16");
            egl.put("extensions", jsonValue(eglExtensions));
            return egl;
        }

        JSONObject glJson() throws Exception {
            JSONObject gl = new JSONObject();
            gl.put("major", glMajor);
            gl.put("minor", glMinor);
            gl.put("version", jsonValue(glVersion));
            gl.put("shadingLanguageVersion", jsonValue(glslVersion));
            gl.put("renderer", jsonValue(renderer));
            gl.put("vendor", jsonValue(vendor));
            return gl;
        }

        void logStatus() {
            if (passed) {
                Log.i(TAG, "PASS GLES " + glMajor + "." + glMinor
                        + " renderer=" + renderer
                        + " compute=256/256 pixels=16/16");
            } else {
                Log.e(TAG, "FAIL stage=" + failureStage
                        + " reason=" + failureMessage
                        + " detail=" + failureDetail);
            }
        }

        private static Object jsonValue(String value) {
            return value == null ? JSONObject.NULL : value;
        }
    }
}
