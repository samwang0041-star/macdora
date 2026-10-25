package local.androiduse.probe;

import android.Manifest;
import android.app.Activity;
import android.content.res.Configuration;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.util.Log;
import android.util.Range;
import android.util.Size;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

public final class CameraProbeActivity extends Activity {
    private static final String TAG = "AndroidUseCameraProbe";
    private static final int CAMERA_PERMISSION_REQUEST = 41;
    private static final int TARGET_FPS = 30;
    private static final int METADATA_INTERVAL_FRAMES = 30;

    private final Object stateLock = new Object();

    private CameraManager cameraManager;
    private CameraDevice cameraDevice;
    private CameraCaptureSession captureSession;
    private Surface previewSurface;
    private HandlerThread cameraThread;
    private Handler cameraHandler;
    private TextureView previewView;
    private SurfaceTexture previewTexture;
    private TextView summaryView;
    private TextView errorView;
    private Size selectedPreviewSize;
    private Range<Integer> selectedFpsRange;
    private int sensorOrientation = -1;
    private long openRequestUptimeMs;
    private long frameRequestUptimeMs;
    private long lastConfigErrorFrame;
    private long openLatencyMs = -1;
    private long firstFrameLatencyMs = -1;
    private long previousSensorTimestampNs = -1;
    private long lastDistinctSensorTimestampNs = -1;
    private long sumIntervalNs;
    private int intervalCount;
    private long latestIntervalNs;
    private long maxIntervalNs;
    private int frameCount;
    private int sensorTimestampCount;
    private int duplicateTimestampCount;
    private long cameraGeneration;
    private int lastSummaryFrame;
    private boolean opening;
    private boolean active;
    private boolean destroyed;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        cameraManager = (CameraManager) getSystemService(CAMERA_SERVICE);
        buildInterface();

        cameraThread = new HandlerThread("CameraProbe");
        cameraThread.start();
        cameraHandler = new Handler(cameraThread.getLooper());

        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, CAMERA_PERMISSION_REQUEST);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        synchronized (stateLock) {
            active = true;
            destroyed = false;
        }
        if (hasCameraPermission() && previewView.isAvailable()) {
            startCamera();
        }
    }

    @Override
    protected void onPause() {
        synchronized (stateLock) {
            active = false;
        }
        stopCamera();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        synchronized (stateLock) {
            destroyed = true;
        }
        stopCamera();
        if (cameraThread != null) {
            cameraThread.quitSafely();
            try {
                cameraThread.join(1000);
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
            }
            cameraThread = null;
        }
        super.onDestroy();
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != CAMERA_PERMISSION_REQUEST) {
            return;
        }
        if (hasCameraPermission()) {
            if (previewView.isAvailable()) {
                startCamera();
            }
        } else {
            reportError("CAMERA permission denied");
        }
    }

    private void buildInterface() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(15, 25, 24));
        int padding = dp(18);
        root.setPadding(padding, dp(14), padding, dp(14));

        TextView title = new TextView(this);
        title.setText("AndroidUse 前置相机采集探针");
        title.setTextColor(Color.rgb(251, 244, 229));
        title.setTextSize(22);
        title.setGravity(Gravity.START);
        root.addView(title, matchWidthWrap());

        previewView = new TextureView(this);
        previewView.setContentDescription("前置相机真实预览");
        previewView.setSurfaceTextureListener(new PreviewSurfaceListener(this));
        LinearLayout.LayoutParams previewParams =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f);
        previewParams.topMargin = dp(12);
        root.addView(previewView, previewParams);

        summaryView = new TextView(this);
        summaryView.setTextColor(Color.rgb(232, 216, 187));
        summaryView.setTextSize(13);
        summaryView.setLineSpacing(dp(2), 1.0f);
        updateSummary("正在初始化");
        LinearLayout.LayoutParams summaryParams = matchWidthWrap();
        summaryParams.topMargin = dp(12);
        root.addView(summaryView, summaryParams);

        errorView = new TextView(this);
        errorView.setTextColor(Color.rgb(255, 156, 122));
        errorView.setTextSize(13);
        errorView.setVisibility(View.GONE);
        LinearLayout.LayoutParams errorParams = matchWidthWrap();
        errorParams.topMargin = dp(6);
        root.addView(errorView, errorParams);

        setContentView(root);
    }

    private void startCamera() {
        synchronized (stateLock) {
            if (!active || destroyed || opening || cameraDevice != null || cameraHandler == null) {
                return;
            }
            opening = true;
            cameraGeneration++;
            resetMeasurementsLocked();
        }

        long generation;
        synchronized (stateLock) {
            selectedPreviewSize = null;
            selectedFpsRange = null;
            sensorOrientation = -1;
            generation = cameraGeneration;
        }
        try {
            String cameraId = findFrontCameraId();
            CameraCharacteristics characteristics =
                    cameraManager.getCameraCharacteristics(cameraId);
            Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
            if (facing == null || facing != CameraCharacteristics.LENS_FACING_FRONT) {
                throw new IllegalStateException("Front camera not found");
            }

            Size previewSize = choosePreviewSize(characteristics);
            Range<Integer> fpsRange = characteristics.get(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) == null
                    ? null
                    : chooseFpsRange(Arrays.asList(characteristics.get(
                            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)));
            Integer sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
            synchronized (stateLock) {
                if (!active || destroyed || generation != cameraGeneration) {
                    return;
                }
                selectedPreviewSize = previewSize;
                selectedFpsRange = fpsRange;
                sensorOrientation = sensor == null ? -1 : sensor;
                updateSummary("正在打开前置相机");
                openRequestUptimeMs = SystemClock.elapsedRealtime();
                frameRequestUptimeMs = 0L;
            }
            cameraManager.openCamera(
                    cameraId, new DeviceCallback(this, generation), cameraHandler);
        } catch (CameraAccessException | IllegalArgumentException | SecurityException
                 | IllegalStateException exception) {
            onCameraFailure("openCamera", exception);
        }
    }

    private void onDeviceOpened(CameraDevice camera, long generation) {
        synchronized (stateLock) {
            if (generation != cameraGeneration) {
                camera.close();
                return;
            }
            if (!active) {
                camera.close();
                opening = false;
                return;
            }
        if (cameraDevice != null && cameraDevice != camera) {
            camera.close();
            return;
        }
            cameraDevice = camera;
            opening = false;
            openLatencyMs = SystemClock.elapsedRealtime() - openRequestUptimeMs;
        }
        updateSummary("相机已打开，正在创建预览");
        runOnUiThread(() -> openCameraPreview(generation));
    }

    private void onDeviceDisconnected(CameraDevice camera, long generation) {
        camera.close();
        synchronized (stateLock) {
            if (generation != cameraGeneration) {
                return;
            }
            if (cameraDevice == camera) {
                cameraDevice = null;
            }
            opening = false;
        }
        reportError("Camera disconnected");
        stopCamera();
    }

    private void onDeviceError(CameraDevice camera, int error, long generation) {
        camera.close();
        synchronized (stateLock) {
            if (generation != cameraGeneration) {
                return;
            }
            if (cameraDevice == camera) {
                cameraDevice = null;
            }
            opening = false;
        }
        reportError("CameraDevice error: " + error);
        stopCamera();
    }

    private void openCameraPreview(long generation) {
        try {
            SurfaceTexture texture;
            synchronized (stateLock) {
                if (!active || destroyed || generation != cameraGeneration
                        || cameraDevice == null) {
                    return;
                }
                texture = previewView.getSurfaceTexture();
                if (texture == null) {
                    throw new IllegalStateException("Preview SurfaceTexture unavailable");
                }
                texture.setDefaultBufferSize(
                        selectedPreviewSize.getWidth(), selectedPreviewSize.getHeight());
                updatePreviewTransform();
                releasePreviewSurfaceLocked();
                previewSurface = new Surface(texture);
                CameraDevice device = cameraDevice;
                long sessionGeneration = cameraGeneration;
                device.createCaptureSession(
                        Arrays.asList(previewSurface),
                        new SessionCallback(this, sessionGeneration),
                        cameraHandler);
            }
        } catch (CameraAccessException | IllegalArgumentException | IllegalStateException exception) {
            onCameraFailure("createPreview", exception);
        }
    }

    private void onSessionConfigured(CameraCaptureSession session, long generation) {
        synchronized (stateLock) {
            if (!active || cameraDevice == null || destroyed
                    || generation != cameraGeneration) {
                session.close();
                return;
            }
            captureSession = session;
        }
        startRepeatingRequest();
    }

    private void onSessionConfigureFailed(CameraCaptureSession session, long generation) {
        synchronized (stateLock) {
            if (generation != cameraGeneration) {
                session.close();
                return;
            }
        }
        reportError("Preview session configuration failed");
        session.close();
        synchronized (stateLock) {
            if (generation == cameraGeneration) {
                stopCamera();
            }
        }
    }

    private void startRepeatingRequest() {
        CameraDevice device;
        CameraCaptureSession session;
        Surface surface;
        Range<Integer> fpsRange;
        long generation;
        synchronized (stateLock) {
            if (!active || destroyed) {
                return;
            }
            device = cameraDevice;
            session = captureSession;
            surface = previewSurface;
            fpsRange = selectedFpsRange;
            generation = cameraGeneration;
        }
        if (device == null || session == null || surface == null) {
            return;
        }
        try {
            CaptureRequest.Builder builder =
                    device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
            builder.addTarget(surface);
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
            if (fpsRange != null) {
                builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange);
            }
            synchronized (stateLock) {
                if (!active || destroyed || generation != cameraGeneration) {
                    return;
                }
                frameRequestUptimeMs = SystemClock.elapsedRealtime();
            }
            session.setRepeatingRequest(
                    builder.build(), new FrameCallback(this, generation), cameraHandler);
            updateSummary("等待首个真实 sensor frame");
        } catch (CameraAccessException | IllegalStateException exception) {
            synchronized (stateLock) {
                if (!active || destroyed || generation != cameraGeneration) {
                    return;
                }
            }
            onCameraFailure("startPreview", exception);
        }
    }

    private void onFrameCompleted(TotalCaptureResult result, long generation) {
        synchronized (stateLock) {
            if (!active || destroyed || generation != cameraGeneration) {
                return;
            }
        }
        Long sensorTimestamp = result.get(CaptureResult.SENSOR_TIMESTAMP);
        if (sensorTimestamp != null) {
            recordFrame(sensorTimestamp, generation);
        }
    }

    private void recordFrame(long sensorTimestampNs, long generation) {
        int currentFrames;
        synchronized (stateLock) {
            if (!active || destroyed || generation != cameraGeneration) {
                return;
            }
            frameCount++;
            if (sensorTimestampNs != lastDistinctSensorTimestampNs) {
                lastDistinctSensorTimestampNs = sensorTimestampNs;
                sensorTimestampCount++;
            } else {
                duplicateTimestampCount++;
            }
            if (frameCount == 1) {
                firstFrameLatencyMs =
                        SystemClock.elapsedRealtime() - frameRequestUptimeMs;
                previousSensorTimestampNs = sensorTimestampNs;
            } else if (sensorTimestampNs > previousSensorTimestampNs) {
                long intervalNs = sensorTimestampNs - previousSensorTimestampNs;
                sumIntervalNs += intervalNs;
                intervalCount++;
                latestIntervalNs = intervalNs;
                if (intervalNs > maxIntervalNs) {
                    maxIntervalNs = intervalNs;
                }
                previousSensorTimestampNs = sensorTimestampNs;
            }
            currentFrames = frameCount;
        }

        if (currentFrames == 1 || currentFrames - lastSummaryFrame >= METADATA_INTERVAL_FRAMES) {
            synchronized (stateLock) {
                if (lastConfigErrorFrame != 0 || generation != cameraGeneration) {
                    return;
                }
                reportSummaryLocked("running");
            }
        }
    }

    private String formatSummaryLocked(String resultState) {
        double averageIntervalMs = intervalCount == 0
                ? 0.0
                : sumIntervalNs / (double) intervalCount / 1_000_000.0;
        double averageFps = averageIntervalMs == 0.0 ? 0.0 : 1000.0 / averageIntervalMs;
        return String.format(
                Locale.US,
                "facing=FRONT size=%dx%d target=%s result=%s sensorOrientation=%d displayRotation=%d\n"
                        + "open=%dms firstFrame=%dms frames=%d uniqueTimestamps=%d duplicates=%d\n"
                        + "lastInterval=%.3fms avgInterval=%.3fms maxInterval=%.3fms avgFps=%.2f",
                selectedPreviewSize.getWidth(),
                selectedPreviewSize.getHeight(),
                selectedFpsRange == null ? "default" : selectedFpsRange.toString(),
                resultState,
                sensorOrientation,
                displayRotationDegrees(),
                openLatencyMs,
                firstFrameLatencyMs,
                frameCount,
                sensorTimestampCount,
                duplicateTimestampCount,
                latestIntervalNs / 1_000_000.0,
                averageIntervalMs,
                maxIntervalNs / 1_000_000.0,
                averageFps);
    }

    private void reportSummaryLocked(String resultState) {
        String summary = formatSummaryLocked(resultState);
        Log.i(TAG, summary.replace('\n', ' '));
        lastSummaryFrame = frameCount;
        final String displaySummary = summary.replace(
                " result=running", "\n状态：真实预览运行中\nresult=running");
        runOnUiThread(() -> updateSummary(displaySummary));
    }

    private void stopCamera() {
        CameraCaptureSession session;
        CameraDevice device;
        Surface surface;
        synchronized (stateLock) {
            cameraGeneration++;
            session = captureSession;
            captureSession = null;
            device = cameraDevice;
            cameraDevice = null;
            surface = previewSurface;
            previewSurface = null;
            opening = false;
        }
        if (session != null) {
            session.close();
        }
        if (device != null) {
            device.close();
        }
        if (surface != null) {
            surface.release();
        }
    }

    private void releasePreviewSurfaceLocked() {
        if (previewSurface != null) {
            previewSurface.release();
            previewSurface = null;
        }
    }

    private String findFrontCameraId() throws CameraAccessException {
        for (String cameraId : cameraManager.getCameraIdList()) {
            CameraCharacteristics characteristics =
                    cameraManager.getCameraCharacteristics(cameraId);
            Integer facing = characteristics.get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == CameraCharacteristics.LENS_FACING_FRONT) {
                return cameraId;
            }
        }
        throw new IllegalStateException("Front camera not found");
    }

    private Size choosePreviewSize(CameraCharacteristics characteristics) {
        android.hardware.camera2.params.StreamConfigurationMap streamMap =
                characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        if (streamMap == null) {
            throw new IllegalStateException("Camera reports no stream configuration");
        }
        Size[] sizes = streamMap.getOutputSizes(SurfaceTexture.class);
        if (sizes == null || sizes.length == 0) {
            throw new IllegalStateException("Camera reports no preview sizes");
        }
        List<Size> candidates = new ArrayList<>(Arrays.asList(sizes));
        candidates.sort(Comparator
                .comparingLong((Size size) -> Math.abs(
                        (long) size.getWidth() * size.getHeight() - 1280L * 720L))
                .thenComparing((Size size) -> size.getWidth() > size.getHeight()));
        return candidates.get(0);
    }

    private Range<Integer> chooseFpsRange(List<Range<Integer>> ranges) {
        if (ranges == null || ranges.isEmpty()) {
            return null;
        }
        for (Range<Integer> range : ranges) {
            if (range.getLower() == TARGET_FPS && range.getUpper() == TARGET_FPS) {
                return range;
            }
        }
        Range<Integer> best = null;
        for (Range<Integer> range : ranges) {
            if (range.getLower() == TARGET_FPS
                    && (best == null || range.getUpper() < best.getUpper())) {
                best = range;
            }
        }
        if (best != null) {
            return best;
        }
        for (Range<Integer> range : ranges) {
            if (range.getUpper() == TARGET_FPS
                    && (best == null || range.getLower() > best.getLower())) {
                best = range;
            }
        }
        return best;
    }

    private void updatePreviewTransform() {
        if (previewView.getSurfaceTexture() == null || selectedPreviewSize == null
                || previewView.getWidth() == 0 || previewView.getHeight() == 0) {
            return;
        }
        int displayRotationDegrees = displayRotationDegrees();
        int relativeRotation = sensorOrientation < 0
                ? 0
                : (sensorOrientation - displayRotationDegrees + 360) % 360;
        float viewWidth = previewView.getWidth();
        float viewHeight = previewView.getHeight();
        float bufferWidth = selectedPreviewSize.getWidth();
        float bufferHeight = selectedPreviewSize.getHeight();
        // TextureView already applies the sensor's buffer rotation before our transform.
        // Its stretched input dimensions therefore differ from the stream dimensions.
        if (sensorOrientation == 90 || sensorOrientation == 270) {
            float originalWidth = bufferWidth;
            bufferWidth = bufferHeight;
            bufferHeight = originalWidth;
        }
        boolean swapDimensions = relativeRotation == 90 || relativeRotation == 270;
        float rotatedWidth = swapDimensions ? bufferHeight : bufferWidth;
        float rotatedHeight = swapDimensions ? bufferWidth : bufferHeight;
        float scale = Math.min(viewWidth / rotatedWidth, viewHeight / rotatedHeight);
        Matrix transform = new Matrix();
        // Undo TextureView's initial stretch, rotate around the image center, then fit.
        transform.setTranslate(-viewWidth / 2f, -viewHeight / 2f);
        transform.postScale(bufferWidth / viewWidth, bufferHeight / viewHeight);
        // Front camera buffers rotate counterclockwise; Android Matrix uses clockwise angles.
        // https://developer.android.com/media/camera/camera2/camera-preview#orientation_calculation
        transform.postRotate(-relativeRotation);
        transform.postScale(scale, scale);
        transform.postTranslate(viewWidth / 2f, viewHeight / 2f);
        previewView.setTransform(transform);
    }

    private int displayRotationDegrees() {
        switch (previewView.getDisplay() == null
                ? Surface.ROTATION_0
                : previewView.getDisplay().getRotation()) {
            case Surface.ROTATION_90:
                return 90;
            case Surface.ROTATION_180:
                return 180;
            case Surface.ROTATION_270:
                return 270;
            default:
                return 0;
        }
    }

    private void resetMeasurementsLocked() {
        synchronized (stateLock) {
            openRequestUptimeMs = 0L;
            frameRequestUptimeMs = 0L;
            openLatencyMs = -1;
            firstFrameLatencyMs = -1;
            previousSensorTimestampNs = -1;
            lastDistinctSensorTimestampNs = -1;
            sumIntervalNs = 0;
            intervalCount = 0;
            latestIntervalNs = 0L;
            maxIntervalNs = 0L;
            frameCount = 0;
            sensorTimestampCount = 0;
            duplicateTimestampCount = 0;
            lastSummaryFrame = 0;
            lastConfigErrorFrame = 0;
        }
    }

    private void onCameraFailure(String operation, Exception exception) {
        synchronized (stateLock) {
            if ("createPreview".equals(operation)
                    || "startPreview".equals(operation)) {
                lastConfigErrorFrame = frameCount == 0 ? -1L : frameCount;
            }
            opening = false;
        }
        stopCamera();
        reportError(operation + ": " + exception.getClass().getSimpleName()
                + (exception.getMessage() == null ? "" : ": " + exception.getMessage()));
    }

    private void reportError(String message) {
        Log.e(TAG, message);
        runOnUiThread(() -> {
            boolean hasCameraDetails;
            synchronized (stateLock) {
                hasCameraDetails = selectedPreviewSize != null;
            }
            if (errorView != null) {
                errorView.setText("错误 / Error: " + message);
                errorView.setVisibility(View.VISIBLE);
            }
            if (summaryView != null) {
                if (hasCameraDetails) {
                    synchronized (stateLock) {
                        if (selectedPreviewSize != null) {
                            summaryView.setText(formatSummaryLocked("error"));
                        }
                    }
                } else {
                    summaryView.setText("result=error");
                }
            }
        });
    }

    private void updateSummary(String message) {
        runOnUiThread(() -> {
            if (summaryView != null) {
                summaryView.setText(message);
            }
        });
    }

    private boolean hasCameraPermission() {
        return checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED;
    }

    private LinearLayout.LayoutParams matchWidthWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (previewTexture != null && selectedPreviewSize != null) {
            previewTexture.setDefaultBufferSize(
                    selectedPreviewSize.getWidth(), selectedPreviewSize.getHeight());
        }
        previewView.post(this::updatePreviewTransform);
    }

    private static final class PreviewSurfaceListener
            implements TextureView.SurfaceTextureListener {
        private final CameraProbeActivity activity;

        PreviewSurfaceListener(CameraProbeActivity activity) {
            this.activity = activity;
        }

        @Override
        public void onSurfaceTextureAvailable(
                SurfaceTexture texture, int width, int height) {
            activity.previewTexture = texture;
            if (activity.hasCameraPermission()) {
                activity.startCamera();
            }
        }

        @Override
        public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) {
            activity.previewTexture = null;
            activity.stopCamera();
            return true;
        }

        @Override
        public void onSurfaceTextureUpdated(SurfaceTexture texture) {
        }

        @Override
        public void onSurfaceTextureSizeChanged(
                SurfaceTexture texture, int width, int height) {
            if (activity.selectedPreviewSize != null) {
                texture.setDefaultBufferSize(
                        activity.selectedPreviewSize.getWidth(),
                        activity.selectedPreviewSize.getHeight());
            }
            activity.updatePreviewTransform();
        }
    }

    private static final class DeviceCallback extends CameraDevice.StateCallback {
        private final CameraProbeActivity activity;
        private final long generation;

        DeviceCallback(CameraProbeActivity activity, long generation) {
            this.activity = activity;
            this.generation = generation;
        }

        @Override
        public void onOpened(CameraDevice camera) {
            activity.onDeviceOpened(camera, generation);
        }

        @Override
        public void onDisconnected(CameraDevice camera) {
            activity.onDeviceDisconnected(camera, generation);
        }

        @Override
        public void onError(CameraDevice camera, int error) {
            activity.onDeviceError(camera, error, generation);
        }
    }

    private static final class SessionCallback
            extends CameraCaptureSession.StateCallback {
        private final CameraProbeActivity activity;
        private final long generation;

        SessionCallback(CameraProbeActivity activity, long generation) {
            this.activity = activity;
            this.generation = generation;
        }

        @Override
        public void onConfigured(CameraCaptureSession session) {
            activity.onSessionConfigured(session, generation);
        }

        @Override
        public void onConfigureFailed(CameraCaptureSession session) {
            activity.onSessionConfigureFailed(session, generation);
        }
    }

    private static final class FrameCallback
            extends CameraCaptureSession.CaptureCallback {
        private final CameraProbeActivity activity;
        private final long generation;

        FrameCallback(CameraProbeActivity activity, long generation) {
            this.activity = activity;
            this.generation = generation;
        }

        @Override
        public void onCaptureCompleted(
                CameraCaptureSession session,
                CaptureRequest request,
                TotalCaptureResult result) {
            activity.onFrameCompleted(result, generation);
        }
    }
}
