package local.androiduse.plugin.gnss;

import android.app.Service;
import android.content.Intent;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

public final class GnssKeepWarmService extends Service {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final LocationListener listener = new NoOpLocationListener();

    @Override
    public void onCreate() {
        super.onCreate();
        main.post(this::rebindGpsProvider);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && "STOP".equals(intent.getAction())) {
            unbindGpsProvider();
            stopSelf();
            return START_NOT_STICKY;
        }
        main.post(this::rebindGpsProvider);
        return START_STICKY;
    }

    private void rebindGpsProvider() {
        LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
        if (lm == null) return;
        try {
            lm.removeUpdates(listener);
        } catch (Throwable ignored) {}
        try {
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                lm.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    50L,
                    0.0f,
                    listener,
                    Looper.getMainLooper()
                );
            }
        } catch (Throwable ignored) {}
    }

    private void unbindGpsProvider() {
        LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
        if (lm != null) {
            try {
                lm.removeUpdates(listener);
            } catch (Throwable ignored) {}
        }
    }

    @Override
    public void onDestroy() {
        unbindGpsProvider();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private static final class NoOpLocationListener implements LocationListener {
        @Override public void onLocationChanged(Location location) {}
        @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
        @Override public void onProviderEnabled(String provider) {}
        @Override public void onProviderDisabled(String provider) {}
    }
}
