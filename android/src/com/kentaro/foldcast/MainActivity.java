package com.kentaro.foldcast;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import java.net.HttpURLConnection;
import java.net.URL;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;

/**
 * FoldCast viewer — whole Galaxy Z Fold screen as a Mac extended display.
 *
 * Connection is self-healing: it keeps a visible "waiting" screen and retries
 * every few seconds, so it does NOT matter what order you start things in or
 * whether the Mac's IP changes. Order of preference each attempt:
 *   discovered (Bonjour/mDNS)  >  saved/explicit URL  >  localhost (USB)
 */
public class MainActivity extends Activity {

    private static final String PREF = "foldcast";
    private static final String KEY_URL = "url";
    private static final String DEFAULT_URL = "http://localhost:8787/"; // USB
    private static final String SERVICE_TYPE = "_foldcast._tcp.";
    private static final int RETRY_MS = 3000;
    private static final int REDISCOVER_MS = 12000;

    private WebView web;
    private NsdManager nsd;
    private NsdManager.DiscoveryListener discoveryListener;
    private WifiManager.MulticastLock multicastLock;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private volatile String discoveredUrl;   // from mDNS
    private volatile boolean connected;       // a real page is showing
    private volatile boolean probing;
    private boolean resolving;
    private long lastDiscover;

    @Override
    protected void onCreate(Bundle s) {
        super.onCreate(s);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(Color.BLACK);
        getWindow().setNavigationBarColor(Color.BLACK);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        web = new WebView(this);
        WebSettings ws = web.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setMediaPlaybackRequiresUserGesture(false);
        ws.setUseWideViewPort(true);
        ws.setLoadWithOverviewMode(true);
        ws.setBuiltInZoomControls(false);
        ws.setDisplayZoomControls(false);
        ws.setSupportZoom(false);
        ws.setCacheMode(WebSettings.LOAD_NO_CACHE);
        web.setBackgroundColor(Color.BLACK);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.setVerticalScrollBarEnabled(false);
        web.setHorizontalScrollBarEnabled(false);
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, String u) {
                v.loadUrl(u); return true;
            }
            @Override public void onPageFinished(WebView v, String u) {
                if (u != null && u.startsWith("http")) connected = true;
            }
            @Override public void onReceivedError(WebView v, int code,
                    String desc, String failingUrl) {
                // Only react to the *main* page failing (the live server),
                // never to the data: waiting page.
                if (failingUrl != null && failingUrl.startsWith("http")) {
                    connected = false;
                    showWaiting();
                }
            }
        });

        root.addView(web, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);

        root.setOnTouchListener((v, e) -> {
            if (e.getPointerCount() >= 3
                    && e.getActionMasked()
                       == android.view.MotionEvent.ACTION_POINTER_DOWN) {
                promptUrl();
            }
            return false;
        });

        startDiscovery();
        showWaiting();             // visible spinner — stays until reachable
        ui.post(ticker);           // background probe loop (never blanks UI)
    }

    @Override
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        String u = intent != null ? intent.getStringExtra("url") : null;
        if (u != null && !u.isEmpty()) {
            String n = normalize(u);
            prefs().edit().putString(KEY_URL, n).apply();
            connected = false;
            if (web != null) web.loadUrl(n);
        }
    }

    // ---- self-healing retry -----------------------------------------------

    /** Candidate URLs, best first: mDNS-discovered, saved/explicit, USB. */
    private java.util.List<String> candidates() {
        java.util.ArrayList<String> c = new java.util.ArrayList<>();
        if (discoveredUrl != null) c.add(discoveredUrl);
        String saved = prefs().getString(KEY_URL, DEFAULT_URL);
        if (!c.contains(saved)) c.add(saved);
        if (!c.contains(DEFAULT_URL)) c.add(DEFAULT_URL);
        return c;
    }

    private String targetUrl() {
        java.util.List<String> c = candidates();
        return c.isEmpty() ? DEFAULT_URL : c.get(0);
    }

    /** Background reachability probe — never touches the WebView until a
     *  server actually answers, so the visible waiting screen never blanks. */
    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            if (web == null) return;
            if (!connected && !probing) {
                long now = System.currentTimeMillis();
                if (now - lastDiscover > REDISCOVER_MS) restartDiscovery();
                probing = true;
                new Thread(() -> {
                    String hit = null;
                    for (String base : candidates()) {
                        if (reachable(base)) { hit = base; break; }
                    }
                    final String found = hit;
                    ui.post(() -> {
                        probing = false;
                        if (found != null && !connected && web != null) {
                            prefs().edit().putString(KEY_URL, found).apply();
                            web.loadUrl(found);
                        }
                    });
                }).start();
            }
            ui.postDelayed(this, RETRY_MS);
        }
    };

    private boolean reachable(String base) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(base + "health").openConnection();
            c.setConnectTimeout(1500);
            c.setReadTimeout(1500);
            c.setRequestMethod("GET");
            int code = c.getResponseCode();
            return code >= 200 && code < 500;
        } catch (Exception e) {
            return false;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private void showWaiting() {
        if (web == null) return;
        String t = targetUrl();
        String html =
            "<!doctype html><html><head><meta name=viewport "
          + "content='width=device-width,initial-scale=1'>"
          + "<style>html,body{margin:0;height:100%;background:#0b0f1a;"
          + "color:#e8eefc;font-family:-apple-system,system-ui,sans-serif;"
          + "display:flex;align-items:center;justify-content:center}"
          + ".c{text-align:center;padding:24px}"
          + ".s{width:64px;height:64px;border:6px solid #1d2742;"
          + "border-top-color:#3FC8FF;border-radius:50%;margin:0 auto 28px;"
          + "animation:r 1s linear infinite}@keyframes r{to{transform:"
          + "rotate(360deg)}}h1{font-size:30px;margin:0 0 12px}"
          + "p{font-size:18px;color:#9fb0d0;margin:6px 0}"
          + "code{color:#3FC8FF;font-size:17px}</style></head><body><div class=c>"
          + "<div class=s></div>"
          + "<h1>FoldCast — Mac を探しています…</h1>"
          + "<p>Mac 側で <b>FoldCast.app</b> を起動してください。</p>"
          + "<p>起動すれば数秒で<b>自動接続</b>します（操作不要）。</p>"
          + "<p>接続先: <code>" + t + "</code></p>"
          + "<p style='margin-top:18px;color:#5f7099;font-size:14px'>"
          + "3本指タップで手動URL設定 / USBは adb reverse</p>"
          + "</div></body></html>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    // ---- Bonjour / mDNS ---------------------------------------------------

    private void startDiscovery() {
        try {
            WifiManager wifi = (WifiManager) getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wifi != null && multicastLock == null) {
                multicastLock = wifi.createMulticastLock("foldcast-mdns");
                multicastLock.setReferenceCounted(false);
            }
            if (multicastLock != null && !multicastLock.isHeld())
                multicastLock.acquire();
            nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
            discoveryListener = new NsdManager.DiscoveryListener() {
                public void onDiscoveryStarted(String t) {}
                public void onDiscoveryStopped(String t) {}
                public void onStartDiscoveryFailed(String t, int c) {}
                public void onStopDiscoveryFailed(String t, int c) {}
                public void onServiceLost(NsdServiceInfo i) {}
                public void onServiceFound(NsdServiceInfo info) {
                    String st = info.getServiceType();
                    if (st != null && st.contains("foldcast")) resolve(info);
                }
            };
            nsd.discoverServices(SERVICE_TYPE,
                    NsdManager.PROTOCOL_DNS_SD, discoveryListener);
            lastDiscover = System.currentTimeMillis();
        } catch (Exception ignored) {}
    }

    private void restartDiscovery() {
        lastDiscover = System.currentTimeMillis();
        try {
            if (nsd != null && discoveryListener != null)
                nsd.stopServiceDiscovery(discoveryListener);
        } catch (Exception ignored) {}
        ui.postDelayed(this::startDiscovery, 400);
    }

    private void resolve(NsdServiceInfo info) {
        if (resolving) return;
        resolving = true;
        try {
            nsd.resolveService(info, new NsdManager.ResolveListener() {
                public void onResolveFailed(NsdServiceInfo i, int c) {
                    resolving = false;
                }
                public void onServiceResolved(NsdServiceInfo i) {
                    resolving = false;
                    String host = (i.getHost() != null)
                            ? i.getHost().getHostAddress() : null;
                    if (host == null) return;
                    if (host.contains(":")) host = "[" + host + "]";
                    discoveredUrl = "http://" + host + ":" + i.getPort() + "/";
                    // The probe ticker picks this up on its next pass.
                }
            });
        } catch (Exception e) { resolving = false; }
    }

    // -----------------------------------------------------------------------

    private String normalize(String u) {
        u = u.trim();
        if (!u.startsWith("http")) u = "http://" + u;
        if (!u.endsWith("/")) u = u + "/";
        return u;
    }

    private SharedPreferences prefs() {
        return getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    private void promptUrl() {
        final EditText in = new EditText(this);
        in.setText(prefs().getString(KEY_URL, DEFAULT_URL));
        in.setTextColor(Color.WHITE);
        new AlertDialog.Builder(this)
            .setTitle("FoldCast server URL")
            .setView(in)
            .setPositiveButton("Connect", (d, w) -> {
                String u = normalize(in.getText().toString());
                prefs().edit().putString(KEY_URL, u).apply();
                discoveredUrl = null; connected = false;
                web.loadUrl(u);
            })
            .setNeutralButton("Auto (Bonjour)", (d, w) -> {
                discoveredUrl = null; connected = false; showWaiting();
            })
            .setNegativeButton("Cancel", null)
            .show();
    }

    @Override
    public void onWindowFocusChanged(boolean has) {
        super.onWindowFocusChanged(has);
        if (has) goImmersive();
    }

    private void goImmersive() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.statusBars()
                        | WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(WindowInsetsController
                        .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
            getWindow().setDecorFitsSystemWindows(false);
        } else {
            getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        }
    }

    @Override protected void onDestroy() {
        ui.removeCallbacksAndMessages(null);
        try { if (nsd != null && discoveryListener != null)
            nsd.stopServiceDiscovery(discoveryListener); } catch (Exception ignored) {}
        try { if (multicastLock != null && multicastLock.isHeld())
            multicastLock.release(); } catch (Exception ignored) {}
        if (web != null) { web.destroy(); web = null; }
        super.onDestroy();
    }
}
