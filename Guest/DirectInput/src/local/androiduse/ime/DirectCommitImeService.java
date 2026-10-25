package local.androiduse.ime;

import android.inputmethodservice.InputMethodService;
import android.net.Credentials;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/** Direct user input only. No clipboard, network, storage, text reads or payload logging. */
public final class DirectCommitImeService extends InputMethodService {
    public static final String SOCKET_NAME = "androiduse_ime_v1";
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final AtomicBoolean SERVER_STARTED = new AtomicBoolean(false);
    private static volatile Client current;
    // Only the IME main thread reads/writes these editor properties.
    private static DirectCommitImeService activeService;
    private static long focusEpoch = 1;
    private static boolean editorActive;
    private static boolean sensitive;
    private volatile boolean destroyed;

    @Override public void onCreate() {
        super.onCreate();
        int display = getDisplay() == null ? -1 : getDisplay().getDisplayId();
        if (display > 0 || activeService == null || activeService.destroyed) {
            activeService = this;
        }
        startServerIfNeeded();
    }

    @Override public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        int display = getDisplay() == null ? -1 : getDisplay().getDisplayId();
        if (display <= 0 && activeService != null && activeService != this && !activeService.destroyed) {
            return;
        }
        activeService = this;
        focusEpoch++;
        editorActive = display > 0 && permittedEditor(info);
        sensitive = editorActive && info != null && isSensitive(info.inputType);
        publishFocus();
    }

    @Override public void onFinishInput() {
        if (activeService == this) {
            focusEpoch++; editorActive = false; sensitive = false;
            publishFocus();
        }
        super.onFinishInput();
    }

    @Override public void onUnbindInput() {
        if (activeService == this) {
            focusEpoch++; editorActive = false; sensitive = false;
            publishFocus();
        }
        super.onUnbindInput();
    }

    @Override public boolean onEvaluateInputViewShown() { return false; }
    @Override public boolean onEvaluateFullscreenMode() { return false; }
    @Override public boolean onShowInputRequested(int flags, boolean configChange) { return false; }
    @Override public View onCreateInputView() { return null; }

    private static boolean permittedEditor(EditorInfo info) {
        if (info == null || (info.inputType & InputType.TYPE_MASK_CLASS) == InputType.TYPE_NULL) return false;
        String pkg = info.packageName;
        if (pkg == null || pkg.isEmpty()) return false;
        return !"com.android.launcher3".equals(pkg) && !"com.android.systemui".equals(pkg);
    }

    private static boolean isSensitive(int type) {
        int kind = type & InputType.TYPE_MASK_CLASS;
        int variation = type & InputType.TYPE_MASK_VARIATION;
        return kind == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            || kind == InputType.TYPE_CLASS_TEXT && (
                variation == InputType.TYPE_TEXT_VARIATION_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD);
    }

    private static void publishFocus() {
        Client client = current;
        if (client != null) {
            client.confirmedEpoch = -1; client.confirmedConnection = null;
            client.focus(focusEpoch, editorActive, sensitive);
        }
    }

    private static void startServerIfNeeded() {
        if (!SERVER_STARTED.compareAndSet(false, true)) return;
        Thread server = new Thread(DirectCommitImeService::serve, "AndroidUse-direct-input");
        server.setDaemon(true);
        server.start();
    }

    private static void serve() {
        LocalServerSocket socket = null;
        try {
            socket = new LocalServerSocket(SOCKET_NAME);
            while (true) {
                LocalSocket connection = socket.accept();
                Credentials peer = connection.getPeerCredentials();
                int uid = peer == null ? -1 : peer.getUid();
                // adb forward reaches the abstract socket as adbd, never as a Guest app.
                if (uid != 2000 && uid != 0) { connection.close(); continue; }
                Client previous = current;
                Client client = new Client(connection);
                current = client;
                if (previous != null) previous.close();
                client.write(out -> { out.writeByte(0); out.writeByte(2); out.writeInt(uid); });
                MAIN.post(() -> { if (current == client) publishFocus(); });
                Thread reader = new Thread(() -> {
                    try { readRequests(client); }
                    catch (IOException | InterruptedException ignored) { /* No payloads in logs. */ }
                    finally {
                        client.close();
                        if (current == client) current = null;
                    }
                }, "AndroidUse-direct-input-reader");
                reader.setDaemon(true);
                reader.start();
            }
        } catch (IOException ignored) {
            // The host observes a closed or unavailable bridge and presents a local error.
        } finally {
            SERVER_STARTED.set(false);
            if (socket != null) try { socket.close(); } catch (IOException ignored) { }
        }
    }

    private static void readRequests(Client client) throws IOException, InterruptedException {
        DataInputStream in = new DataInputStream(client.socket.getInputStream());
        while (!client.closed.get()) {
            int magic = in.readUnsignedShort();
            int version = in.readUnsignedByte();
            int op = in.readUnsignedByte();
            int sequence = in.readInt();
            long expectedEpoch = in.readLong();
            long pointerSequence = in.readLong();
            int expectedDisplay = in.readInt();
            int count = in.readUnsignedShort();
            if (magic != 0x4155 || version != 2 || (op != 1 && op != 2)
                || (op == 1 && (count == 0 || count > 4096)) || (op == 2 && count != 0)) {
                client.ack(sequence, 1); return;
            }
            byte[] payload = new byte[count];
            in.readFully(payload);
            final String text;
            try {
                text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(payload)).toString();
            } catch (Exception invalid) { client.ack(sequence, 1); return; }
            final long deadline = SystemClock.uptimeMillis() + 200;
            CountDownLatch done = new CountDownLatch(1);
            AtomicBoolean cancelled = new AtomicBoolean(false);
            AtomicInteger status = new AtomicInteger(4);
            AtomicReference<FocusResult> confirmed = new AtomicReference<>();
            MAIN.post(() -> {
                try {
                    if (op == 2) { client.confirmedEpoch = -1; client.confirmedConnection = null; }
                    DirectCommitImeService service = activeService;
                    if (cancelled.get() || service == null || service.destroyed
                        || current != client || client.closed.get()
                        || SystemClock.uptimeMillis() >= deadline) return;
                    if (!editorActive || !service.getCurrentInputStarted()
                        || !permittedEditor(service.getCurrentInputEditorInfo())) { status.set(2); return; }
                    InputConnection input = service.getCurrentInputConnection();
                    if (input == null) { status.set(2); return; }
                    int display = service.getDisplay() == null ? -1 : service.getDisplay().getDisplayId();
                    if (display <= 0 || (expectedDisplay >= 0 && display != expectedDisplay)) { status.set(2); return; }
                    if (op == 2) {
                        long epoch = focusEpoch;
                        // Zero mode/filter checks the remote connection without requesting
                        // cursor text, coordinates, or composing data.
                        if (!input.requestCursorUpdates(0, 0)) { status.set(5); return; }
                        if (cancelled.get() || SystemClock.uptimeMillis() >= deadline
                            || current != client || client.closed.get() || !editorActive
                            || activeService != service || service.destroyed
                            || focusEpoch != epoch || service.getCurrentInputConnection() != input) { status.set(2); return; }
                        client.confirmedEpoch = epoch; client.confirmedPointer = pointerSequence;
                        client.confirmedDisplay = display; client.confirmedConnection = input;
                        confirmed.set(new FocusResult(epoch, pointerSequence, display, sensitive));
                        status.set(0); return;
                    }
                    if (expectedDisplay != display || expectedEpoch != focusEpoch || client.confirmedEpoch != focusEpoch
                        || client.confirmedPointer != pointerSequence || client.confirmedDisplay != display
                        || client.confirmedConnection != input) { status.set(2); return; }
                    // This is the system-authorized active editor connection, including standard
                    // password editors. A bank's own keyboard without this session is never bypassed.
                    status.set(input.commitText(text, 1) ? 0 : 3);
                } finally { done.countDown(); }
            });
            if (!done.await(200, TimeUnit.MILLISECONDS)) cancelled.set(true);
            if (op == 2) client.confirmation(sequence, status.get(), confirmed.get(), pointerSequence);
            else client.ack(sequence, status.get());
            // A failed/expired request is discarded; it is never replayed on another editor.
        }
    }

    @Override public void onDestroy() {
        destroyed = true;
        if (activeService == this) {
            activeService = null;
            editorActive = false;
            sensitive = false;
            focusEpoch++;
            publishFocus();
        }
        super.onDestroy();
    }

    private interface Output { void send(DataOutputStream out) throws IOException; }

    private static final class FocusResult {
        final long epoch, pointer;
        final int display;
        final boolean sensitive;
        FocusResult(long epoch, long pointer, int display, boolean sensitive) {
            this.epoch = epoch; this.pointer = pointer; this.display = display; this.sensitive = sensitive;
        }
    }

    private static final class Client {
        final LocalSocket socket;
        final AtomicBoolean closed = new AtomicBoolean(false);
        // Main-thread fields, invalidated whenever the editor session changes.
        long confirmedEpoch = -1, confirmedPointer = -1;
        int confirmedDisplay = -1;
        InputConnection confirmedConnection;
        final ThreadPoolExecutor writer = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
            new ArrayBlockingQueue<Runnable>(32), runnable -> {
                Thread thread = new Thread(runnable, "AndroidUse-input-state"); thread.setDaemon(true); return thread;
            });
        Client(LocalSocket socket) { this.socket = socket; }
        void focus(long epoch, boolean active, boolean sensitive) {
            write(out -> { out.writeByte(1); out.writeBoolean(active); out.writeBoolean(sensitive); out.writeLong(epoch); });
        }
        void ack(int sequence, int status) {
            write(out -> { out.writeByte(2); out.writeByte(status); out.writeInt(sequence); });
        }
        void confirmation(int sequence, int status, FocusResult focus, long pointer) {
            write(out -> {
                out.writeByte(3); out.writeInt(sequence); out.writeByte(status);
                out.writeLong(focus == null ? 0 : focus.epoch);
                out.writeLong(focus == null ? pointer : focus.pointer);
                out.writeInt(focus == null ? -1 : focus.display);
                out.writeBoolean(focus != null && focus.sensitive);
            });
        }
        void write(Output output) {
            if (closed.get()) return;
            try {
                writer.execute(() -> {
                    if (closed.get()) return;
                    try {
                        DataOutputStream out = new DataOutputStream(socket.getOutputStream());
                        output.send(out); out.flush();
                    } catch (IOException ignored) { close(); }
                });
            } catch (java.util.concurrent.RejectedExecutionException ignored) { close(); }
        }
        void close() {
            if (!closed.compareAndSet(false, true)) return;
            writer.shutdownNow();
            try { socket.shutdownInput(); } catch (IOException ignored) { }
            try { socket.shutdownOutput(); } catch (IOException ignored) { }
            try { socket.close(); } catch (IOException ignored) { }
        }
    }
}
