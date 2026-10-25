package local.androiduse.probe;

import android.app.Activity;
import android.content.Intent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.text.InputType;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Local synthetic input only. No network, editor dumps, or real account data. */
public final class InteractionActivity extends Activity {
    private EditText first, second;

    @Override public void onCreate(Bundle saved) { super.onCreate(saved); nativeInputs(); }

    private LinearLayout layout(String title) {
        LinearLayout body = new LinearLayout(this); body.setOrientation(LinearLayout.VERTICAL);
        int p = (int) (18 * getResources().getDisplayMetrics().density);
        body.setPadding(p, p, p, p);
        TextView caption = new TextView(this); caption.setText(title); caption.setTextSize(20);
        body.addView(caption); setContentView(body); return body;
    }

    private void nativeInputs() {
        LinearLayout body = layout("本地双输入框验证 · 合成测试数据");
        first = editor("输入框 A", "fieldA"); second = editor("输入框 B", "fieldB");
        body.addView(first); body.addView(second);
        final String sentinel = "android-use-local-test-sentinel";
        ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        LinearLayout checks = new LinearLayout(this);
        TextView clipboardStatus = new TextView(this); clipboardStatus.setText("仅合成数据：设哨兵 → 输入 → 检查");
        Button seed = new Button(this); seed.setText("设剪贴板哨兵");
        seed.setOnClickListener(v -> { clipboard.setPrimaryClip(ClipData.newPlainText("Local test", sentinel)); clipboardStatus.setText("哨兵已设置"); });
        Button check = new Button(this); check.setText("检查剪贴板");
        check.setOnClickListener(v -> {
            ClipData data = clipboard.getPrimaryClip();
            CharSequence value = data != null && data.getItemCount() > 0 ? data.getItemAt(0).getText() : null;
            clipboardStatus.setText(sentinel.equals(value == null ? null : value.toString()) ? "剪贴板保持哨兵 ✓" : "剪贴板已改变");
        });
        checks.addView(seed, new LinearLayout.LayoutParams(0, -2, 1)); checks.addView(check, new LinearLayout.LayoutParams(0, -2, 1));
        body.addView(checks); body.addView(clipboardStatus);
        Button picker = new Button(this); picker.setText("打开系统文件选择器（返回取消）");
        picker.setOnClickListener(v -> startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE).setType("text/plain"), 1));
        body.addView(picker);
        Button web = new Button(this); web.setText("本地网页双输入框"); web.setOnClickListener(v -> webInputs()); body.addView(web);
        Button back = new Button(this); back.setText("返回性能场景"); back.setOnClickListener(v -> finish()); body.addView(back);
    }

    private EditText editor(String hint, String key) {
        EditText edit = new EditText(this); edit.setHint(hint); edit.setContentDescription(hint);
        edit.setInputType(InputType.TYPE_CLASS_TEXT); edit.setSingleLine(true);
        edit.setText(getPreferences(MODE_PRIVATE).getString(key, ""));
        return edit;
    }

    private void saveSyntheticInputs() {
        if (first != null && second != null) getPreferences(MODE_PRIVATE).edit()
            .putString("fieldA", first.getText().toString()).putString("fieldB", second.getText().toString()).apply();
    }
    @Override public void onPause() { saveSyntheticInputs(); super.onPause(); }

    private void webInputs() {
        saveSyntheticInputs();
        LinearLayout body = layout("本地网页输入验证 · 无网络内容");
        Button back = new Button(this); back.setText("返回原生双输入框"); back.setOnClickListener(v -> nativeInputs()); body.addView(back);
        WebView web = new WebView(this);
        body.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
        web.loadDataWithBaseURL(null,
            "<!doctype html><html><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'>"
            + "<body style='font:20px sans-serif'><p>只输入固定测试文字</p>"
            + "<input aria-label='网页输入框 A' placeholder='网页输入框 A' style='font:20px sans-serif;width:90%;margin:18px 0'>"
            + "<input aria-label='网页输入框 B' placeholder='网页输入框 B' style='font:20px sans-serif;width:90%;margin:18px 0'>"
            + "</body></html>", "text/html", "UTF-8", null);
    }
}
