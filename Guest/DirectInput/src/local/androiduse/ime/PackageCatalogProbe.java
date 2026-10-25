package local.androiduse.ime;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;

import java.io.ByteArrayOutputStream;

/**
 * Renders installed Android application icons and reads package labels/versions
 * directly from the guest PackageManager so the host management UI displays each
 * application's real icon instead of synthetic symbol badges.
 */
public final class PackageCatalogProbe {
    private static final int ICON_SIZE = 160;

    private PackageCatalogProbe() {}

    public static void main(String[] args) {
        try {
            if (Looper.getMainLooper() == null) {
                Looper.prepareMainLooper();
            }
            Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
            Object activityThread = activityThreadClass.getMethod("systemMain").invoke(null);
            Context context = (Context) activityThreadClass.getMethod("getSystemContext").invoke(activityThread);
            PackageManager pm = context.getPackageManager();
            for (String pkg : args) {
                if (pkg == null || pkg.isEmpty()) continue;
                try {
                    ApplicationInfo appInfo = pm.getApplicationInfo(pkg, 0);
                    PackageInfo pkgInfo = pm.getPackageInfo(pkg, 0);
                    CharSequence rawLabel = pm.getApplicationLabel(appInfo);
                    String label = rawLabel != null ? sanitize(rawLabel.toString()) : "";
                    String version = (pkgInfo != null && pkgInfo.versionName != null)
                        ? sanitize(pkgInfo.versionName)
                        : "";
                    Drawable icon = pm.getApplicationIcon(appInfo);
                    String base64PNG = renderIconBase64(icon);
                    System.out.println("META\t" + pkg + "\t" + label + "\t" + version + "\t" + base64PNG);
                } catch (Throwable ignored) {
                }
            }
        } catch (Throwable ignored) {
        }
    }

    private static String sanitize(String value) {
        return value.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ').trim();
    }

    private static String renderIconBase64(Drawable drawable) {
        if (drawable == null) return "";
        Bitmap bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        if (drawable instanceof AdaptiveIconDrawable) {
            AdaptiveIconDrawable adaptive = (AdaptiveIconDrawable) drawable;
            int inset = Math.round(ICON_SIZE * 0.16f);
            Drawable bg = adaptive.getBackground();
            Drawable fg = adaptive.getForeground();
            if (bg != null || fg != null) {
                if (bg != null) {
                    bg.setBounds(-inset, -inset, ICON_SIZE + inset, ICON_SIZE + inset);
                    bg.draw(canvas);
                }
                if (fg != null) {
                    fg.setBounds(-inset, -inset, ICON_SIZE + inset, ICON_SIZE + inset);
                    fg.draw(canvas);
                }
            } else {
                drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
                drawable.draw(canvas);
            }
        } else {
            drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
            drawable.draw(canvas);
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
    }
}
