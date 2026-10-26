/*
 * Copyright (C) 2023 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by Macdora for desktop ActivityEmbedding split-pane ratio,
 * WeChat tablet magic-window state, and full-height draggable divider support.
 */
package androidx.window.extensions.embedding;

import android.R;
import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.app.ActivityThread;
import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.RotateDrawable;
import android.hardware.display.DisplayManager;
import android.os.IBinder;
import android.util.TypedValue;
import android.view.MotionEvent;
import android.view.SurfaceControl;
import android.view.SurfaceControlViewHost;
import android.view.VelocityTracker;
import android.view.View;
import android.view.WindowManager;
import android.view.WindowlessWindowManager;
import android.view.animation.PathInterpolator;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.window.InputTransferToken;
import android.window.TaskFragmentOperation;
import android.window.TaskFragmentParentInfo;
import android.window.WindowContainerTransaction;
import androidx.window.common.layout.CommonFoldingFeature;
import androidx.window.extensions.core.util.function.Consumer;
import com.android.internal.hidden_from_bootclasspath.com.android.window.flags.Flags;
import java.util.Objects;
import java.util.concurrent.Executor;

class DividerPresenter implements View.OnTouchListener {
    static final int DEFAULT_DIVIDER_WIDTH_DP = 24;
    static final float DEFAULT_MAX_RATIO = 0.65f;
    static final float DEFAULT_MIN_RATIO = 0.35f;
    private static final int DIVIDER_LAYER = 1;
    static final int FLING_ANIMATION_DURATION = 250;
    static final int MIN_DISMISS_VELOCITY_DP_PER_SECOND = 600;
    static final int MIN_FLING_VELOCITY_DP_PER_SECOND = 400;
    private static final int VEIL_LAYER = 0;
    private static final String WINDOW_NAME = "AE Divider";
    private final Executor mCallbackExecutor;
    IBinder mDecorSurfaceOwner;
    private int mDividerPosition;
    private final DragEventCallback mDragEventCallback;
    Properties mProperties;
    Renderer mRenderer;
    private final int mTaskId;
    VelocityTracker mVelocityTracker;
    private static final Color DEFAULT_PRIMARY_VEIL_COLOR = Color.valueOf(-16777216);
    private static final Color DEFAULT_SECONDARY_VEIL_COLOR = Color.valueOf(-7829368);
    static final float RATIO_EXPANDED_SECONDARY = 0.0f;
    static final float RATIO_EXPANDED_PRIMARY = 1.0f;
    static final PathInterpolator FLING_ANIMATION_INTERPOLATOR = new PathInterpolator(0.4f, RATIO_EXPANDED_SECONDARY, 0.2f, RATIO_EXPANDED_PRIMARY);
    private final Object mLock = new Object();
    private boolean mHasContainersToFinish = false;

    interface DragEventCallback {
        void onFinishDragging(int i, Consumer<WindowContainerTransaction> consumer);

        void onStartDragging(Consumer<WindowContainerTransaction> consumer);
    }

    DividerPresenter(int taskId, DragEventCallback dragEventCallback, Executor callbackExecutor) {
        this.mTaskId = taskId;
        this.mDragEventCallback = dragEventCallback;
        this.mCallbackExecutor = callbackExecutor;
    }

    void updateDivider(WindowContainerTransaction wct, TaskFragmentParentInfo parentInfo, SplitContainer topSplitContainer, boolean isTaskFragmentVanished) {
        if (!Flags.activityEmbeddingInteractiveDividerFlag()) {
            return;
        }
        synchronized (this.mLock) {
            try {
                if (topSplitContainer == null) {
                    if (this.mHasContainersToFinish) {
                        if (!isTaskFragmentVanished) {
                            return;
                        } else {
                            setHasContainersToFinish(false);
                        }
                    }
                    removeDecorSurfaceAndDivider(wct);
                    return;
                }
                SplitAttributes splitAttributes = topSplitContainer.getCurrentSplitAttributes();
                DividerAttributes dividerAttributes = splitAttributes.getDividerAttributes();
                if (dividerAttributes == null) {
                    removeDecorSurfaceAndDivider(wct);
                    return;
                }
                TaskFragmentContainer primaryContainer = topSplitContainer.getPrimaryContainer();
                TaskFragmentContainer secondaryContainer = topSplitContainer.getSecondaryContainer();
                SurfaceControl decorSurface = parentInfo.getDecorSurface();
                if (decorSurface == null) {
                    removeDivider();
                    createOrMoveDecorSurfaceLocked(wct, primaryContainer);
                    return;
                }
                boolean isDraggableExpandType = SplitAttributesHelper.isDraggableExpandType(splitAttributes);
                TaskFragmentContainer decorSurfaceOwnerContainer = isDraggableExpandType ? secondaryContainer : primaryContainer;
                if (!Objects.equals(this.mDecorSurfaceOwner, decorSurfaceOwnerContainer.getTaskFragmentToken())) {
                    createOrMoveDecorSurfaceLocked(wct, decorSurfaceOwnerContainer);
                }
                Configuration parentConfiguration = parentInfo.getConfiguration();
                Rect taskBounds = parentConfiguration.windowConfiguration.getBounds();
                boolean isVerticalSplit = isVerticalSplit(splitAttributes);
                boolean isReversedLayout = SplitAttributesHelper.isReversedLayout(splitAttributes, parentConfiguration);
                int dividerWidthPx = getDividerWidthPx(dividerAttributes);
                updateProperties(new Properties(parentConfiguration, dividerAttributes, decorSurface, getInitialDividerPosition(primaryContainer, secondaryContainer, taskBounds, dividerWidthPx, isDraggableExpandType, isVerticalSplit, isReversedLayout), isVerticalSplit, isReversedLayout, parentInfo.getDisplayId(), isDraggableExpandType, primaryContainer, secondaryContainer));
            } catch (Throwable th) {
                throw th;
            }
        }
    }

    private void updateProperties(Properties properties) {
        if (Properties.equalsForDivider(this.mProperties, properties)) {
            return;
        }
        Properties previousProperties = this.mProperties;
        this.mProperties = properties;
        if (this.mRenderer == null) {
            this.mRenderer = new Renderer(this.mProperties, this);
        } else if (!Properties.areSameSurfaces(previousProperties.mDecorSurface, this.mProperties.mDecorSurface) || previousProperties.mDisplayId != this.mProperties.mDisplayId) {
            this.mRenderer.release();
            this.mRenderer = new Renderer(this.mProperties, this);
        } else {
            this.mRenderer.update(this.mProperties);
        }
    }

    static Color getContainerBackgroundColor(TaskFragmentContainer container, Color defaultColor) {
        Activity activity = container.getTopNonFinishingActivity();
        if (activity == null) {
            return defaultColor;
        }
        Drawable drawable = activity.getWindow().getDecorView().getBackground();
        if (drawable instanceof ColorDrawable) {
            ColorDrawable colorDrawable = (ColorDrawable) drawable;
            return Color.valueOf(colorDrawable.getColor());
        }
        return defaultColor;
    }

    void createOrMoveDecorSurface(WindowContainerTransaction wct, TaskFragmentContainer container) {
        synchronized (this.mLock) {
            createOrMoveDecorSurfaceLocked(wct, container);
        }
    }

    private void createOrMoveDecorSurfaceLocked(WindowContainerTransaction wct, TaskFragmentContainer container) {
        this.mDecorSurfaceOwner = container.getTaskFragmentToken();
        TaskFragmentOperation operation = new TaskFragmentOperation.Builder(12).build();
        wct.addTaskFragmentOperation(this.mDecorSurfaceOwner, operation);
    }

    private void removeDecorSurfaceAndDivider(WindowContainerTransaction wct) {
        if (this.mDecorSurfaceOwner != null) {
            TaskFragmentOperation operation = new TaskFragmentOperation.Builder(13).build();
            wct.addTaskFragmentOperation(this.mDecorSurfaceOwner, operation);
            this.mDecorSurfaceOwner = null;
        }
        removeDivider();
    }

    private void removeDivider() {
        if (this.mRenderer != null) {
            this.mRenderer.release();
        }
        this.mProperties = null;
        this.mRenderer = null;
    }

    static int getInitialDividerPosition(TaskFragmentContainer primaryContainer, TaskFragmentContainer secondaryContainer, Rect taskBounds, int dividerWidthPx, boolean isDraggableExpandType, boolean isVerticalSplit, boolean isReversedLayout) {
        int fullyExpandedPosition;
        if (isDraggableExpandType) {
            if (isVerticalSplit) {
                fullyExpandedPosition = taskBounds.width() - dividerWidthPx;
            } else {
                fullyExpandedPosition = taskBounds.height() - dividerWidthPx;
            }
            if (isReversedLayout) {
                return fullyExpandedPosition;
            }
            return 0;
        }
        Rect primaryBounds = primaryContainer.getLastRequestedBounds();
        Rect secondaryBounds = secondaryContainer.getLastRequestedBounds();
        if (isVerticalSplit) {
            return Math.min(primaryBounds.right, secondaryBounds.right);
        }
        return Math.min(primaryBounds.bottom, secondaryBounds.bottom);
    }

    private static boolean isVerticalSplit(SplitAttributes splitAttributes) {
        int layoutDirection = splitAttributes.getLayoutDirection();
        switch (layoutDirection) {
            case 0:
            case 1:
            case 3:
                return true;
            case 2:
            default:
                throw new IllegalArgumentException("Invalid layout direction:" + layoutDirection);
            case SplitAttributes.LayoutDirection.TOP_TO_BOTTOM /* 4 */:
            case SplitAttributes.LayoutDirection.BOTTOM_TO_TOP /* 5 */:
                return false;
        }
    }

    /* JADX INFO: Access modifiers changed from: private */
    public static int getDividerWidthPx(DividerAttributes dividerAttributes) {
        int dividerWidthDp = dividerAttributes.getWidthDp();
        return convertDpToPixel(dividerWidthDp);
    }

    private static int convertDpToPixel(int dp) {
        Context applicationContext = ActivityThread.currentActivityThread().getApplication();
        return (int) TypedValue.applyDimension(1, dp, applicationContext.getResources().getDisplayMetrics());
    }

    private static float getDisplayDensity() {
        Context applicationContext = ActivityThread.currentActivityThread().getApplication();
        return applicationContext.getResources().getDisplayMetrics().density;
    }

    static int getBoundsOffsetForDivider(SplitAttributes splitAttributes, int position) {
        DividerAttributes dividerAttributes;
        if (!Flags.activityEmbeddingInteractiveDividerFlag() || (dividerAttributes = splitAttributes.getDividerAttributes()) == null) {
            return 0;
        }
        int dividerWidthPx = getDividerWidthPx(dividerAttributes);
        return getBoundsOffsetForDivider(dividerWidthPx, splitAttributes.getSplitType(), position);
    }

    static int getBoundsOffsetForDivider(int dividerWidthPx, SplitAttributes.SplitType splitType, int position) {
        int primaryOffset;
        if (splitType instanceof SplitAttributes.SplitType.ExpandContainersSplitType) {
            return 0;
        }
        if (splitType instanceof SplitAttributes.SplitType.RatioSplitType) {
            SplitAttributes.SplitType.RatioSplitType splitRatio = (SplitAttributes.SplitType.RatioSplitType) splitType;
            primaryOffset = (int) (dividerWidthPx * splitRatio.getRatio());
        } else {
            primaryOffset = dividerWidthPx / 2;
        }
        int secondaryOffset = dividerWidthPx - primaryOffset;
        switch (position) {
            case 0:
            case 1:
                return -primaryOffset;
            case 2:
            case 3:
                return secondaryOffset;
            default:
                throw new IllegalArgumentException("Unknown position:" + position);
        }
    }

    static DividerAttributes sanitizeDividerAttributes(DividerAttributes dividerAttributes) {
        if (dividerAttributes == null) {
            return null;
        }
        int widthDp = dividerAttributes.getWidthDp();
        float minRatio = dividerAttributes.getPrimaryMinRatio();
        float maxRatio = dividerAttributes.getPrimaryMaxRatio();
        if (widthDp == -1) {
            widthDp = DEFAULT_DIVIDER_WIDTH_DP;
        }
        if (dividerAttributes.getDividerType() == 2) {
            if (minRatio == -1.0f) {
                minRatio = DEFAULT_MIN_RATIO;
            }
            if (maxRatio == -1.0f) {
                maxRatio = DEFAULT_MAX_RATIO;
            }
        }
        return new DividerAttributes.Builder(dividerAttributes).setWidthDp(widthDp).setPrimaryMinRatio(minRatio).setPrimaryMaxRatio(maxRatio).build();
    }

    @Override // android.view.View.OnTouchListener
    public boolean onTouch(View view, MotionEvent event) {
        synchronized (this.mLock) {
            if (this.mProperties != null && this.mRenderer != null) {
                Rect taskBounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
                this.mDividerPosition = calculateDividerPosition(event, taskBounds, this.mProperties.mDividerWidthPx, this.mProperties.mDividerAttributes, this.mProperties.mIsVerticalSplit, calculateMinPosition(), calculateMaxPosition());
                this.mRenderer.setDividerPosition(this.mDividerPosition);
                event.setLocation(event.getRawX(), event.getRawY());
                int action = event.getAction() & 255;
                switch (action) {
                    case 0:
                        onStartDragging(event);
                        break;
                    case 1:
                    case 3:
                        onFinishDragging(event);
                        break;
                    case 2:
                        onDrag(event);
                        break;
                }
            }
            return true;
        }
    }

    private void onStartDragging(MotionEvent event) {
        this.mVelocityTracker = VelocityTracker.obtain();
        this.mVelocityTracker.addMovement(event);
        this.mRenderer.mIsDragging = true;
        this.mRenderer.mDragHandle.setPressed(this.mRenderer.mIsDragging);
        this.mRenderer.updateSurface();
        final SurfaceControl.Transaction t = new SurfaceControl.Transaction();
        this.mRenderer.showVeils(t);
        this.mCallbackExecutor.execute(new Runnable() { // from class: androidx.window.extensions.embedding.DividerPresenter$$ExternalSyntheticLambda1
            @Override // java.lang.Runnable
            public final void run() {
                DividerPresenter.this.lambda$onStartDragging$1(t);
            }
        });
    }

    /* JADX INFO: Access modifiers changed from: private */
    public /* synthetic */ void lambda$onStartDragging$1(final SurfaceControl.Transaction t) {
        this.mDragEventCallback.onStartDragging(new Consumer() { // from class: androidx.window.extensions.embedding.DividerPresenter$$ExternalSyntheticLambda2
            @Override // androidx.window.extensions.core.util.function.Consumer
            public final void accept(Object obj) {
                DividerPresenter.this.lambda$onStartDragging$0(t, (WindowContainerTransaction) obj);
            }
        });
    }

    /* JADX INFO: Access modifiers changed from: private */
    public /* synthetic */ void lambda$onStartDragging$0(SurfaceControl.Transaction t, WindowContainerTransaction wct) {
        synchronized (this.mLock) {
            setDecorSurfaceBoosted(wct, this.mDecorSurfaceOwner, true, t);
        }
    }

    private void onDrag(MotionEvent event) {
        if (this.mVelocityTracker != null) {
            this.mVelocityTracker.addMovement(event);
        }
        this.mRenderer.updateSurface();
    }

    private void onFinishDragging(MotionEvent event) {
        float yVelocity;
        float velocity = RATIO_EXPANDED_SECONDARY;
        if (this.mVelocityTracker != null) {
            this.mVelocityTracker.addMovement(event);
            this.mVelocityTracker.computeCurrentVelocity(CommonFoldingFeature.COMMON_STATE_USE_BASE_STATE);
            boolean z = this.mProperties.mIsVerticalSplit;
            VelocityTracker velocityTracker = this.mVelocityTracker;
            if (z) {
                yVelocity = velocityTracker.getXVelocity();
            } else {
                yVelocity = velocityTracker.getYVelocity();
            }
            velocity = yVelocity;
            this.mVelocityTracker.recycle();
        }
        int prevDividerPosition = this.mDividerPosition;
        this.mDividerPosition = dividerPositionForSnapPoints(this.mDividerPosition, velocity);
        if (this.mDividerPosition != prevDividerPosition) {
            ValueAnimator animator = getFlingAnimator(prevDividerPosition, this.mDividerPosition);
            animator.start();
        } else {
            onDraggingEnd();
        }
    }

    ValueAnimator getFlingAnimator(int prevDividerPosition, int snappedDividerPosition) {
        ValueAnimator animator = getValueAnimator(prevDividerPosition, snappedDividerPosition);
        animator.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() { // from class: androidx.window.extensions.embedding.DividerPresenter$$ExternalSyntheticLambda4
            @Override // android.animation.ValueAnimator.AnimatorUpdateListener
            public final void onAnimationUpdate(ValueAnimator valueAnimator) {
                DividerPresenter.this.lambda$getFlingAnimator$2(valueAnimator);
            }
        });
        animator.addListener(new AnimatorListenerAdapter() { // from class: androidx.window.extensions.embedding.DividerPresenter.1
            @Override // android.animation.AnimatorListenerAdapter, android.animation.Animator.AnimatorListener
            public void onAnimationEnd(Animator animation) {
                synchronized (DividerPresenter.this.mLock) {
                    DividerPresenter.this.onDraggingEnd();
                }
            }

            @Override // android.animation.AnimatorListenerAdapter, android.animation.Animator.AnimatorListener
            public void onAnimationCancel(Animator animation) {
                synchronized (DividerPresenter.this.mLock) {
                    DividerPresenter.this.onDraggingEnd();
                }
            }
        });
        return animator;
    }

    /* JADX INFO: Access modifiers changed from: private */
    public /* synthetic */ void lambda$getFlingAnimator$2(ValueAnimator animation) {
        synchronized (this.mLock) {
            updateDividerPosition(((Integer) animation.getAnimatedValue()).intValue());
        }
    }

    static ValueAnimator getValueAnimator(int prevDividerPosition, int snappedDividerPosition) {
        ValueAnimator animator = ValueAnimator.ofInt(prevDividerPosition, snappedDividerPosition).setDuration(250L);
        animator.setInterpolator(FLING_ANIMATION_INTERPOLATOR);
        return animator;
    }

    private void updateDividerPosition(int position) {
        if (this.mRenderer != null) {
            this.mRenderer.setDividerPosition(position);
            this.mRenderer.updateSurface();
        }
    }

    /* JADX INFO: Access modifiers changed from: private */
    public void onDraggingEnd() {
        final SurfaceControl.Transaction t = new SurfaceControl.Transaction();
        if (this.mRenderer != null) {
            this.mRenderer.hideVeils(t);
        }
        this.mCallbackExecutor.execute(new Runnable() { // from class: androidx.window.extensions.embedding.DividerPresenter$$ExternalSyntheticLambda0
            @Override // java.lang.Runnable
            public final void run() {
                DividerPresenter.this.lambda$onDraggingEnd$4(t);
            }
        });
        if (this.mRenderer != null) {
            this.mRenderer.mIsDragging = false;
            this.mRenderer.mDragHandle.setPressed(this.mRenderer.mIsDragging);
        }
    }

    /* JADX INFO: Access modifiers changed from: private */
    public /* synthetic */ void lambda$onDraggingEnd$4(final SurfaceControl.Transaction t) {
        this.mDragEventCallback.onFinishDragging(this.mTaskId, new Consumer() { // from class: androidx.window.extensions.embedding.DividerPresenter$$ExternalSyntheticLambda3
            @Override // androidx.window.extensions.core.util.function.Consumer
            public final void accept(Object obj) {
                DividerPresenter.this.lambda$onDraggingEnd$3(t, (WindowContainerTransaction) obj);
            }
        });
    }

    /* JADX INFO: Access modifiers changed from: private */
    public /* synthetic */ void lambda$onDraggingEnd$3(SurfaceControl.Transaction t, WindowContainerTransaction wct) {
        synchronized (this.mLock) {
            setDecorSurfaceBoosted(wct, this.mDecorSurfaceOwner, false, t);
        }
    }

    private int dividerPositionForSnapPoints(int dividerPosition, float velocity) {
        int fullyExpandedPosition;
        Rect taskBounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
        int minPosition = calculateMinPosition();
        int maxPosition = calculateMaxPosition();
        if (this.mProperties.mIsVerticalSplit) {
            fullyExpandedPosition = taskBounds.width() - this.mProperties.mDividerWidthPx;
        } else {
            fullyExpandedPosition = taskBounds.height() - this.mProperties.mDividerWidthPx;
        }
        float displayDensity = getDisplayDensity();
        boolean isDraggingToFullscreenAllowed = isDraggingToFullscreenAllowed(this.mProperties.mDividerAttributes);
        return dividerPositionWithPositionOptions(dividerPosition, minPosition, maxPosition, fullyExpandedPosition, velocity, displayDensity, isDraggingToFullscreenAllowed);
    }

    static int dividerPositionWithPositionOptions(int dividerPosition, int minPosition, int maxPosition, int fullyExpandedPosition, float velocity, float displayDensity, boolean isDraggingToFullscreenAllowed) {
        int[] iArr;
        if (isDraggingToFullscreenAllowed) {
            float minDismissVelocityPxPerSecond = 600.0f * displayDensity;
            if (dividerPosition < minPosition && velocity < (-minDismissVelocityPxPerSecond)) {
                return 0;
            }
            if (dividerPosition > maxPosition && velocity > minDismissVelocityPxPerSecond) {
                return fullyExpandedPosition;
            }
        }
        float minFlingVelocityPxPerSecond = 400.0f * displayDensity;
        if (Math.abs(velocity) >= minFlingVelocityPxPerSecond) {
            return dividerPositionForFling(dividerPosition, minPosition, maxPosition, velocity);
        }
        if (dividerPosition >= minPosition && dividerPosition <= maxPosition) {
            return dividerPosition;
        }
        if (isDraggingToFullscreenAllowed) {
            iArr = new int[]{0, minPosition, maxPosition, fullyExpandedPosition};
        } else {
            iArr = new int[]{minPosition, maxPosition};
        }
        return snap(dividerPosition, iArr);
    }

    private static int dividerPositionForFling(int dividerPosition, int minPosition, int maxPosition, float velocity) {
        boolean isBackwardDirection = velocity < RATIO_EXPANDED_SECONDARY;
        if (isBackwardDirection) {
            return dividerPosition < maxPosition ? minPosition : maxPosition;
        }
        return dividerPosition > minPosition ? maxPosition : minPosition;
    }

    private static int snap(int dividerPosition, int[] possiblePositions) {
        int snappedPosition = dividerPosition;
        float minDistance = Float.MAX_VALUE;
        for (int position : possiblePositions) {
            float distance = Math.abs(dividerPosition - position);
            if (distance < minDistance) {
                snappedPosition = position;
                minDistance = distance;
            }
        }
        return snappedPosition;
    }

    private static void setDecorSurfaceBoosted(WindowContainerTransaction wct, IBinder decorSurfaceOwner, boolean boosted, SurfaceControl.Transaction clientTransaction) {
        if (decorSurfaceOwner == null) {
            return;
        }
        wct.addTaskFragmentOperation(decorSurfaceOwner, new TaskFragmentOperation.Builder(15).setBooleanValue(boosted).setSurfaceTransaction(clientTransaction).build());
    }

    static int calculateDividerPosition(MotionEvent event, Rect taskBounds, int dividerWidthPx, DividerAttributes dividerAttributes, boolean isVerticalSplit, int minPosition, int maxPosition) {
        int touchPositionInTaskSpace;
        if (isVerticalSplit) {
            touchPositionInTaskSpace = ((int) event.getRawX()) - taskBounds.left;
        } else {
            touchPositionInTaskSpace = ((int) event.getRawY()) - taskBounds.top;
        }
        int dividerPosition = touchPositionInTaskSpace - (dividerWidthPx / 2);
        if (!isDraggingToFullscreenAllowed(dividerAttributes)) {
            return Math.clamp(dividerPosition, minPosition, maxPosition);
        }
        return dividerPosition;
    }

    private int calculateMinPosition() {
        return calculateMinPosition(this.mProperties.mConfiguration.windowConfiguration.getBounds(), this.mProperties.mDividerWidthPx, this.mProperties.mDividerAttributes, this.mProperties.mIsVerticalSplit, this.mProperties.mIsReversedLayout);
    }

    private int calculateMaxPosition() {
        return calculateMaxPosition(this.mProperties.mConfiguration.windowConfiguration.getBounds(), this.mProperties.mDividerWidthPx, this.mProperties.mDividerAttributes, this.mProperties.mIsVerticalSplit, this.mProperties.mIsReversedLayout);
    }

    static int calculateMinPosition(Rect taskBounds, int dividerWidthPx, DividerAttributes dividerAttributes, boolean isVerticalSplit, boolean isReversedLayout) {
        int usableSize;
        float primaryMinRatio;
        if (isVerticalSplit) {
            usableSize = taskBounds.width() - dividerWidthPx;
        } else {
            usableSize = taskBounds.height() - dividerWidthPx;
        }
        if (isReversedLayout) {
            primaryMinRatio = usableSize - (usableSize * dividerAttributes.getPrimaryMaxRatio());
        } else {
            primaryMinRatio = usableSize * dividerAttributes.getPrimaryMinRatio();
        }
        return (int) primaryMinRatio;
    }

    static int calculateMaxPosition(Rect taskBounds, int dividerWidthPx, DividerAttributes dividerAttributes, boolean isVerticalSplit, boolean isReversedLayout) {
        int usableSize;
        float primaryMaxRatio;
        if (isVerticalSplit) {
            usableSize = taskBounds.width() - dividerWidthPx;
        } else {
            usableSize = taskBounds.height() - dividerWidthPx;
        }
        if (isReversedLayout) {
            primaryMaxRatio = usableSize - (usableSize * dividerAttributes.getPrimaryMinRatio());
        } else {
            primaryMaxRatio = usableSize * dividerAttributes.getPrimaryMaxRatio();
        }
        return (int) primaryMaxRatio;
    }

    float calculateNewSplitRatio() {
        float fCalculateNewSplitRatio;
        synchronized (this.mLock) {
            fCalculateNewSplitRatio = calculateNewSplitRatio(this.mDividerPosition, this.mProperties.mConfiguration.windowConfiguration.getBounds(), this.mProperties.mDividerWidthPx, this.mProperties.mIsVerticalSplit, this.mProperties.mIsReversedLayout, calculateMinPosition(), calculateMaxPosition(), isDraggingToFullscreenAllowed(this.mProperties.mDividerAttributes));
        }
        return fCalculateNewSplitRatio;
    }

    void setHasContainersToFinish(boolean hasContainersToFinish) {
        synchronized (this.mLock) {
            this.mHasContainersToFinish = hasContainersToFinish;
        }
    }

    private static boolean isDraggingToFullscreenAllowed(DividerAttributes dividerAttributes) {
        return dividerAttributes.isDraggingToFullscreenAllowed();
    }

    static float calculateNewSplitRatio(int dividerPosition, Rect taskBounds, int dividerWidthPx, boolean isVerticalSplit, boolean isReversedLayout, int minPosition, int maxPosition, boolean isDraggingToFullscreenAllowed) {
        int usableSize;
        int newPrimaryHeight;
        int newPrimaryWidth;
        if (!isDraggingToFullscreenAllowed) {
            dividerPosition = Math.clamp(dividerPosition, minPosition, maxPosition);
        } else {
            if (dividerPosition < minPosition) {
                if (isReversedLayout) {
                    return RATIO_EXPANDED_PRIMARY;
                }
                return RATIO_EXPANDED_SECONDARY;
            }
            if (dividerPosition > maxPosition) {
                if (!isReversedLayout) {
                    return RATIO_EXPANDED_PRIMARY;
                }
                return RATIO_EXPANDED_SECONDARY;
            }
        }
        if (isVerticalSplit) {
            usableSize = taskBounds.width() - dividerWidthPx;
        } else {
            usableSize = taskBounds.height() - dividerWidthPx;
        }
        if (isVerticalSplit) {
            if (isReversedLayout) {
                newPrimaryWidth = taskBounds.width() - (dividerPosition + dividerWidthPx);
            } else {
                newPrimaryWidth = dividerPosition;
            }
            float newRatio = (newPrimaryWidth * RATIO_EXPANDED_PRIMARY) / usableSize;
            return newRatio;
        }
        if (isReversedLayout) {
            newPrimaryHeight = taskBounds.height() - (dividerPosition + dividerWidthPx);
        } else {
            newPrimaryHeight = dividerPosition;
        }
        float newRatio2 = (newPrimaryHeight * RATIO_EXPANDED_PRIMARY) / usableSize;
        return newRatio2;
    }

    static class Properties {
        private static final int CONFIGURATION_MASK_FOR_DIVIDER = 536883200;
        private final Configuration mConfiguration;
        private final SurfaceControl mDecorSurface;
        private final int mDisplayId;
        private final DividerAttributes mDividerAttributes;
        private final int mDividerWidthPx;
        private final int mInitialDividerPosition;
        private final boolean mIsDraggableExpandType;
        private final boolean mIsReversedLayout;
        private final boolean mIsVerticalSplit;
        private final TaskFragmentContainer mPrimaryContainer;
        private final TaskFragmentContainer mSecondaryContainer;

        Properties(Configuration configuration, DividerAttributes dividerAttributes, SurfaceControl decorSurface, int initialDividerPosition, boolean isVerticalSplit, boolean isReversedLayout, int displayId, boolean isDraggableExpandType, TaskFragmentContainer primaryContainer, TaskFragmentContainer secondaryContainer) {
            this.mConfiguration = configuration;
            this.mDividerAttributes = dividerAttributes;
            this.mDecorSurface = decorSurface;
            this.mInitialDividerPosition = initialDividerPosition;
            this.mIsVerticalSplit = isVerticalSplit;
            this.mIsReversedLayout = isReversedLayout;
            this.mDisplayId = displayId;
            this.mIsDraggableExpandType = isDraggableExpandType;
            this.mPrimaryContainer = primaryContainer;
            this.mSecondaryContainer = secondaryContainer;
            this.mDividerWidthPx = DividerPresenter.getDividerWidthPx(dividerAttributes);
        }

        /* JADX INFO: Access modifiers changed from: private */
        public static boolean equalsForDivider(Properties a, Properties b) {
            if (a == b) {
                return true;
            }
            if (a == null || b == null) {
                return false;
            }
            if (areSameSurfaces(a.mDecorSurface, b.mDecorSurface) && Objects.equals(a.mDividerAttributes, b.mDividerAttributes) && areConfigurationsEqualForDivider(a.mConfiguration, b.mConfiguration) && a.mInitialDividerPosition == b.mInitialDividerPosition && a.mIsVerticalSplit == b.mIsVerticalSplit && a.mDisplayId == b.mDisplayId && a.mIsReversedLayout == b.mIsReversedLayout && a.mIsDraggableExpandType == b.mIsDraggableExpandType && a.mPrimaryContainer == b.mPrimaryContainer && a.mSecondaryContainer == b.mSecondaryContainer) {
                return true;
            }
            return false;
        }

        /* JADX INFO: Access modifiers changed from: private */
        public static boolean areSameSurfaces(SurfaceControl sc1, SurfaceControl sc2) {
            if (sc1 == sc2) {
                return true;
            }
            if (sc1 == null || sc2 == null) {
                return false;
            }
            return sc1.isSameSurface(sc2);
        }

        private static boolean areConfigurationsEqualForDivider(Configuration a, Configuration b) {
            int diff = a.diff(b);
            return (CONFIGURATION_MASK_FOR_DIVIDER & diff) == 0;
        }
    }

    static class Renderer {
        private final FrameLayout mDividerLayout;
        private final SurfaceControl mDividerLineSurface;
        private int mDividerPosition;
        private final SurfaceControl mDividerSurface;
        private int mDividerSurfaceWidthPx;
        private View mDragHandle;
        private int mHandleWidthPx;
        private boolean mIsDragging;
        private final View.OnTouchListener mListener;
        private SurfaceControl mPrimaryVeil;
        private Properties mProperties;
        private SurfaceControl mSecondaryVeil;
        private final SurfaceControlViewHost mViewHost;
        private final WindowlessWindowManager mWindowlessWindowManager;

        private Renderer(Properties properties, View.OnTouchListener listener) {
            this.mProperties = properties;
            this.mListener = listener;
            this.mDividerSurface = createChildSurface(this.mProperties.mDecorSurface, "DividerSurface", true);
            this.mDividerLineSurface = createChildSurface(this.mDividerSurface, "DividerLineSurface", true);
            this.mWindowlessWindowManager = new WindowlessWindowManager(this.mProperties.mConfiguration, this.mDividerSurface, new InputTransferToken());
            Context context = ActivityThread.currentActivityThread().getApplication();
            DisplayManager displayManager = (DisplayManager) context.getSystemService(DisplayManager.class);
            this.mViewHost = new SurfaceControlViewHost(context, displayManager.getDisplay(this.mProperties.mDisplayId), this.mWindowlessWindowManager, "DividerContainer");
            this.mDividerLayout = new FrameLayout(context);
            update();
        }

        /* JADX INFO: Access modifiers changed from: private */
        public void update(Properties newProperties) {
            this.mProperties = newProperties;
            update();
        }

        void update() {
            this.mDividerPosition = this.mProperties.mInitialDividerPosition;
            this.mWindowlessWindowManager.setConfiguration(this.mProperties.mConfiguration);
            if (this.mProperties.mDividerAttributes.getDividerType() == 2) {
                Context context = ActivityThread.currentActivityThread().getApplication();
                this.mHandleWidthPx = Math.max(16, (int) (context.getResources().getDisplayMetrics().density * 12.0f));
            } else {
                this.mHandleWidthPx = 0;
            }
            SurfaceControl.Transaction t = new SurfaceControl.Transaction();
            updateSurface(t);
            updateLayout();
            updateDivider(t);
            t.apply();
        }

        void release() {
            this.mViewHost.release();
            SurfaceControl.Transaction t = new SurfaceControl.Transaction();
            t.remove(this.mDividerSurface);
            removeVeils(t);
            t.apply();
        }

        /* JADX INFO: Access modifiers changed from: private */
        public void setDividerPosition(int dividerPosition) {
            this.mDividerPosition = dividerPosition;
        }

        /* JADX INFO: Access modifiers changed from: private */
        public void updateSurface() {
            SurfaceControl.Transaction t = new SurfaceControl.Transaction();
            updateSurface(t);
            t.apply();
        }

        private void updateSurface(SurfaceControl.Transaction t) {
            int dividerSurfacePosition;
            int iHeight;
            Rect taskBounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
            int dividerType = this.mProperties.mDividerAttributes.getDividerType();
            Properties properties = this.mProperties;
            boolean isDividerLineVisible = false;
            if (dividerType == 2) {
                this.mDividerSurfaceWidthPx = Math.max(properties.mDividerWidthPx, this.mHandleWidthPx);
                int dividerSurfacePosition2 = this.mDividerPosition - ((this.mDividerSurfaceWidthPx - this.mProperties.mDividerWidthPx) / 2);
                long j = dividerSurfacePosition2;
                if (this.mProperties.mIsVerticalSplit) {
                    iHeight = taskBounds.width() - this.mDividerSurfaceWidthPx;
                } else {
                    iHeight = taskBounds.height() - this.mDividerSurfaceWidthPx;
                }
                dividerSurfacePosition = Math.clamp(j, 0, iHeight);
            } else {
                int dividerSurfacePosition3 = properties.mDividerWidthPx;
                this.mDividerSurfaceWidthPx = dividerSurfacePosition3;
                dividerSurfacePosition = this.mDividerPosition;
            }
            boolean z2 = this.mProperties.mIsVerticalSplit;
            SurfaceControl surfaceControl = this.mDividerSurface;
            if (z2) {
                t.setPosition(surfaceControl, dividerSurfacePosition, DividerPresenter.RATIO_EXPANDED_SECONDARY);
                t.setWindowCrop(this.mDividerSurface, this.mDividerSurfaceWidthPx, taskBounds.height());
            } else {
                t.setPosition(surfaceControl, DividerPresenter.RATIO_EXPANDED_SECONDARY, dividerSurfacePosition);
                t.setWindowCrop(this.mDividerSurface, taskBounds.width(), this.mDividerSurfaceWidthPx);
            }
            int offset = this.mDividerPosition - dividerSurfacePosition;
            boolean z3 = this.mProperties.mIsVerticalSplit;
            SurfaceControl surfaceControl2 = this.mDividerLineSurface;
            if (z3) {
                t.setPosition(surfaceControl2, offset, DividerPresenter.RATIO_EXPANDED_SECONDARY);
                t.setWindowCrop(this.mDividerLineSurface, this.mProperties.mDividerWidthPx, taskBounds.height());
            } else {
                t.setPosition(surfaceControl2, DividerPresenter.RATIO_EXPANDED_SECONDARY, offset);
                t.setWindowCrop(this.mDividerLineSurface, taskBounds.width(), this.mProperties.mDividerWidthPx);
            }
            if (this.mProperties.mDividerWidthPx > 0 && (!this.mProperties.mIsDraggableExpandType || this.mIsDragging)) {
                isDividerLineVisible = true;
            }
            t.setVisibility(this.mDividerLineSurface, isDividerLineVisible);
            t.setColor(this.mDividerLineSurface, colorToFloatArray(Color.valueOf(this.mProperties.mDividerAttributes.getDividerColor())));
            if (this.mIsDragging) {
                updateVeils(t);
            }
        }

        private void updateLayout() {
            WindowManager.LayoutParams lp;
            Rect taskBounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
            if (this.mProperties.mIsVerticalSplit) {
                lp = new WindowManager.LayoutParams(this.mDividerSurfaceWidthPx, taskBounds.height(), 1002, 536870952, -3);
            } else {
                lp = new WindowManager.LayoutParams(taskBounds.width(), this.mDividerSurfaceWidthPx, 1002, 536870952, -3);
            }
            lp.setTitle(DividerPresenter.WINDOW_NAME);
            this.mDividerLayout.setLayoutDirection(0);
            this.mViewHost.setView(this.mDividerLayout, lp);
            this.mViewHost.relayout(lp);
        }

        private void updateDivider(SurfaceControl.Transaction t) {
            this.mDividerLayout.removeAllViews();
            if (this.mProperties.mDividerAttributes.getDividerType() == 2) {
                createVeils();
                drawDragHandle();
            } else {
                removeVeils(t);
            }
            this.mViewHost.getView().invalidate();
        }

        private void drawDragHandle() {
            FrameLayout.LayoutParams params;
            Context context = this.mDividerLayout.getContext();
            ImageButton button = new ImageButton(context);
            if (this.mProperties.mIsVerticalSplit) {
                params = new FrameLayout.LayoutParams(context.getResources().getDimensionPixelSize(0x01050051), context.getResources().getDimensionPixelSize(0x01050050));
            } else {
                params = new FrameLayout.LayoutParams(context.getResources().getDimensionPixelSize(0x01050050), context.getResources().getDimensionPixelSize(0x01050051));
            }
            params.gravity = 17;
            button.setLayoutParams(params);
            button.setBackgroundColor(0);
            button.setContentDescription(context.getString(0x01040134));
            Drawable handle = context.getResources().getDrawable(0x0108014c, context.getTheme());
            if (this.mProperties.mIsVerticalSplit) {
                button.setImageDrawable(handle);
            } else {
                RotateDrawable rotatedHandle = new RotateDrawable();
                rotatedHandle.setFromDegrees(90.0f);
                rotatedHandle.setToDegrees(90.0f);
                rotatedHandle.setPivotXRelative(true);
                rotatedHandle.setPivotYRelative(true);
                rotatedHandle.setPivotX(0.5f);
                rotatedHandle.setPivotY(0.5f);
                rotatedHandle.setLevel(1);
                rotatedHandle.setDrawable(handle);
                button.setImageDrawable(rotatedHandle);
            }
            button.setOnTouchListener(this.mListener);
            this.mDividerLayout.setOnTouchListener(this.mListener);
            this.mDragHandle = button;
            this.mDividerLayout.addView(button);
        }

        private SurfaceControl createChildSurface(SurfaceControl parent, String name, boolean visible) {
            Rect bounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
            return new SurfaceControl.Builder().setParent(parent).setName(name).setHidden(!visible).setCallsite("DividerManager.createChildSurface").setBufferSize(bounds.width(), bounds.height()).setEffectLayer().build();
        }

        private void createVeils() {
            if (this.mPrimaryVeil == null) {
                this.mPrimaryVeil = createChildSurface(this.mProperties.mDecorSurface, "DividerPrimaryVeil", false);
            }
            if (this.mSecondaryVeil == null) {
                this.mSecondaryVeil = createChildSurface(this.mProperties.mDecorSurface, "DividerSecondaryVeil", false);
            }
        }

        private void removeVeils(SurfaceControl.Transaction t) {
            if (this.mPrimaryVeil != null) {
                t.remove(this.mPrimaryVeil);
            }
            if (this.mSecondaryVeil != null) {
                t.remove(this.mSecondaryVeil);
            }
            this.mPrimaryVeil = null;
            this.mSecondaryVeil = null;
        }

        /* JADX INFO: Access modifiers changed from: private */
        public void showVeils(SurfaceControl.Transaction t) {
            Color primaryVeilColor = getVeilColor(this.mProperties.mDividerAttributes.getPrimaryVeilColor(), this.mProperties.mPrimaryContainer, DividerPresenter.DEFAULT_PRIMARY_VEIL_COLOR);
            Color secondaryVeilColor = getVeilColor(this.mProperties.mDividerAttributes.getSecondaryVeilColor(), this.mProperties.mSecondaryContainer, DividerPresenter.DEFAULT_SECONDARY_VEIL_COLOR);
            t.setColor(this.mPrimaryVeil, colorToFloatArray(primaryVeilColor)).setColor(this.mSecondaryVeil, colorToFloatArray(secondaryVeilColor)).setLayer(this.mDividerSurface, 1).setLayer(this.mPrimaryVeil, 0).setLayer(this.mSecondaryVeil, 0).setVisibility(this.mPrimaryVeil, true).setVisibility(this.mSecondaryVeil, true);
            updateVeils(t);
        }

        /* JADX INFO: Access modifiers changed from: private */
        public void hideVeils(SurfaceControl.Transaction t) {
            t.setVisibility(this.mPrimaryVeil, false).setVisibility(this.mSecondaryVeil, false);
        }

        private void updateVeils(SurfaceControl.Transaction t) {
            Rect primaryBounds;
            Rect secondaryBounds;
            Rect taskBounds = this.mProperties.mConfiguration.windowConfiguration.getBounds();
            if (this.mProperties.mIsVerticalSplit) {
                Rect boundsLeft = new Rect(0, 0, this.mDividerPosition, taskBounds.height());
                Rect boundsRight = new Rect(this.mDividerPosition + this.mProperties.mDividerWidthPx, 0, taskBounds.width(), taskBounds.height());
                primaryBounds = this.mProperties.mIsReversedLayout ? boundsRight : boundsLeft;
                secondaryBounds = this.mProperties.mIsReversedLayout ? boundsLeft : boundsRight;
            } else {
                Rect boundsTop = new Rect(0, 0, taskBounds.width(), this.mDividerPosition);
                Rect boundsBottom = new Rect(0, this.mDividerPosition + this.mProperties.mDividerWidthPx, taskBounds.width(), taskBounds.height());
                primaryBounds = this.mProperties.mIsReversedLayout ? boundsBottom : boundsTop;
                secondaryBounds = this.mProperties.mIsReversedLayout ? boundsTop : boundsBottom;
            }
            if (this.mPrimaryVeil != null) {
                t.setWindowCrop(this.mPrimaryVeil, primaryBounds.width(), primaryBounds.height());
                t.setPosition(this.mPrimaryVeil, primaryBounds.left, primaryBounds.top);
                t.setVisibility(this.mPrimaryVeil, !primaryBounds.isEmpty());
            }
            if (this.mSecondaryVeil != null) {
                t.setWindowCrop(this.mSecondaryVeil, secondaryBounds.width(), secondaryBounds.height());
                t.setPosition(this.mSecondaryVeil, secondaryBounds.left, secondaryBounds.top);
                t.setVisibility(this.mSecondaryVeil, !secondaryBounds.isEmpty());
            }
        }

        private static Color getVeilColor(int configuredColor, TaskFragmentContainer container, Color defaultColor) {
            if (configuredColor != 0) {
                return Color.valueOf(configuredColor);
            }
            return DividerPresenter.getContainerBackgroundColor(container, defaultColor);
        }

        private static float[] colorToFloatArray(Color color) {
            return new float[]{color.red(), color.green(), color.blue()};
        }
    }
}
