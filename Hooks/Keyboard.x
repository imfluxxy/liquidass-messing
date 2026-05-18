#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static void *kKeyboardTintKey = &kKeyboardTintKey;
static void *kKeyboardBlurViewKey = &kKeyboardBlurViewKey;
static void *kKeyboardBorderLayerKey = &kKeyboardBorderLayerKey;
static void *kKeyboardMaterialStatesKey = &kKeyboardMaterialStatesKey;
static void *kKeyboardOriginalBackgroundKey = &kKeyboardOriginalBackgroundKey;
static void *kKeyboardOriginalCornerRadiusKey = &kKeyboardOriginalCornerRadiusKey;
static void *kKeyboardOriginalClipsKey = &kKeyboardOriginalClipsKey;

static const NSInteger kKeyboardTintTag = 0xA1FE;

LG_ENABLED_BOOL_PREF_FUNC(LGKeyboardEnabled, "Keyboard.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGKeyboardTransparency, "Keyboard.Transparency", 0.85)
LG_FLOAT_PREF_FUNC(LGKeyboardTopCornerRadius, "Keyboard.TopCornerRadius", 28.0)
LG_FLOAT_PREF_FUNC(LGKeyboardButtonCornerRadius, "Keyboard.ButtonCornerRadius", 8.0)
LG_FLOAT_PREF_FUNC(LGKeyboardBorderFadeDistance, "Keyboard.BorderFadeDistance", 40.0)
LG_FLOAT_PREF_FUNC(LGKeyboardBorderAlpha, "Keyboard.BorderAlpha", 0.4)
LG_FLOAT_PREF_FUNC(LGKeyboardLightTintAlpha, "Keyboard.LightTintAlpha", 0.15)
LG_FLOAT_PREF_FUNC(LGKeyboardDarkTintAlpha, "Keyboard.DarkTintAlpha", 0.08)
LG_FLOAT_PREF_FUNC(LGKeyboardEmojiCornerRadius, "Keyboard.EmojiCornerRadius", 28.0)

static BOOL LGIsKeyboardView(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass(view.class);
    if (!className) return NO;
    if ([className isEqualToString:@"UIKeyboardImpl"]) return YES;
    if ([className isEqualToString:@"UIKeyboard"]) return YES;
    return NO;
}

static BOOL LGIsEmojiSearchBar(UIView *view) {
    if (!view) return NO;
    NSString *className = NSStringFromClass(view.class);
    if ([className containsString:@"UISearchBar"]) return YES;
    if ([className isEqualToString:@"UITextField"]) {
        UIView *parent = view.superview;
        while (parent) {
            NSString *parentClass = NSStringFromClass(parent.class);
            if ([parentClass containsString:@"Emoji"]) return YES;
            parent = parent.superview;
        }
    }
    return NO;
}

static UIColor *LGKeyboardTintColor(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGKeyboardLightTintAlpha(), LGKeyboardDarkTintAlpha(), @"Keyboard.TintOverrideMode");
}

static void LGHideKeyboardBackgroundMaterials(UIView *view) {
    NSMutableArray *hiddenViews = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        NSString *className = NSStringFromClass(subview.class);
        if ([className containsString:@"MTMaterialView"] ||
            [className containsString:@"_UIVisualEffectBackdropView"] ||
            [className containsString:@"_UIReplicantView"]) {
            [hiddenViews addObject:subview];
            subview.hidden = YES;
            subview.alpha = 0.0;
        }
        if (subview.subviews.count > 0) {
            LGHideKeyboardBackgroundMaterials(subview);
        }
    }
    if (hiddenViews.count > 0) {
        objc_setAssociatedObject(view, kKeyboardMaterialStatesKey, hiddenViews, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGRestoreKeyboardBackgroundMaterials(UIView *view) {
    NSArray *hiddenViews = objc_getAssociatedObject(view, kKeyboardMaterialStatesKey);
    for (UIView *subview in hiddenViews) {
        if (!subview) continue;
        subview.hidden = NO;
        subview.alpha = 1.0;
    }
    objc_setAssociatedObject(view, kKeyboardMaterialStatesKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGKeyboardRememberOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kKeyboardOriginalBackgroundKey)) {
        objc_setAssociatedObject(view, kKeyboardOriginalBackgroundKey, view.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(view, kKeyboardOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(view, kKeyboardOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(view, kKeyboardOriginalClipsKey)) {
        objc_setAssociatedObject(view, kKeyboardOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LGKeyboardRestoreOriginalState(UIView *view) {
    UIColor *bgColor = objc_getAssociatedObject(view, kKeyboardOriginalBackgroundKey);
    if (bgColor) view.backgroundColor = bgColor;

    NSNumber *cornerRadius = objc_getAssociatedObject(view, kKeyboardOriginalCornerRadiusKey);
    if (cornerRadius) view.layer.cornerRadius = [cornerRadius doubleValue];

    NSNumber *clips = objc_getAssociatedObject(view, kKeyboardOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
}

static void LGRemoveKeyboardGlass(UIView *view) {
    LGRemoveAssociatedSubview(view, kKeyboardTintKey);

    UIView *blurView = objc_getAssociatedObject(view, kKeyboardBlurViewKey);
    if (blurView) [blurView removeFromSuperview];
    objc_setAssociatedObject(view, kKeyboardBlurViewKey, nil, OBJC_ASSOCIATION_ASSIGN);

    CALayer *border = objc_getAssociatedObject(view, kKeyboardBorderLayerKey);
    if (border) [border removeFromSuperlayer];
    objc_setAssociatedObject(view, kKeyboardBorderLayerKey, nil, OBJC_ASSOCIATION_ASSIGN);

    LGRestoreKeyboardBackgroundMaterials(view);
}

static void LGKeyboardAddTopBorder(UIView *host) {
    CALayer *existingBorder = objc_getAssociatedObject(host, kKeyboardBorderLayerKey);
    if (existingBorder) [existingBorder removeFromSuperlayer];

    CGFloat borderHeight = LGKeyboardBorderFadeDistance();
    CAGradientLayer *gradientLayer = [CAGradientLayer layer];
    gradientLayer.startPoint = CGPointMake(0.5, 0.0);
    gradientLayer.endPoint = CGPointMake(0.5, 1.0);

    UIColor *tintColor = LGKeyboardTintColor(host);
    UIColor *borderColor = [tintColor colorWithAlphaComponent:LGKeyboardBorderAlpha()];

    gradientLayer.colors = @[
        (id)borderColor.CGColor,
        (id)[borderColor colorWithAlphaComponent:0.0].CGColor
    ];
    gradientLayer.locations = @[@0.0, @1.0];
    gradientLayer.frame = CGRectMake(0, 0, CGRectGetWidth(host.bounds), borderHeight);
    gradientLayer.zPosition = 100;

    [host.layer addSublayer:gradientLayer];
    objc_setAssociatedObject(host, kKeyboardBorderLayerKey, gradientLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGKeyboardPrepareHost(UIView *host) {
    LGKeyboardRememberOriginalState(host);

    host.backgroundColor = [UIColor clearColor];
    host.layer.backgroundColor = nil;

    host.alpha = LGKeyboardTransparency();
    host.layer.cornerRadius = LGKeyboardTopCornerRadius();
    if (@available(iOS 13.0, *)) {
        host.layer.cornerCurve = kCACornerCurveContinuous;
    }
    host.clipsToBounds = YES;
}

static void LGKeyboardEnsureBlurEffect(UIView *host) {
    UIVisualEffectView *blurView = objc_getAssociatedObject(host, kKeyboardBlurViewKey);
    if (!blurView) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.frame = host.bounds;
        blurView.userInteractionEnabled = NO;
        [host insertSubview:blurView atIndex:0];
        objc_setAssociatedObject(host, kKeyboardBlurViewKey, blurView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blurView.frame = host.bounds;
}

static void LGKeyboardEnsureTintOverlay(UIView *host) {
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kKeyboardTintKey,
                                           kKeyboardTintTag,
                                           host.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               LGKeyboardTintColor(host),
                               LGKeyboardTopCornerRadius(),
                               host.layer,
                               YES);
    [host bringSubviewToFront:tint];
}

static void LGKeyboardStyleButtons(UIView *host) {
    for (UIView *subview in host.subviews) {
        NSString *className = NSStringFromClass(subview.class);

        if ([subview isKindOfClass:[UIVisualEffectView class]]) continue;

        if ([className containsString:@"Key"] || [className isEqualToString:@"UIButton"]) {
            subview.layer.shadowOpacity = 0.0;
            subview.layer.cornerRadius = LGKeyboardButtonCornerRadius();
            if (@available(iOS 13.0, *)) {
                subview.layer.cornerCurve = kCACornerCurveContinuous;
            }
        }

        if (subview.subviews.count > 0) {
            LGKeyboardStyleButtons(subview);
        }
    }
}

static void LGKeyboardStyleEmojiSearchBar(UIView *host) {
    for (UIView *subview in host.subviews) {
        if ([subview isKindOfClass:[UIVisualEffectView class]]) continue;
        if (LGIsEmojiSearchBar(subview)) {
            subview.layer.cornerRadius = LGKeyboardEmojiCornerRadius();
            if (@available(iOS 13.0, *)) {
                subview.layer.cornerCurve = kCACornerCurveContinuous;
            }
            subview.clipsToBounds = YES;
        }

        if (subview.subviews.count > 0) {
            LGKeyboardStyleEmojiSearchBar(subview);
        }
    }
}

static void LGKeyboardInject(UIView *host) {
    CFTimeInterval profileStart = LGProfileBegin();

    if (!LGIsKeyboardView(host)) {
        LGProfileEnd(@"keyboard.inject", profileStart);
        return;
    }

    if (!host.window || !LGKeyboardEnabled()) {
        LGRemoveKeyboardGlass(host);
        LGKeyboardRestoreOriginalState(host);
        LGProfileEnd(@"keyboard.inject", profileStart);
        return;
    }

    LGHideKeyboardBackgroundMaterials(host);
    LGKeyboardPrepareHost(host);
    LGKeyboardEnsureBlurEffect(host);
    LGKeyboardEnsureTintOverlay(host);
    LGKeyboardAddTopBorder(host);
    LGKeyboardStyleButtons(host);
    LGKeyboardStyleEmojiSearchBar(host);

    LGProfileEnd(@"keyboard.inject", profileStart);
}

%group LGKeyboardHook

%hook UIKeyboardImpl

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (LGIsKeyboardView(self_)) {
        LGKeyboardInject(self_);
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (LGIsKeyboardView(self_)) {
        LGKeyboardInject(self_);
        CALayer *border = objc_getAssociatedObject(self_, kKeyboardBorderLayerKey);
        if (border) {
            CGFloat borderHeight = LGKeyboardBorderFadeDistance();
            border.frame = CGRectMake(0, 0, CGRectGetWidth(self_.bounds), borderHeight);
        }
    }
}

%end

%end

static void LGKeyboardRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGTraverseViews(window, ^(UIView *view) {
                    if (LGIsKeyboardView(view)) {
                        LGKeyboardInject(view);
                    }
                });
            }
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) {
            LGTraverseViews(window, ^(UIView *view) {
                if (LGIsKeyboardView(view)) {
                    LGKeyboardInject(view);
                }
            });
        }
    }
}

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGKeyboardRefreshAllHosts();
    });
    %init(LGKeyboardHook);
}

