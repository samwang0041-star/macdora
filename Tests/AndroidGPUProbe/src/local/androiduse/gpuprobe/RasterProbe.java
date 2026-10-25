package local.androiduse.gpuprobe;

import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLES31;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Executes the GLES 3.1 raster paths needed to verify last-vertex flat
 * interpolation with real pixels. The caller owns the EGL context.
 */
public final class RasterProbe {
    private static final int WIDTH = 16;
    private static final int HEIGHT = 16;
    private static final int INDEX_PREFIX_BYTES = 8;
    private static final int LARGE_INDIRECT_VERTEX_COUNT = 131076;
    private static final int LARGE_INDIRECT_INITIAL_CPU_COUNT = 3;
    private static final int LARGE_INDIRECT_EXPECTED_RED =
            (LARGE_INDIRECT_VERTEX_COUNT - 1) & 0xff;
    private static final String INDIRECT_COMPUTE_SOURCE =
            "#version 310 es\n"
                    + "layout(local_size_x = 1) in;\n"
                    + "layout(std430, binding = 0) buffer IndirectArgs {\n"
                    + "  uint count;\n"
                    + "  uint instanceCount;\n"
                    + "  uint first;\n"
                    + "  uint baseInstance;\n"
                    + "} args;\n"
                    + "void main() {\n"
                    + "  args.count = " + LARGE_INDIRECT_VERTEX_COUNT + "u;\n"
                    + "  args.instanceCount = 1u;\n"
                    + "  args.first = 0u;\n"
                    + "  args.baseInstance = 0u;\n"
                    + "}\n";
    private static final int[] CAPABILITIES = {
            GLES20.GL_BLEND,
            GLES20.GL_CULL_FACE,
            GLES20.GL_DEPTH_TEST,
            GLES20.GL_SCISSOR_TEST,
            GLES20.GL_STENCIL_TEST,
            GLES20.GL_DITHER,
            GLES30.GL_RASTERIZER_DISCARD,
            GLES20.GL_SAMPLE_ALPHA_TO_COVERAGE,
            GLES20.GL_SAMPLE_COVERAGE
    };
    private static final int[][] SAMPLE_POINTS = {
            {8, 8},
            {1, 1},
            {14, 1},
            {1, 14}
    };

    private static final String VERTEX_SOURCE =
            "#version 300 es\n"
                    + "layout(location = 0) in vec2 aPosition;\n"
                    + "flat out highp uint vVertexID;\n"
                    + "void main() {\n"
                    + "  gl_Position = vec4(aPosition, 0.0, 1.0);\n"
                    + "  vVertexID = uint(gl_VertexID);\n"
                    + "}\n";
    private static final String FRAGMENT_SOURCE =
            "#version 300 es\n"
                    + "precision highp float;\n"
                    + "flat in highp uint vVertexID;\n"
                    + "layout(location = 0) out vec4 fragColor;\n"
                    + "void main() {\n"
                    + "  fragColor = vec4(float(vVertexID & 255u) / 255.0, "
                    + "0.0, 0.0, 1.0);\n"
                    + "}\n";

    private RasterProbe() {
    }

    /**
     * Runs against the caller's current GLES 3.1 context and returns structured
     * evidence. A false result always has a case-level or top-level message.
     */
    public static JSONObject run() throws Exception {
        return run(false);
    }

    public static JSONObject run(boolean includeLargeIndirect) throws Exception {
        JSONObject root = new JSONObject();
        JSONArray cases = new JSONArray();
        root.put("verified", false);
        root.put("includeLargeIndirect", includeLargeIndirect);
        root.put("cases", cases);

        final ProbeResources resources = new ProbeResources();
        final GlState state = new GlState();
        try {
            state.capture();
            requireNoGlError("GL state capture");

            prepareState();
            requireNoGlError("GL state preparation");

            createGeometry(resources);
            createFramebuffer(resources);
            createProgram(resources);
            requireNoGlError("raster setup");

            cases.put(runArraysCase(
                    resources, "glDrawArrays TRIANGLES last-vertex",
                    GLES20.GL_TRIANGLES, 2));
            cases.put(runArraysCase(
                    resources, "glDrawArrays TRIANGLE_STRIP last-vertex",
                    GLES20.GL_TRIANGLE_STRIP, 2));
            cases.put(runArraysCase(
                    resources, "glDrawArrays TRIANGLE_FAN last-vertex",
                    GLES20.GL_TRIANGLE_FAN, 2));

            cases.put(runIndexedCase(
                    resources, "glDrawElements TRIANGLES uint8 nonzero-offset",
                    GLES20.GL_UNSIGNED_BYTE));
            cases.put(runIndexedCase(
                    resources, "glDrawElements TRIANGLES uint16 nonzero-offset",
                    GLES20.GL_UNSIGNED_SHORT));
            cases.put(runIndexedCase(
                    resources, "glDrawElements TRIANGLES uint32 nonzero-offset",
                    GLES20.GL_UNSIGNED_INT));

            cases.put(runPrimitiveRestartCase(resources));
            cases.put(runArraysIndirectCase(resources));
            cases.put(runElementsIndirectCase(resources));
            if (includeLargeIndirect) {
                cases.put(runLargeGpuArraysIndirectCase(resources));
            }

            boolean allVerified = cases.length() > 0;
            for (int i = 0; i < cases.length(); i++) {
                if (!cases.getJSONObject(i).optBoolean("verified", false)) {
                    allVerified = false;
                    break;
                }
            }
            root.put("verified", allVerified);
            if (!allVerified) {
                root.put("message", "one or more raster cases failed");
            }
        } catch (ShaderFailure failure) {
            root.put("message", failure.getMessage());
            JSONObject shaderError = new JSONObject();
            shaderError.put("stage", failure.stage);
            shaderError.put("log", failure.log);
            shaderError.put(
                    "glError",
                    failure.errorCode == GLES20.GL_NO_ERROR
                            ? JSONObject.NULL
                            : hex(failure.errorCode));
            root.put("shaderError", shaderError);
        } catch (GlFailure failure) {
            root.put("message", failure.getMessage());
            root.put("glError", failure.error.toJson());
        } catch (ProbeFailure failure) {
            root.put("message", failure.getMessage());
        } catch (Exception failure) {
            root.put("message", "unexpected raster exception: " + describe(failure));
        } finally {
            String cleanupError = cleanup(resources, state);
            if (cleanupError != null) {
                String previous = root.has("message") ? root.getString("message") : null;
                root.put(
                        "message",
                        previous == null ? cleanupError : previous + "; " + cleanupError);
                JSONObject cleanupJson = new JSONObject();
                cleanupJson.put("message", cleanupError);
                root.put("cleanupError", cleanupJson);
                root.put("verified", false);
            }
        }
        return root;
    }

    private static void prepareState() {
        for (int capability : CAPABILITIES) {
            GLES20.glDisable(capability);
        }
        GLES30.glDisable(GLES30.GL_PRIMITIVE_RESTART_FIXED_INDEX);
        GLES20.glColorMask(true, true, true, true);
        GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        GLES20.glViewport(0, 0, WIDTH, HEIGHT);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0);
        GLES20.glPixelStorei(GLES20.GL_PACK_ALIGNMENT, 1);
        GLES20.glPixelStorei(GLES30.GL_PACK_ROW_LENGTH, 0);
        GLES20.glPixelStorei(GLES30.GL_PACK_SKIP_ROWS, 0);
        GLES20.glPixelStorei(GLES30.GL_PACK_SKIP_PIXELS, 0);
    }

    private static void createGeometry(ProbeResources resources) throws ProbeFailure {
        int[] buffers = new int[3];
        GLES20.glGenBuffers(3, buffers, 0);
        resources.vbo = buffers[0];
        resources.ebo = buffers[1];
        resources.indirectBuffer = buffers[2];
        if (resources.vbo == 0
                || resources.ebo == 0
                || resources.indirectBuffer == 0) {
            throw new ProbeFailure("geometry", "glGenBuffers returned zero");
        }

        float[] positions = {
                -1.0f, -1.0f,
                3.0f, -1.0f,
                -1.0f, 3.0f,
                -1.0f, -1.0f,
                3.0f, -1.0f,
                -1.0f, 3.0f
        };
        ByteBuffer positionBytes = directBuffer(positions.length * 4);
        for (float position : positions) {
            positionBytes.putFloat(position);
        }
        positionBytes.flip();

        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, resources.vbo);
        GLES20.glBufferData(
                GLES20.GL_ARRAY_BUFFER,
                positionBytes.capacity(),
                positionBytes,
                GLES20.GL_STATIC_DRAW);

        int[] vertexArrays = new int[1];
        GLES30.glGenVertexArrays(1, vertexArrays, 0);
        resources.vao = vertexArrays[0];
        if (resources.vao == 0) {
            throw new ProbeFailure("geometry", "glGenVertexArrays returned zero");
        }
        GLES30.glBindVertexArray(resources.vao);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, resources.vbo);
        GLES20.glEnableVertexAttribArray(0);
        GLES20.glVertexAttribPointer(
                0, 2, GLES20.GL_FLOAT, false, 2 * 4, 0);
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, resources.ebo);
    }

    private static void createFramebuffer(ProbeResources resources) throws ProbeFailure {
        int[] textures = new int[1];
        int[] framebuffers = new int[1];
        GLES20.glGenTextures(1, textures, 0);
        GLES20.glGenFramebuffers(1, framebuffers, 0);
        resources.texture = textures[0];
        resources.framebuffer = framebuffers[0];
        if (resources.texture == 0 || resources.framebuffer == 0) {
            throw new ProbeFailure(
                    "framebuffer", "could not allocate RGBA8 texture or framebuffer");
        }

        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, resources.texture);
        GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_NEAREST);
        GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_NEAREST);
        GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D,
                0,
                GLES30.GL_RGBA8,
                WIDTH,
                HEIGHT,
                0,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                null);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, resources.framebuffer);
        GLES20.glFramebufferTexture2D(
                GLES20.GL_FRAMEBUFFER,
                GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D,
                resources.texture,
                0);
        int status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER);
        if (status != GLES20.GL_FRAMEBUFFER_COMPLETE) {
            throw new ProbeFailure(
                    "framebuffer",
                    "framebuffer incomplete: " + hex(status));
        }
    }

    private static void createProgram(ProbeResources resources)
            throws ShaderFailure, ProbeFailure, GlFailure {
        resources.vertexShader = GLES20.glCreateShader(GLES20.GL_VERTEX_SHADER);
        compileShader(
                resources.vertexShader,
                VERTEX_SOURCE,
                "vertex shader compile");

        resources.fragmentShader = GLES20.glCreateShader(GLES20.GL_FRAGMENT_SHADER);
        compileShader(
                resources.fragmentShader,
                FRAGMENT_SOURCE,
                "fragment shader compile");

        resources.program = GLES20.glCreateProgram();
        if (resources.program == 0) {
            GlError error = readGlErrors();
            throw new ShaderFailure(
                    "program create",
                    "glCreateProgram returned zero",
                    error == null ? GLES20.GL_NO_ERROR : error.code);
        }
        GLES20.glAttachShader(resources.program, resources.vertexShader);
        GLES20.glAttachShader(resources.program, resources.fragmentShader);
        GLES20.glBindAttribLocation(resources.program, 0, "aPosition");
        GLES20.glLinkProgram(resources.program);

        int[] linkStatus = new int[1];
        GLES20.glGetProgramiv(
                resources.program, GLES20.GL_LINK_STATUS, linkStatus, 0);
        String log = safeLog(GLES20.glGetProgramInfoLog(resources.program));
        GlError error = readGlErrors();
        if (linkStatus[0] == 0 || error != null) {
            throw new ShaderFailure(
                    "program link",
                    linkStatus[0] == 0
                            ? "program link failed: " + log
                            : "GL error during program link: " + log,
                    error == null ? GLES20.GL_NO_ERROR : error.code);
        }

        int location = GLES20.glGetAttribLocation(resources.program, "aPosition");
        error = readGlErrors();
        if (error != null) {
            throw new GlFailure("attribute location query", error);
        }
        if (location != 0) {
            throw new ProbeFailure(
                    "program", "aPosition location is " + location + ", expected 0");
        }
        GLES20.glUseProgram(resources.program);
    }

    private static void compileShader(int shader, String source, String stage)
            throws ShaderFailure {
        if (shader == 0) {
            GlError error = readGlErrors();
            throw new ShaderFailure(
                    stage,
                    "glCreateShader returned zero",
                    error == null ? GLES20.GL_NO_ERROR : error.code);
        }
        GLES20.glShaderSource(shader, source);
        GLES20.glCompileShader(shader);
        int[] compileStatus = new int[1];
        GLES20.glGetShaderiv(
                shader, GLES20.GL_COMPILE_STATUS, compileStatus, 0);
        String log = safeLog(GLES20.glGetShaderInfoLog(shader));
        GlError error = readGlErrors();
        if (compileStatus[0] == 0 || error != null) {
            throw new ShaderFailure(
                    stage,
                    compileStatus[0] == 0
                            ? "shader compile failed: " + log
                            : "GL error during shader compile: " + log,
                    error == null ? GLES20.GL_NO_ERROR : error.code);
        }
    }

    private static JSONObject runArraysCase(
            final ProbeResources resources,
            String name,
            final int mode,
            final int expectedVertexID) throws Exception {
        return executeCase(
                resources,
                name,
                expectedVertexID,
                new DrawCall() {
                    @Override
                    public void run() {
                        GLES20.glDrawArrays(mode, 0, 3);
                    }
                });
    }

    private static JSONObject runIndexedCase(
            final ProbeResources resources,
            String name,
            final int indexType) throws Exception {
        return executeCase(
                resources,
                name,
                2,
                new DrawCall() {
                    @Override
                    public void run() {
                        uploadIndices(
                                resources,
                                indexType,
                                new int[]{0, 1, 2},
                                INDEX_PREFIX_BYTES);
                        GLES20.glDrawElements(
                                GLES20.GL_TRIANGLES,
                                3,
                                indexType,
                                INDEX_PREFIX_BYTES);
                    }
                });
    }

    private static JSONObject runPrimitiveRestartCase(
            final ProbeResources resources) throws Exception {
        return executeCase(
                resources,
                "glDrawElements TRIANGLE_STRIP uint8 primitive-restart second-segment",
                5,
                new DrawCall() {
                    @Override
                    public void run() {
                        uploadIndices(
                                resources,
                                GLES20.GL_UNSIGNED_BYTE,
                                new int[]{0, 1, 2, 0xff, 3, 4, 5},
                                0);
                        GLES30.glEnable(GLES30.GL_PRIMITIVE_RESTART_FIXED_INDEX);
                        try {
                            GLES20.glDrawElements(
                                    GLES20.GL_TRIANGLE_STRIP,
                                    7,
                                    GLES20.GL_UNSIGNED_BYTE,
                                    0);
                        } finally {
                            GLES30.glDisable(GLES30.GL_PRIMITIVE_RESTART_FIXED_INDEX);
                        }
                    }
                });
    }

    private static JSONObject runArraysIndirectCase(
            final ProbeResources resources) throws Exception {
        return executeCase(
                resources,
                "glDrawArraysIndirect TRIANGLES",
                2,
                new DrawCall() {
                    @Override
                    public void run() {
                        uploadIndirect(
                                resources, new int[]{3, 1, 0, 0});
                        GLES31.glDrawArraysIndirect(GLES20.GL_TRIANGLES, 0L);
                    }
                });
    }

    private static JSONObject runElementsIndirectCase(
            final ProbeResources resources) throws Exception {
        return executeCase(
                resources,
                "glDrawElementsIndirect TRIANGLES uint16",
                2,
                new DrawCall() {
                    @Override
                    public void run() {
                        uploadIndices(
                                resources,
                                GLES20.GL_UNSIGNED_SHORT,
                                new int[]{0, 1, 2},
                                0);
                        uploadIndirect(
                                resources, new int[]{3, 1, 0, 0, 0});
                        GLES31.glDrawElementsIndirect(
                                GLES20.GL_TRIANGLES,
                                GLES20.GL_UNSIGNED_SHORT,
                                0L);
                    }
                });
    }

    private static JSONObject runLargeGpuArraysIndirectCase(
            final ProbeResources resources) throws Exception {
        final int[] tempBuffers = new int[2];
        final int[] tempVaos = new int[1];
        int computeShader = 0;
        int computeProgram = 0;
        try {
            GLES20.glGenBuffers(2, tempBuffers, 0);
            GLES30.glGenVertexArrays(1, tempVaos, 0);
            final int largeVbo = tempBuffers[0];
            final int largeIndirect = tempBuffers[1];
            final int largeVao = tempVaos[0];
            if (largeVbo == 0 || largeIndirect == 0 || largeVao == 0) {
                throw new ProbeFailure(
                        "largeIndirect", "could not allocate large VBO/VAO/indirect buffer");
            }

            ByteBuffer largePositions = directBuffer(LARGE_INDIRECT_VERTEX_COUNT * 2 * 4);
            for (int v = 0; v < LARGE_INDIRECT_VERTEX_COUNT; v += 3) {
                largePositions.putFloat(-1.0f).putFloat(-1.0f);
                largePositions.putFloat(3.0f).putFloat(-1.0f);
                largePositions.putFloat(-1.0f).putFloat(3.0f);
            }
            largePositions.flip();
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, largeVbo);
            GLES20.glBufferData(
                    GLES20.GL_ARRAY_BUFFER,
                    largePositions.capacity(),
                    largePositions,
                    GLES20.GL_STATIC_DRAW);

            GLES30.glBindVertexArray(largeVao);
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, largeVbo);
            GLES20.glEnableVertexAttribArray(0);
            GLES20.glVertexAttribPointer(0, 2, GLES20.GL_FLOAT, false, 2 * 4, 0);

            ByteBuffer initialIndirect = directBuffer(4 * 4);
            initialIndirect.putInt(LARGE_INDIRECT_INITIAL_CPU_COUNT);
            initialIndirect.putInt(1);
            initialIndirect.putInt(0);
            initialIndirect.putInt(0);
            initialIndirect.flip();
            GLES20.glBindBuffer(GLES31.GL_DRAW_INDIRECT_BUFFER, largeIndirect);
            GLES20.glBufferData(
                    GLES31.GL_DRAW_INDIRECT_BUFFER,
                    initialIndirect.capacity(),
                    initialIndirect,
                    GLES30.GL_DYNAMIC_COPY);

            computeShader = GLES20.glCreateShader(GLES31.GL_COMPUTE_SHADER);
            compileShader(
                    computeShader,
                    INDIRECT_COMPUTE_SOURCE,
                    "large indirect compute shader compile");
            computeProgram = GLES20.glCreateProgram();
            if (computeProgram == 0) {
                throw new ProbeFailure(
                        "largeIndirect", "glCreateProgram returned zero for compute");
            }
            GLES20.glAttachShader(computeProgram, computeShader);
            GLES20.glLinkProgram(computeProgram);
            int[] linked = new int[1];
            GLES20.glGetProgramiv(computeProgram, GLES20.GL_LINK_STATUS, linked, 0);
            if (linked[0] == 0) {
                String log = GLES20.glGetProgramInfoLog(computeProgram);
                GlError error = readGlErrors();
                throw new ShaderFailure(
                        "large indirect compute program link",
                        safeLog(log),
                        error == null ? GLES20.GL_NO_ERROR : error.code);
            }
            requireNoGlError("large indirect setup");

            final int finalComputeProgram = computeProgram;
            JSONObject caseResult = executeCase(
                    resources,
                    "glDrawArraysIndirect TRIANGLES 131076 gpu-args",
                    LARGE_INDIRECT_EXPECTED_RED,
                    new DrawCall() {
                        @Override
                        public void run() {
                            GLES20.glUseProgram(finalComputeProgram);
                            GLES30.glBindBufferBase(
                                    GLES31.GL_SHADER_STORAGE_BUFFER, 0, largeIndirect);
                            GLES31.glDispatchCompute(1, 1, 1);
                            GLES31.glMemoryBarrier(
                                    GLES31.GL_COMMAND_BARRIER_BIT
                                            | GLES31.GL_SHADER_STORAGE_BARRIER_BIT);
                            GLES30.glBindBufferBase(
                                    GLES31.GL_SHADER_STORAGE_BUFFER, 0, 0);

                            GLES20.glUseProgram(resources.program);
                            GLES30.glBindVertexArray(largeVao);
                            GLES20.glBindBuffer(
                                    GLES31.GL_DRAW_INDIRECT_BUFFER, largeIndirect);
                            GLES31.glDrawArraysIndirect(GLES20.GL_TRIANGLES, 0L);
                        }
                    });
            caseResult.put("vertexCount", LARGE_INDIRECT_VERTEX_COUNT);
            caseResult.put("initialCpuVertexCount", LARGE_INDIRECT_INITIAL_CPU_COUNT);
            caseResult.put("gpuWrittenArgs", true);
            return caseResult;
        } finally {
            GLES30.glBindBufferBase(GLES31.GL_SHADER_STORAGE_BUFFER, 0, 0);
            GLES20.glBindBuffer(GLES31.GL_SHADER_STORAGE_BUFFER, 0);
            GLES30.glBindVertexArray(resources.vao);
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, resources.vbo);
            GLES20.glBindBuffer(GLES31.GL_DRAW_INDIRECT_BUFFER, resources.indirectBuffer);
            GLES20.glUseProgram(resources.program);
            if (computeProgram != 0) {
                GLES20.glDeleteProgram(computeProgram);
            }
            if (computeShader != 0) {
                GLES20.glDeleteShader(computeShader);
            }
            if (tempVaos[0] != 0) {
                GLES30.glDeleteVertexArrays(1, tempVaos, 0);
            }
            if (tempBuffers[0] != 0) {
                GLES20.glDeleteBuffers(1, new int[]{tempBuffers[0]}, 0);
            }
            if (tempBuffers[1] != 0) {
                GLES20.glDeleteBuffers(1, new int[]{tempBuffers[1]}, 0);
            }
        }
    }

    private static JSONObject executeCase(
            ProbeResources resources,
            String name,
            int expectedVertexID,
            DrawCall drawCall) throws Exception {
        JSONObject result = new JSONObject();
        result.put("name", name);
        result.put("verified", false);
        result.put("expectedRGBA", rgba(expectedVertexID, 0, 0, 255));

        int[] center = {0, 0, 0, 0};
        result.put("actualRGBA", rgba(center));
        try {
            GLES30.glBindVertexArray(resources.vao);
            GLES20.glUseProgram(resources.program);
            GLES20.glViewport(0, 0, WIDTH, HEIGHT);
            GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);

            drawCall.run();
            GLES20.glFinish();
            GlError error = readGlErrors();
            if (error != null) {
                throw new GlFailure("draw/finish", error);
            }

            String mismatch = null;
            ByteBuffer pixel = directBuffer(4);
            for (int i = 0; i < SAMPLE_POINTS.length; i++) {
                int x = SAMPLE_POINTS[i][0];
                int y = SAMPLE_POINTS[i][1];
                int[] actual = readPixel(pixel, x, y);
                if (i == 0) {
                    center = actual;
                    result.put("actualRGBA", rgba(center));
                }
                if (!matches(actual, expectedVertexID, 0, 0, 255) && mismatch == null) {
                    mismatch = "pixel (" + x + "," + y + ") expected "
                            + rgbaText(expectedVertexID, 0, 0, 255)
                            + ", got " + rgbaText(actual);
                }
            }
            if (mismatch != null) {
                result.put("message", mismatch);
            } else {
                result.put("verified", true);
            }
        } catch (GlFailure failure) {
            result.put("message", failure.getMessage());
        }
        return result;
    }

    private static int[] readPixel(ByteBuffer pixel, int x, int y) throws GlFailure {
        GLES20.glReadPixels(
                x,
                y,
                1,
                1,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                pixel);
        GlError error = readGlErrors();
        if (error != null) {
            throw new GlFailure(
                    "glReadPixels (" + x + "," + y + ")", error);
        }
        return new int[]{
                pixel.get(0) & 0xff,
                pixel.get(1) & 0xff,
                pixel.get(2) & 0xff,
                pixel.get(3) & 0xff
        };
    }

    private static void uploadIndices(
            ProbeResources resources,
            int type,
            int[] indices,
            int prefixBytes) {
        int indexSize;
        if (type == GLES20.GL_UNSIGNED_BYTE) {
            indexSize = 1;
        } else if (type == GLES20.GL_UNSIGNED_SHORT) {
            indexSize = 2;
        } else if (type == GLES20.GL_UNSIGNED_INT) {
            indexSize = 4;
        } else {
            throw new IllegalArgumentException("unsupported index type");
        }

        ByteBuffer data = directBuffer(prefixBytes + indices.length * indexSize);
        for (int i = 0; i < prefixBytes; i++) {
            data.put(i, (byte) 0xa5);
        }
        int offset = prefixBytes;
        for (int value : indices) {
            if (indexSize == 1) {
                data.put(offset, (byte) (value & 0xff));
            } else if (indexSize == 2) {
                data.putShort(offset, (short) (value & 0xffff));
            } else {
                data.putInt(offset, value);
            }
            offset += indexSize;
        }

        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, resources.ebo);
        GLES20.glBufferData(
                GLES20.GL_ELEMENT_ARRAY_BUFFER,
                data.capacity(),
                data,
                GLES20.GL_STATIC_DRAW);
    }

    private static void uploadIndirect(ProbeResources resources, int[] values) {
        ByteBuffer data = directBuffer(values.length * 4);
        for (int value : values) {
            data.putInt(value);
        }
        data.flip();
        GLES20.glBindBuffer(GLES31.GL_DRAW_INDIRECT_BUFFER, resources.indirectBuffer);
        GLES20.glBufferData(
                GLES31.GL_DRAW_INDIRECT_BUFFER,
                data.capacity(),
                data,
                GLES20.GL_STATIC_DRAW);
    }

    private static ByteBuffer directBuffer(int bytes) {
        return ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder());
    }

    private static boolean matches(
            int[] actual,
            int red,
            int green,
            int blue,
            int alpha) {
        return actual.length == 4
                && actual[0] == red
                && actual[1] == green
                && actual[2] == blue
                && actual[3] == alpha;
    }

    private static JSONArray rgba(int... values) {
        JSONArray array = new JSONArray();
        for (int value : values) {
            array.put(value);
        }
        return array;
    }

    private static String rgbaText(int... values) {
        return "[" + values[0] + ", " + values[1] + ", "
                + values[2] + ", " + values[3] + "]";
    }

    private static String cleanup(ProbeResources resources, GlState state) {
        if (resources.vao != 0) {
            GLES30.glBindVertexArray(resources.vao);
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0);
        }
        GLES30.glBindVertexArray(0);
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0);
        GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, 0);
        GLES20.glBindBuffer(GLES31.GL_DRAW_INDIRECT_BUFFER, 0);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
        GLES20.glUseProgram(0);

        if (resources.framebuffer != 0) {
            int[] framebuffer = {resources.framebuffer};
            GLES20.glDeleteFramebuffers(1, framebuffer, 0);
        }
        if (resources.texture != 0) {
            int[] texture = {resources.texture};
            GLES20.glDeleteTextures(1, texture, 0);
        }
        if (resources.program != 0) {
            GLES20.glDeleteProgram(resources.program);
        }
        if (resources.vertexShader != 0) {
            GLES20.glDeleteShader(resources.vertexShader);
        }
        if (resources.fragmentShader != 0) {
            GLES20.glDeleteShader(resources.fragmentShader);
        }
        if (resources.vao != 0) {
            int[] vertexArray = {resources.vao};
            GLES30.glDeleteVertexArrays(1, vertexArray, 0);
        }

        int[] buffers = {
                resources.vbo,
                resources.ebo,
                resources.indirectBuffer
        };
        for (int i = 0; i < buffers.length; i++) {
            if (buffers[i] == 0) {
                buffers[i] = 0;
            }
        }
        if (resources.vbo != 0) {
            GLES20.glDeleteBuffers(1, new int[]{resources.vbo}, 0);
        }
        if (resources.ebo != 0) {
            GLES20.glDeleteBuffers(1, new int[]{resources.ebo}, 0);
        }
        if (resources.indirectBuffer != 0) {
            GLES20.glDeleteBuffers(1, new int[]{resources.indirectBuffer}, 0);
        }

        state.restore();
        GlError error = readGlErrors();
        return error == null ? null : error.describe("resource cleanup/state restore");
    }

    private static GlError readGlErrors() {
        int first = GLES20.GL_NO_ERROR;
        int count = 0;
        for (int i = 0; i < 64; i++) {
            int error = GLES20.glGetError();
            if (error == GLES20.GL_NO_ERROR) {
                break;
            }
            if (first == GLES20.GL_NO_ERROR) {
                first = error;
            }
            count++;
        }
        return first == GLES20.GL_NO_ERROR ? null : new GlError(first, count);
    }

    private static void requireNoGlError(String stage) throws GlFailure {
        GlError error = readGlErrors();
        if (error != null) {
            throw new GlFailure(stage, error);
        }
    }

    private static String safeLog(String log) {
        return log == null || log.length() == 0 ? "(empty log)" : log;
    }

    private static String hex(int value) {
        return "0x" + Integer.toHexString(value);
    }

    private static String describe(Throwable throwable) {
        String message = throwable.getMessage();
        return throwable.getClass().getSimpleName()
                + (message == null || message.length() == 0 ? "" : ": " + message);
    }

    private interface DrawCall {
        void run();
    }

    private static final class ProbeResources {
        int vbo;
        int ebo;
        int indirectBuffer;
        int vao;
        int texture;
        int framebuffer;
        int vertexShader;
        int fragmentShader;
        int program;
    }

    private static final class GlError {
        final int code;
        final int count;

        GlError(int code, int count) {
            this.code = code;
            this.count = count;
        }

        String describe(String stage) {
            return "GL error after " + stage + ": " + hex(code)
                    + (count > 1 ? " (" + count + " errors)" : "");
        }

        JSONObject toJson() throws Exception {
            JSONObject json = new JSONObject();
            json.put("code", hex(code));
            json.put("count", count);
            return json;
        }
    }

    private static final class GlFailure extends Exception {
        final GlError error;

        GlFailure(String stage, GlError error) {
            super(error.describe(stage));
            this.error = error;
        }
    }

    private static final class ShaderFailure extends Exception {
        final String stage;
        final String log;
        final int errorCode;

        ShaderFailure(String stage, String message, int errorCode) {
            super(stage + ": " + message);
            this.stage = stage;
            this.log = message;
            this.errorCode = errorCode;
        }
    }

    private static final class ProbeFailure extends Exception {
        final String stage;

        ProbeFailure(String stage, String message) {
            super(stage + ": " + message);
            this.stage = stage;
        }
    }

    private static final class GlState {
        int program;
        int vertexArray;
        int arrayBuffer;
        int elementBuffer;
        int indirectBuffer;
        int shaderStorageBuffer;
        int drawFramebuffer;
        int readFramebuffer;
        int activeTexture;
        int textureUnit0Binding;
        int pixelPackBuffer;
        int packAlignment;
        int packRowLength;
        int packSkipRows;
        int packSkipPixels;
        int[] viewport = new int[4];
        float[] clearColor = new float[4];
        boolean[] colorMask = new boolean[4];
        boolean[] capabilities = new boolean[CAPABILITIES.length];
        boolean primitiveRestart;

        void capture() {
            program = getInteger(GLES20.GL_CURRENT_PROGRAM);
            vertexArray = getInteger(GLES30.GL_VERTEX_ARRAY_BINDING);
            arrayBuffer = getInteger(GLES20.GL_ARRAY_BUFFER_BINDING);
            elementBuffer = getInteger(GLES20.GL_ELEMENT_ARRAY_BUFFER_BINDING);
            indirectBuffer = getInteger(GLES31.GL_DRAW_INDIRECT_BUFFER_BINDING);
            shaderStorageBuffer = getInteger(GLES31.GL_SHADER_STORAGE_BUFFER_BINDING);
            drawFramebuffer = getInteger(GLES30.GL_DRAW_FRAMEBUFFER_BINDING);
            readFramebuffer = getInteger(GLES30.GL_READ_FRAMEBUFFER_BINDING);

            activeTexture = getInteger(GLES20.GL_ACTIVE_TEXTURE);
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            textureUnit0Binding = getInteger(GLES20.GL_TEXTURE_BINDING_2D);

            pixelPackBuffer = getInteger(GLES30.GL_PIXEL_PACK_BUFFER_BINDING);
            packAlignment = getInteger(GLES20.GL_PACK_ALIGNMENT);
            packRowLength = getInteger(GLES30.GL_PACK_ROW_LENGTH);
            packSkipRows = getInteger(GLES30.GL_PACK_SKIP_ROWS);
            packSkipPixels = getInteger(GLES30.GL_PACK_SKIP_PIXELS);

            GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, viewport, 0);
            GLES20.glGetFloatv(GLES20.GL_COLOR_CLEAR_VALUE, clearColor, 0);
            GLES20.glGetBooleanv(GLES20.GL_COLOR_WRITEMASK, colorMask, 0);
            for (int i = 0; i < CAPABILITIES.length; i++) {
                capabilities[i] = GLES20.glIsEnabled(CAPABILITIES[i]);
            }
            primitiveRestart =
                    GLES20.glIsEnabled(GLES30.GL_PRIMITIVE_RESTART_FIXED_INDEX);
        }

        void restore() {
            GLES20.glUseProgram(program);
            GLES30.glBindVertexArray(vertexArray);
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, arrayBuffer);
            GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, elementBuffer);
            GLES20.glBindBuffer(GLES31.GL_DRAW_INDIRECT_BUFFER, indirectBuffer);
            GLES20.glBindBuffer(GLES31.GL_SHADER_STORAGE_BUFFER, shaderStorageBuffer);
            GLES20.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, drawFramebuffer);
            GLES20.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, readFramebuffer);

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0);
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureUnit0Binding);
            GLES20.glActiveTexture(activeTexture);

            GLES20.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pixelPackBuffer);
            GLES20.glPixelStorei(GLES20.GL_PACK_ALIGNMENT, packAlignment);
            GLES20.glPixelStorei(GLES30.GL_PACK_ROW_LENGTH, packRowLength);
            GLES20.glPixelStorei(GLES30.GL_PACK_SKIP_ROWS, packSkipRows);
            GLES20.glPixelStorei(GLES30.GL_PACK_SKIP_PIXELS, packSkipPixels);
            GLES20.glViewport(
                    viewport[0], viewport[1], viewport[2], viewport[3]);
            GLES20.glClearColor(
                    clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
            GLES20.glColorMask(
                    colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
            for (int i = 0; i < CAPABILITIES.length; i++) {
                setCapability(CAPABILITIES[i], capabilities[i]);
            }
            setCapability(
                    GLES30.GL_PRIMITIVE_RESTART_FIXED_INDEX,
                    primitiveRestart);
        }

        private static int getInteger(int name) {
            int[] value = new int[1];
            GLES20.glGetIntegerv(name, value, 0);
            return value[0];
        }

        private static void setCapability(int capability, boolean enabled) {
            if (enabled) {
                GLES20.glEnable(capability);
            } else {
                GLES20.glDisable(capability);
            }
        }
    }
}
