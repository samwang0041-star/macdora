package local.androiduse.probe;

import android.app.Activity;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

/** Offline, synthetic data only. Verification never creates or repairs fixture data. */
public final class PersistenceActivity extends Activity {
    private static final String VALUE = "neutral local persistence fixture";
    private static final String KEY_ALIAS = "macdora-persistence-probe";
    private TextView result;
    private Button seed;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        int padding = Math.round(24 * getResources().getDisplayMetrics().density);
        body.setPadding(padding, padding, padding, padding);
        body.setBackgroundColor(0xfff3efe7);
        TextView title = new TextView(this);
        title.setText("本地数据保留检查\n" + getPackageName());
        title.setTextSize(22);
        body.addView(title);
        seed = new Button(this);
        seed.setText("创建中性测试数据");
        seed.setOnClickListener(view -> {
            try { createFixture(); verify(); }
            catch (Exception error) { result.setText("初始化失败：" + error.getClass().getSimpleName()); }
        });
        body.addView(seed);
        Button refresh = new Button(this);
        refresh.setText("重新检查（不修复数据）");
        refresh.setOnClickListener(view -> verify());
        body.addView(refresh);
        result = new TextView(this);
        result.setTextSize(18);
        result.setTextIsSelectable(true);
        body.addView(result);
        setContentView(body);
    }

    @Override
    protected void onResume() {
        super.onResume();
        verify();
    }

    private SharedPreferences preferences() { return getSharedPreferences("persistence", MODE_PRIVATE); }
    private File file(String name) { return new File(getFilesDir(), name); }

    private void createFixture() throws Exception {
        // Never reseed a previously initialized fixture; missing state must remain a failure.
        if (file("initialized").exists()) throw new IllegalStateException("Already initialized");
        Files.write(file("local-state.txt").toPath(), VALUE.getBytes(StandardCharsets.UTF_8));
        SQLiteDatabase database = SQLiteDatabase.openOrCreateDatabase(file("state.sqlite"), null);
        try {
            database.execSQL("CREATE TABLE retained_state (value TEXT NOT NULL)");
            database.execSQL("INSERT INTO retained_state VALUES (?)", new Object[] {VALUE});
        } finally { database.close(); }
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        SecretKey key = generator.generateKey();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key);
        Files.write(file("encrypted-state").toPath(), cipher.doFinal(VALUE.getBytes(StandardCharsets.UTF_8)));
        Files.write(file("encrypted-iv").toPath(), cipher.getIV());
        if (!preferences().edit().putString("value", VALUE).putString("androidIDHash", androidIDHash())
                .putString("model", Build.MODEL).commit()) throw new IllegalStateException("Preferences write failed");
        Files.write(file("initialized").toPath(), new byte[] {1});
    }

    private void verify() {
        JSONObject status = new JSONObject();
        boolean initialized = file("initialized").exists();
        seed.setEnabled(!initialized);
        try {
            status.put("checkedAtUnixMillis", System.currentTimeMillis());
            status.put("applicationUID", android.os.Process.myUid());
            status.put("package", getPackageName());
            int smallestWidth = getResources().getConfiguration().smallestScreenWidthDp;
            status.put("smallestScreenWidthDp", smallestWidth);
            status.put("densityDpi", getResources().getDisplayMetrics().densityDpi);
            status.put("orientation", getResources().getConfiguration().orientation);
            status.put("tabletConfiguration", smallestWidth >= 600);
            status.put("initialized", initialized);
            if (!initialized) {
                status.put("allDataOK", false);
            } else {
                boolean preferencesOK = VALUE.equals(preferences().getString("value", ""));
                boolean fileOK = false;
                boolean databaseOK = false;
                boolean keystoreOK = false;
                try { fileOK = VALUE.equals(new String(Files.readAllBytes(file("local-state.txt").toPath()), StandardCharsets.UTF_8)); }
                catch (Exception ignored) { }
                try {
                    SQLiteDatabase database = SQLiteDatabase.openDatabase(file("state.sqlite").getPath(), null, SQLiteDatabase.OPEN_READONLY);
                    try (Cursor cursor = database.rawQuery("SELECT value FROM retained_state", null)) {
                        databaseOK = cursor.moveToFirst() && VALUE.equals(cursor.getString(0)) && !cursor.moveToNext();
                    } finally { database.close(); }
                } catch (Exception ignored) { }
                try {
                    KeyStore store = KeyStore.getInstance("AndroidKeyStore");
                    store.load(null);
                    SecretKey key = (SecretKey) store.getKey(KEY_ALIAS, null);
                    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                    cipher.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, Files.readAllBytes(file("encrypted-iv").toPath())));
                    keystoreOK = Arrays.equals(VALUE.getBytes(StandardCharsets.UTF_8), cipher.doFinal(Files.readAllBytes(file("encrypted-state").toPath())));
                } catch (Exception ignored) { }
                boolean idStable = androidIDHash().equals(preferences().getString("androidIDHash", ""));
                status.put("preferencesOK", preferencesOK);
                status.put("fileOK", fileOK);
                status.put("databaseOK", databaseOK);
                status.put("keystoreOK", keystoreOK);
                status.put("androidIDStable", idStable);
                status.put("deviceModelChanged", !Build.MODEL.equals(preferences().getString("model", "")));
                status.put("allDataOK", preferencesOK && fileOK && databaseOK && keystoreOK && idStable);
            }
            result.setText((status.optBoolean("allDataOK") ? "PASS · 数据完整" : "尚未初始化或数据检查失败") + "\n\n" + status.toString(2));
            exportStatus(status);
        } catch (Exception error) {
            result.setText("检查失败：" + error.getClass().getSimpleName());
            try {
                status.put("allDataOK", false);
                status.put("errorType", error.getClass().getSimpleName());
                exportStatus(status);
            } catch (Exception ignored) { }
        }
    }

    private void exportStatus(JSONObject status) throws Exception {
        // Export only test results and freshness metadata, never keys or device identifiers.
        File directory = getExternalFilesDir(null);
        if (directory == null) throw new java.io.IOException("External report directory unavailable");
        try (FileOutputStream output = new FileOutputStream(new File(directory, "persistence-status.json"))) {
            output.write(status.toString(2).getBytes(StandardCharsets.UTF_8));
        }
    }

    private String androidIDHash() throws Exception {
        String id = Settings.Secure.getString(getContentResolver(), Settings.Secure.ANDROID_ID);
        if (id == null || id.isEmpty()) throw new IllegalStateException("Android ID unavailable");
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(id.getBytes(StandardCharsets.UTF_8));
        StringBuilder result = new StringBuilder();
        for (byte value : digest) result.append(String.format("%02x", value & 0xff));
        return result.toString();
    }
}
