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

import androidx.window.extensions.RequiresVendorApiLevel;
import java.util.Objects;

@RequiresVendorApiLevel(level = 2)
public class SplitAttributes {
    private final AnimationParams mAnimationParams;
    private final DividerAttributes mDividerAttributes;
    private final int mLayoutDirection;
    private final SplitType mSplitType;
    private final WindowAttributes mWindowAttributes;

    public static class SplitType {
        private final String mDescription;

        SplitType(String description) {
            this.mDescription = description;
        }

        public int hashCode() {
            return this.mDescription.hashCode();
        }

        public boolean equals(Object obj) {
            if (this == obj) {
                return true;
            }
            if (!(obj instanceof SplitType)) {
                return false;
            }
            SplitType that = (SplitType) obj;
            return this.mDescription.equals(that.mDescription);
        }

        public String toString() {
            return this.mDescription;
        }

        static SplitType createSplitTypeFromLegacySplitRatio(float splitRatio) {
            if (splitRatio == 0.0d || splitRatio == 1.0d) {
                return new ExpandContainersSplitType();
            }
            return new RatioSplitType(splitRatio);
        }

        public static final class RatioSplitType extends SplitType {
            private final float mRatio;

            public RatioSplitType(float ratio) {
                super("ratio:" + ratio);
                if (ratio <= 0.0f || ratio >= 1.0f) {
                    throw new IllegalArgumentException("Ratio must be in range (0.0, 1.0).  Use SplitType.ExpandContainersSplitType() instead of 0 or 1.");
                }
                this.mRatio = ratio;
            }

            public float getRatio() {
                return this.mRatio;
            }

            public static RatioSplitType splitEqually() {
                return new RatioSplitType(0.5f);
            }
        }

        public static final class HingeSplitType extends SplitType {
            private final SplitType mFallbackSplitType;

            public HingeSplitType(SplitType fallbackSplitType) {
                super("hinge, fallbackType=" + fallbackSplitType);
                this.mFallbackSplitType = fallbackSplitType;
            }

            public SplitType getFallbackSplitType() {
                return this.mFallbackSplitType;
            }
        }

        public static final class ExpandContainersSplitType extends SplitType {
            public ExpandContainersSplitType() {
                super("expandContainers");
            }
        }
    }

    public static final class LayoutDirection {
        public static final int BOTTOM_TO_TOP = 5;
        public static final int LEFT_TO_RIGHT = 0;
        public static final int LOCALE = 3;
        public static final int RIGHT_TO_LEFT = 1;
        public static final int TOP_TO_BOTTOM = 4;

        private LayoutDirection() {
        }
    }

    SplitAttributes(SplitType splitType, int layoutDirection, AnimationParams animationParams, WindowAttributes attributes, DividerAttributes dividerAttributes) {
        this.mSplitType = splitType;
        this.mLayoutDirection = layoutDirection;
        this.mAnimationParams = animationParams;
        this.mWindowAttributes = attributes;
        this.mDividerAttributes = dividerAttributes;
    }

    public int getLayoutDirection() {
        return this.mLayoutDirection;
    }

    public SplitType getSplitType() {
        return this.mSplitType;
    }

    @RequiresVendorApiLevel(deprecatedSince = 7, level = LayoutDirection.BOTTOM_TO_TOP)
    @Deprecated
    public AnimationBackground getAnimationBackground() {
        return this.mAnimationParams.getAnimationBackground();
    }

    @RequiresVendorApiLevel(level = 7)
    public AnimationParams getAnimationParams() {
        return this.mAnimationParams;
    }

    @RequiresVendorApiLevel(level = LayoutDirection.BOTTOM_TO_TOP)
    public WindowAttributes getWindowAttributes() {
        return this.mWindowAttributes;
    }

    @RequiresVendorApiLevel(level = 6)
    public DividerAttributes getDividerAttributes() {
        return this.mDividerAttributes;
    }

    public static final class Builder {
        private AnimationParams mAnimationParams;
        private DividerAttributes mDividerAttributes;
        private int mLayoutDirection;
        private SplitType mSplitType;
        private WindowAttributes mWindowAttributes;

        public Builder() {
            this.mSplitType = new SplitType.RatioSplitType(0.5f);
            this.mLayoutDirection = 3;
            this.mAnimationParams = new AnimationParams.Builder().build();
            this.mWindowAttributes = new WindowAttributes(2);
        }

        @RequiresVendorApiLevel(level = 6)
        public Builder(SplitAttributes original) {
            this.mSplitType = new SplitType.RatioSplitType(0.5f);
            this.mLayoutDirection = 3;
            this.mAnimationParams = new AnimationParams.Builder().build();
            this.mWindowAttributes = new WindowAttributes(2);
            this.mSplitType = original.mSplitType;
            this.mLayoutDirection = original.mLayoutDirection;
            this.mAnimationParams = original.mAnimationParams;
            this.mWindowAttributes = original.mWindowAttributes;
            this.mDividerAttributes = original.mDividerAttributes;
        }

        public Builder setSplitType(SplitType splitType) {
            this.mSplitType = splitType;
            return this;
        }

        public Builder setLayoutDirection(int layoutDirection) {
            this.mLayoutDirection = layoutDirection;
            return this;
        }

        @RequiresVendorApiLevel(deprecatedSince = 7, level = LayoutDirection.BOTTOM_TO_TOP)
        @Deprecated
        public Builder setAnimationBackground(AnimationBackground background) {
            this.mAnimationParams = new AnimationParams.Builder().setAnimationBackground(background).build();
            return this;
        }

        @RequiresVendorApiLevel(level = 7)
        public Builder setAnimationParams(AnimationParams params) {
            this.mAnimationParams = params;
            return this;
        }

        @RequiresVendorApiLevel(level = LayoutDirection.BOTTOM_TO_TOP)
        public Builder setWindowAttributes(WindowAttributes attributes) {
            this.mWindowAttributes = attributes;
            return this;
        }

        @RequiresVendorApiLevel(level = 6)
        public Builder setDividerAttributes(DividerAttributes dividerAttributes) {
            this.mDividerAttributes = dividerAttributes;
            return this;
        }

        public SplitAttributes build() {
            if (this.mSplitType instanceof SplitType.RatioSplitType) {
                try {
                    android.app.Application app = android.app.ActivityThread.currentApplication();
                    if (app != null && "com.tencent.mm".equals(app.getPackageName())) {
                        SplitType.RatioSplitType rt = (SplitType.RatioSplitType) this.mSplitType;
                        if (Math.abs(rt.getRatio() - 0.5f) < 0.01f) {
                            this.mSplitType = new SplitType.RatioSplitType(0.35f);
                        }
                        Class<?> okCls = Class.forName("com.tencent.mm.ui.ok", false, app.getClassLoader());
                        java.lang.reflect.Field fField = okCls.getDeclaredField("f");
                        fField.setAccessible(true);
                        fField.set(null, Boolean.TRUE);
                    }
                } catch (Throwable ignored) {
                }
                if (this.mDividerAttributes == null) {
                    this.mDividerAttributes = new DividerAttributes.Builder(DividerAttributes.DIVIDER_TYPE_DRAGGABLE)
                        .setWidthDp(1)
                        .setPrimaryMinRatio(0.25f)
                        .setPrimaryMaxRatio(0.65f)
                        .setDividerColor(0xFFE5E5E5)
                        .build();
                }
            }
            return new SplitAttributes(this.mSplitType, this.mLayoutDirection, this.mAnimationParams, this.mWindowAttributes, this.mDividerAttributes);
        }
    }

    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (!(o instanceof SplitAttributes)) {
            return false;
        }
        SplitAttributes that = (SplitAttributes) o;
        return this.mLayoutDirection == that.mLayoutDirection && this.mSplitType.equals(that.mSplitType) && Objects.equals(this.mAnimationParams, that.mAnimationParams) && this.mWindowAttributes.equals(that.mWindowAttributes) && Objects.equals(this.mDividerAttributes, that.mDividerAttributes);
    }

    public int hashCode() {
        return Objects.hash(Integer.valueOf(this.mLayoutDirection), this.mSplitType, this.mAnimationParams, this.mWindowAttributes, this.mDividerAttributes);
    }

    public String toString() {
        return SplitAttributes.class.getSimpleName() + "{layoutDir=" + layoutDirectionToString() + ", splitType=" + this.mSplitType + ", animationParams=" + this.mAnimationParams + ", windowAttributes=" + this.mWindowAttributes + ", dividerAttributes=" + this.mDividerAttributes + "}";
    }

    private String layoutDirectionToString() {
        switch (this.mLayoutDirection) {
            case 0:
                return "LEFT_TO_RIGHT";
            case 1:
                return "RIGHT_TO_LEFT";
            case 2:
            default:
                throw new IllegalArgumentException("Invalid layout direction:" + this.mLayoutDirection);
            case 3:
                return "LOCALE";
            case LayoutDirection.TOP_TO_BOTTOM /* 4 */:
                return "TOP_TO_BOTTOM";
            case LayoutDirection.BOTTOM_TO_TOP /* 5 */:
                return "BOTTOM_TO_TOP";
        }
    }
}
