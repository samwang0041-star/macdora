package local.androiduse.probe;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.os.Bundle;
import android.view.Choreographer;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

public final class MainActivity extends Activity
        implements Choreographer.FrameCallback, View.OnClickListener {
    static final String ACTION_CAMERA = "local.androiduse.probe.CAMERA";

    private static final int MARKER_HEIGHT_PX = 96;
    private static final int ROW_COUNT = 240;
    private static final int SYSTEM_UI_HIDDEN = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            | View.SYSTEM_UI_FLAG_FULLSCREEN;

    private MarkerStripView markerView;
    private MotionSquareView motionView;
    private Button tapButton;
    private Choreographer choreographer;
    private boolean redirectedToCamera;
    private boolean frameLoopActive;
    private int tapCount;
    private int inputCounter;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (ACTION_CAMERA.equals(getIntent().getAction())) {
            redirectedToCamera = true;
            startActivity(new Intent(this, CameraProbeActivity.class));
            finish();
            return;
        }
        configureWindow();
        buildInterface();
        choreographer = Choreographer.getInstance();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (!redirectedToCamera) {
            startFrameLoop();
        }
    }

    @Override
    protected void onPause() {
        if (!redirectedToCamera) {
            stopFrameLoop();
        }
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && !redirectedToCamera) {
            hideSystemBars();
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        if (event.getAction() == MotionEvent.ACTION_DOWN) {
            inputCounter = (inputCounter + 1) & 0xffff;
            if (markerView != null) {
                markerView.setInputCounter(inputCounter);
                markerView.invalidate();
            }
        }
        return super.dispatchTouchEvent(event);
    }

    private void startFrameLoop() {
        if (!frameLoopActive) {
            frameLoopActive = true;
            choreographer.postFrameCallback(this);
        }
    }

    private void stopFrameLoop() {
        if (frameLoopActive) {
            frameLoopActive = false;
            choreographer.removeFrameCallback(this);
        }
    }

    private void configureWindow() {
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.BLACK);

        window.getDecorView().setFitsSystemWindows(false);
        hideSystemBars();
    }

    private void hideSystemBars() {
        getWindow().getDecorView().setSystemUiVisibility(SYSTEM_UI_HIDDEN);
    }

    private void buildInterface() {
        int horizontalPadding = dp(18);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(243, 239, 231));

        markerView = new MarkerStripView(this);
        markerView.setContentDescription(getString(R.string.marker_description));
        root.addView(markerView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, MARKER_HEIGHT_PX));

        LinearLayout body = new LinearLayout(this);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(horizontalPadding, dp(12), horizontalPadding, dp(12));
        root.addView(body, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        TextView eyebrow = new TextView(this);
        eyebrow.setText(R.string.eyebrow);
        eyebrow.setTextColor(Color.rgb(164, 70, 40));
        eyebrow.setTextSize(12);
        eyebrow.setTypeface(Typeface.DEFAULT_BOLD);
        eyebrow.setAllCaps(false);
        eyebrow.setLetterSpacing(0.08f);
        body.addView(eyebrow, matchWidthWrap());

        TextView title = new TextView(this);
        title.setText(R.string.title);
        title.setTextColor(Color.rgb(29, 44, 43));
        title.setTextSize(24);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        body.addView(title, matchWidthWrap());

        TextView description = new TextView(this);
        description.setText(R.string.description);
        description.setTextColor(Color.rgb(66, 77, 74));
        description.setTextSize(13);
        description.setLineSpacing(dp(2), 1.0f);
        LinearLayout.LayoutParams descriptionParams = matchWidthWrap();
        descriptionParams.topMargin = dp(4);
        body.addView(description, descriptionParams);

        EditText textInput = new EditText(this);
        textInput.setHint(R.string.edit_hint);
        textInput.setText(R.string.edit_initial);
        textInput.setTextSize(16);
        textInput.setSingleLine(false);
        textInput.setMinLines(2);
        textInput.setMaxLines(3);
        textInput.setGravity(Gravity.CENTER_VERTICAL);
        textInput.setPadding(dp(14), dp(10), dp(14), dp(10));
        LinearLayout.LayoutParams editParams = matchWidthWrap();
        editParams.topMargin = dp(10);
        body.addView(textInput, editParams);

        tapButton = new Button(this);
        updateTapButton();
        tapButton.setTextSize(18);
        tapButton.setAllCaps(false);
        tapButton.setGravity(Gravity.CENTER);
        tapButton.setOnClickListener(this);
        tapButton.setContentDescription("测试点击；长按打开双输入框、文件选择和本地网页验证");
        tapButton.setOnLongClickListener(view -> { startActivity(new Intent(this, InteractionActivity.class)); return true; });
        LinearLayout.LayoutParams buttonParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(62));
        buttonParams.topMargin = dp(10);
        body.addView(tapButton, buttonParams);

        TextView motionCaption = new TextView(this);
        motionCaption.setText(R.string.motion_caption);
        motionCaption.setTextColor(Color.rgb(66, 77, 74));
        motionCaption.setTextSize(12);
        motionCaption.setTypeface(Typeface.DEFAULT_BOLD);
        LinearLayout.LayoutParams motionCaptionParams = matchWidthWrap();
        motionCaptionParams.topMargin = dp(12);
        body.addView(motionCaption, motionCaptionParams);

        motionView = new MotionSquareView(this);
        motionView.setContentDescription(getString(R.string.motion_caption));
        LinearLayout.LayoutParams motionParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(82));
        motionParams.topMargin = dp(5);
        body.addView(motionView, motionParams);

        TextView listCaption = new TextView(this);
        listCaption.setText(getString(R.string.list_caption, ROW_COUNT));
        listCaption.setTextColor(Color.rgb(29, 44, 43));
        listCaption.setTextSize(13);
        listCaption.setTypeface(Typeface.DEFAULT_BOLD);
        LinearLayout.LayoutParams listCaptionParams = matchWidthWrap();
        listCaptionParams.topMargin = dp(12);
        body.addView(listCaption, listCaptionParams);

        ListView listView = new ListView(this);
        listView.setAdapter(new ProbeListAdapter(this, ROW_COUNT));
        listView.setDividerHeight(dp(1));
        listView.setDivider(createDivider());
        listView.setFastScrollEnabled(true);
        listView.setVerticalScrollBarEnabled(true);
        LinearLayout.LayoutParams listParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f);
        listParams.topMargin = dp(4);
        body.addView(listView, listParams);

        setContentView(root);
    }

    private void updateTapButton() {
        tapButton.setText(getString(R.string.tap_count, tapCount));
    }

    private android.graphics.drawable.ColorDrawable createDivider() {
        return new android.graphics.drawable.ColorDrawable(Color.rgb(214, 207, 194));
    }

    private LinearLayout.LayoutParams matchWidthWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void doFrame(long frameTimeNanos) {
        if (!frameLoopActive) {
            return;
        }

        markerView.advanceFrame();
        motionView.advanceFrame(frameTimeNanos);
        choreographer.postFrameCallback(this);
    }

    @Override
    public void onClick(View view) {
        tapCount++;
        updateTapButton();
    }

    private static final class MarkerStripView extends View {
        private static final int MARKER_BACKGROUND = Color.BLACK;
        private static final int CELL_SIZE = 24;
        private static final int FIRST_ROW_X = 16;
        private static final int FIRST_ROW_Y = 16;
        private static final int SECOND_ROW_Y = 48;

        private final Paint blockPaint = new Paint();
        private int frameCounter;
        private int inputCounter;

        MarkerStripView(Context context) {
            super(context);
            blockPaint.setStyle(Paint.Style.FILL);
            blockPaint.setAntiAlias(false);
            blockPaint.setDither(false);
            setBackgroundColor(MARKER_BACKGROUND);
        }

        void advanceFrame() {
            frameCounter++;
            invalidate();
        }

        void setInputCounter(int inputCounter) {
            this.inputCounter = inputCounter & 0xffff;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            canvas.drawColor(MARKER_BACKGROUND);
            drawCounterBits(canvas, frameCounter, 32, FIRST_ROW_Y);
            drawCounterBits(canvas, inputCounter, 16, SECOND_ROW_Y);
        }

        private void drawCounterBits(Canvas canvas, int value, int bitCount, int top) {
            for (int bit = 0; bit < bitCount; bit++) {
                boolean isSet = ((value >>> bit) & 1) != 0;
                blockPaint.setColor(isSet ? Color.WHITE : Color.BLACK);
                int left = FIRST_ROW_X + CELL_SIZE * bit;
                canvas.drawRect(
                        left,
                        top,
                        left + CELL_SIZE,
                        top + CELL_SIZE,
                        blockPaint);
            }
        }
    }

    private static final class MotionSquareView extends View {
        private static final int PANEL_COLOR = Color.rgb(27, 45, 44);
        private static final int GRID_COLOR = Color.rgb(48, 76, 72);
        private static final int SQUARE_COLOR = Color.rgb(224, 91, 47);

        private final Paint panelPaint = new Paint();
        private final Paint gridPaint = new Paint();
        private final Paint squarePaint = new Paint();
        private long frameTimeNanos;

        MotionSquareView(Context context) {
            super(context);
            panelPaint.setColor(PANEL_COLOR);
            panelPaint.setStyle(Paint.Style.FILL);
            panelPaint.setAntiAlias(false);
            gridPaint.setColor(GRID_COLOR);
            gridPaint.setStyle(Paint.Style.FILL);
            gridPaint.setAntiAlias(false);
            squarePaint.setColor(SQUARE_COLOR);
            squarePaint.setStyle(Paint.Style.FILL);
            squarePaint.setAntiAlias(false);
        }

        void advanceFrame(long frameTimeNanos) {
            this.frameTimeNanos = frameTimeNanos;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            canvas.drawRect(0, 0, getWidth(), getHeight(), panelPaint);

            int gridStep = Math.max(32, getWidth() / 12);
            for (int x = gridStep; x < getWidth(); x += gridStep) {
                canvas.drawRect(x, 0, x + 1, getHeight(), gridPaint);
            }

            int squareSize = Math.min(getWidth() / 7, getHeight() / 2);
            int travel = Math.max(1, getWidth() - squareSize);
            long phase = (frameTimeNanos / 8_000_000L) % (travel * 2L);
            int left = (int) (phase <= travel ? phase : travel * 2L - phase);
            int top = (getHeight() - squareSize) / 2;
            canvas.drawRect(left, top, left + squareSize, top + squareSize, squarePaint);
        }
    }

    private static final class ProbeListAdapter extends BaseAdapter {
        private final Context context;
        private final int rowCount;

        ProbeListAdapter(Context context, int rowCount) {
            this.context = context;
            this.rowCount = rowCount;
        }

        @Override
        public int getCount() {
            return rowCount;
        }

        @Override
        public Object getItem(int position) {
            return position;
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            RowHolder holder;
            if (convertView == null) {
                LinearLayout row = new LinearLayout(context);
                row.setOrientation(LinearLayout.VERTICAL);
                row.setPadding(dp(parent, 10), dp(parent, 7), dp(parent, 10), dp(parent, 7));

                TextView title = new TextView(context);
                title.setTextColor(Color.rgb(29, 44, 43));
                title.setTextSize(15);
                title.setTypeface(Typeface.DEFAULT_BOLD);
                row.addView(title);

                TextView subtitle = new TextView(context);
                subtitle.setTextColor(Color.rgb(91, 100, 96));
                subtitle.setTextSize(12);
                row.addView(subtitle);

                holder = new RowHolder(title, subtitle);
                row.setTag(holder);
                convertView = row;
            } else {
                holder = (RowHolder) convertView.getTag();
            }

            int displayNumber = position + 1;
            holder.title.setText(context.getString(R.string.row_title, displayNumber));
            holder.subtitle.setText(context.getString(R.string.row_subtitle, displayNumber));
            return convertView;
        }

        private static int dp(View parent, int value) {
            return Math.round(value * parent.getResources().getDisplayMetrics().density);
        }

        private static final class RowHolder {
            final TextView title;
            final TextView subtitle;

            RowHolder(TextView title, TextView subtitle) {
                this.title = title;
                this.subtitle = subtitle;
            }
        }
    }
}
