#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kWidgetTintTag       = 0x71D0;

static void LGWidgetsRefreshAllHosts(void);
static void LGWidgetsRefreshAttachedHosts(void);
static BOOL LGIsWidgetGlassHostView(UIView *view);
static void LGRestoreWidgetOriginalState(UIView *view);
static void *kWidgetAttachedKey = &kWidgetAttachedKey;
static void *kWidgetGlassKey = &kWidgetGlassKey;
static void *kWidgetTintKey = &kWidgetTintKey;
static void *kWidgetOriginalAlphaKey = &kWidgetOriginalAlphaKey;
static void *kWidgetOriginalCornerRadiusKey = &kWidgetOriginalCornerRadiusKey;
static void *kWidgetOriginalClipsKey = &kWidgetOriginalClipsKey;
static void *kWidgetOriginalMasksKey = &kWidgetOriginalMasksKey;
static void *kWidgetOriginalCornerCurveKey = &kWidgetOriginalCornerCurveKey;
static void *kWidgetMaterialOriginalHiddenKey = &kWidgetMaterialOriginalHiddenKey;
static void *kWidgetMaterialOriginalAlphaKey = &kWidgetMaterialOriginalAlphaKey;
static void *kWidgetMaterialOriginalLayerOpacityKey = &kWidgetMaterialOriginalLayerOpacityKey;
static void *kWidgetLastLiveCaptureTimeKey = &kWidgetLastLiveCaptureTimeKey;
static void *kWidgetBackdropViewKey = &kWidgetBackdropViewKey;

static LGDisplayLinkState sWidgetDisplayLinkState = {0};
static NSHashTable<UIView *> *sWidgetHosts = nil;

LG_ENABLED_BOOL_PREF_FUNC(LGWidgetEnabled, "Widgets.Enabled", NO)
static CGFloat LGWidgetCornerRadius(void) { return LGDynamicDefaultFloat(@"Widgets.CornerRadius", 20.2); }
LG_FLOAT_PREF_FUNC(LGWidgetBezelWidth, "Widgets.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGWidgetGlassThickness, "Widgets.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGWidgetRefractionScale, "Widgets.RefractionScale", 1.8)
LG_FLOAT_PREF_FUNC(LGWidgetRefractiveIndex, "Widgets.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGWidgetSpecularOpacity, "Widgets.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGWidgetBlur, "Widgets.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGWidgetWallpaperScale, "Widgets.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGWidgetLightTintAlpha, "Widgets.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGWidgetDarkTintAlpha, "Widgets.DarkTintAlpha", 0.3)
LG_FLOAT_PREF_FUNC(LGWidgetLiveCaptureFPS, "Widgets.LiveCaptureFPS", 8.0)

static NSHashTable<UIView *> *LGWidgetHostRegistry(void) {
    if (!sWidgetHosts) {
        sWidgetHosts = [NSHashTable weakObjectsHashTable];
    }
    return sWidgetHosts;
}

@interface CHSWidget : NSObject
@property (nonatomic, copy, readonly) NSString *extensionBundleIdentifier;
@end

@interface CHUISWidgetHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

@interface CHUISAvocadoHostViewController : UIViewController
@property (nonatomic, copy) CHSWidget *widget;
@end

static BOOL LGViewBelongsToWidgetStack(UIView *view) {
    if (!view) return NO;

    NSString *selfClassName = NSStringFromClass([view class]);
    if ([selfClassName containsString:@"Widget"] || [selfClassName containsString:@"WG"]) {
        return YES;
    }

    UIView *ancestor = view.superview;
    while (ancestor) {
        NSString *className = NSStringFromClass([ancestor class]);
        if ([className containsString:@"Widget"] || [className containsString:@"WG"])
            return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static UIView *LGWidgetFindDescendantNamed(UIView *view, NSString *className) {
    if (!view) return nil;
    for (UIView *subview in view.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:className]) return subview;
        UIView *match = LGWidgetFindDescendantNamed(subview, className);
        if (match) return match;
    }
    return nil;
}

static BOOL LGWidgetScrollViewContainsWidgetContainer(UIView *view) {
    if (!view) return NO;
    if ([NSStringFromClass(view.class) isEqualToString:@"SBHWidgetContainerView"]) return YES;
    for (UIView *subview in view.subviews) {
        if (LGWidgetScrollViewContainsWidgetContainer(subview)) return YES;
    }
    return NO;
}

static BOOL LGWidgetHasAncestorClassNamedWithinDepth(UIView *view, NSString *className, NSInteger maxDepth) {
    UIView *ancestor = view.superview;
    NSInteger depth = 0;
    while (ancestor && depth < maxDepth) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:className]) return YES;
        ancestor = ancestor.superview;
        depth++;
    }
    return NO;
}

static void LGStartWidgetDisplayLink(void) {
    NSInteger fps = LG_prefersLiveCapture(@"Widgets.RenderingMode")
        ? LGPreferredLiveCaptureFramesPerSecond(LGWidgetLiveCaptureFPS())
        : LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 1);
    LGStartDisplayLinkStateWithPreferenceKey(&sWidgetDisplayLinkState,
                                             fps,
                                             @"DisplayLink.Widgets.Enabled",
                                             ^{
        NSInteger nextFPS = LG_prefersLiveCapture(@"Widgets.RenderingMode")
            ? LGPreferredLiveCaptureFramesPerSecond(LGWidgetLiveCaptureFPS())
            : LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 1);
        LGSetDisplayLinkStatePreferredFPS(&sWidgetDisplayLinkState, nextFPS);
        if (LG_prefersLiveCapture(@"Widgets.RenderingMode")) LGWidgetsRefreshAttachedHosts();
        else LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
    });
}

static void LGStopWidgetDisplayLink(void) {
    LGStopDisplayLinkState(&sWidgetDisplayLinkState);
}

static UIColor *widgetTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGWidgetLightTintAlpha(), LGWidgetDarkTintAlpha(), @"Widgets.TintOverrideMode");
}

static BOOL LGWidgetHostUsesStockMaterialBlur(UIView *view) {
    return view && [NSStringFromClass(view.class) isEqualToString:@"MTMaterialView"];
}

static UIViewController *LGNearestWidgetStackControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([NSStringFromClass(responder.class) isEqualToString:@"SBHWidgetStackViewController"] &&
            [responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL LGWidgetContainerLooksLikeHomescreenWidgetHost(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"UIView"]) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;
    if (!LGNearestWidgetStackControllerForView(view)) return NO;
    if (!LGWidgetHasAncestorClassNamedWithinDepth(view, @"SBFTouchPassThroughView", 8)) return NO;
    if (!LGWidgetHasAncestorClassNamedWithinDepth(view, @"SBIconView", 10)) return NO;

    BOOL hasWidgetScroll = NO;
    for (UIView *subview in view.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"UIView"] &&
            ![NSStringFromClass(subview.class) isEqualToString:@"BSUIScrollView"]) {
            continue;
        }
        UIView *scrollView = [NSStringFromClass(subview.class) isEqualToString:@"BSUIScrollView"] ? subview : LGWidgetFindDescendantNamed(subview, @"BSUIScrollView");
        if (!scrollView) continue;
        if (!LGWidgetScrollViewContainsWidgetContainer(scrollView)) continue;
        hasWidgetScroll = YES;
        break;
    }
    return hasWidgetScroll;
}

static UIView *LGWidgetAncestorContainerHostForView(UIView *view) {
    UIView *ancestor = view;
    NSInteger depth = 0;
    while (ancestor && depth < 12) {
        if (LGWidgetContainerLooksLikeHomescreenWidgetHost(ancestor)) return ancestor;
        ancestor = ancestor.superview;
        depth++;
    }
    return nil;
}

static NSArray *LGWidgetCleanedFilterArray(NSArray *filters, BOOL *didRemoveAny) {
    if (!filters.count) return filters;
    NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:filters.count];
    BOOL removed = NO;
    for (id filter in filters) {
        NSString *desc = [[filter description] lowercaseString];
        if ([desc containsString:@"colormatrix"] || [desc containsString:@"opacitycolor"]) {
            removed = YES;
            continue;
        }
        [cleaned addObject:filter];
    }
    if (didRemoveAny) *didRemoveAny = removed;
    return removed ? cleaned : filters;
}

static void LGStripWidgetTintFiltersFromLayerTree(CALayer *layer) {
    if (!layer) return;
    BOOL removedMain = NO;
    NSArray *mainFilters = LGWidgetCleanedFilterArray(layer.filters, &removedMain);
    if (removedMain) layer.filters = mainFilters;

    @try {
        id rawBackgroundFilters = [layer valueForKey:@"backgroundFilters"];
        if ([rawBackgroundFilters isKindOfClass:[NSArray class]]) {
            BOOL removedBg = NO;
            NSArray *cleanedBg = LGWidgetCleanedFilterArray(rawBackgroundFilters, &removedBg);
            if (removedBg) [layer setValue:cleanedBg forKey:@"backgroundFilters"];
        }
    } @catch (__unused NSException *e) {}

    layer.compositingFilter = nil;
    for (CALayer *sub in layer.sublayers) {
        LGStripWidgetTintFiltersFromLayerTree(sub);
    }
}

static void removeWidgetOverlays(UIView *view) {
    if (!view) return;
    objc_setAssociatedObject(view, kWidgetLastLiveCaptureTimeKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveAssociatedSubview(view, kWidgetTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kWidgetBackdropViewKey);
}

static void LGDetachWidgetGlassHostView(UIView *view) {
    if (!view) return;
    [LGWidgetHostRegistry() removeObject:view];
    removeWidgetOverlays(view);
    LGRestoreWidgetOriginalState(view);
    if ([objc_getAssociatedObject(view, kWidgetAttachedKey) boolValue]) {
        objc_setAssociatedObject(view, kWidgetAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        sWidgetDisplayLinkState.activeCount = MAX(0, sWidgetDisplayLinkState.activeCount - 1);
        LGDisplayLinkStateDidChangeActivity(&sWidgetDisplayLinkState);
        if (sWidgetDisplayLinkState.activeCount == 0) LGStopWidgetDisplayLink();
    }
}

static void LGRememberWidgetOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kWidgetOriginalAlphaKey))
        objc_setAssociatedObject(view, kWidgetOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey)) {
        objc_setAssociatedObject(view, kWidgetOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGCacheDynamicDefaultFloat(@"Widgets.CornerRadius", view.layer.cornerRadius);
    }
    if (!objc_getAssociatedObject(view, kWidgetOriginalClipsKey))
        objc_setAssociatedObject(view, kWidgetOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalMasksKey))
        objc_setAssociatedObject(view, kWidgetOriginalMasksKey, @(view.layer.masksToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey)) {
        NSString *curve = nil;
        if (@available(iOS 13.0, *))
            curve = view.layer.cornerCurve;
        if (curve)
            objc_setAssociatedObject(view, kWidgetOriginalCornerCurveKey, curve, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static void LGRestoreWidgetOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kWidgetOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kWidgetOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
    NSNumber *masks = objc_getAssociatedObject(view, kWidgetOriginalMasksKey);
    if (masks) view.layer.masksToBounds = [masks boolValue];
    NSString *curve = objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey);
    if (@available(iOS 13.0, *)) {
        if (curve) view.layer.cornerCurve = curve;
    }
}

static BOOL LGIsWidgetStackBackgroundMaterialView(UIView *view) {
    if (!view) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"MTMaterialView"]) return NO;
    UIView *parent = view.superview;
    if (!parent || ![NSStringFromClass(parent.class) isEqualToString:@"UIView"]) return NO;
    UIViewController *controller = LGNearestWidgetStackControllerForView(parent);
    if (!controller) return NO;
    if (controller.view == parent) return YES;
    return parent.superview == controller.view;
}

static void LGRestoreWidgetStackMaterialView(UIView *view) {
    NSNumber *hidden = objc_getAssociatedObject(view, kWidgetMaterialOriginalHiddenKey);
    NSNumber *alpha = objc_getAssociatedObject(view, kWidgetMaterialOriginalAlphaKey);
    NSNumber *layerOpacity = objc_getAssociatedObject(view, kWidgetMaterialOriginalLayerOpacityKey);
    if (hidden) view.hidden = hidden.boolValue;
    if (alpha) view.alpha = alpha.doubleValue;
    if (layerOpacity) view.layer.opacity = layerOpacity.floatValue;
    objc_setAssociatedObject(view, kWidgetMaterialOriginalHiddenKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kWidgetMaterialOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kWidgetMaterialOriginalLayerOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGApplyWidgetStackMaterialVisibility(UIView *view) {
    if (!LGIsWidgetStackBackgroundMaterialView(view)) {
        LGRestoreWidgetStackMaterialView(view);
        return;
    }
    if (!LGWidgetEnabled()) {
        LGRestoreWidgetStackMaterialView(view);
        return;
    }
    if (!objc_getAssociatedObject(view, kWidgetMaterialOriginalHiddenKey)) {
        objc_setAssociatedObject(view, kWidgetMaterialOriginalHiddenKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kWidgetMaterialOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, kWidgetMaterialOriginalLayerOpacityKey, @(view.layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.hidden = YES;
    view.alpha = 0.0;
    view.layer.opacity = 0.0f;
}

static void ensureWidgetTintOverlay(UIView *view) {
    if (LGWidgetHostUsesStockMaterialBlur(view)) {
        LGStripWidgetTintFiltersFromLayerTree(view.layer);
    }

    UIView *tint = LGEnsureTintOverlayView(view,
                                           kWidgetTintKey,
                                           kWidgetTintTag,
                                           view.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               widgetTintColorForView(view),
                               view.layer.cornerRadius,
                               view.layer,
                               NO);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);
    UIView *contentAnchor = nil;
    for (UIView *subview in view.subviews) {
        if (subview == glass || subview == tint) continue;
        contentAnchor = subview;
        break;
    }
    if (contentAnchor) {
        [view insertSubview:tint belowSubview:contentAnchor];
    } else if (glass) {
        [view insertSubview:tint aboveSubview:glass];
    } else {
        [view sendSubviewToBack:tint];
    }
}

static BOOL LGIsWidgetGlassHostView(UIView *view) {
    if (!view.window) return NO;

    NSString *className = NSStringFromClass(view.class);
    if ([className isEqualToString:@"UIView"] &&
        LGWidgetContainerLooksLikeHomescreenWidgetHost(view)) {
        return YES;
    }

    return NO;
}

static void LGPrepareWidgetGlassHostView(UIView *view) {
    LGRememberWidgetOriginalState(view);
    view.layer.cornerRadius = LGWidgetCornerRadius();
    if (@available(iOS 13.0, *))
        view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    if (LGWidgetHostUsesStockMaterialBlur(view)) {
        LGStripWidgetTintFiltersFromLayerTree(view.layer);
    }
}

static void LGInjectIntoWidgetGlassHostView(UIView *view) {
    CFTimeInterval profileStart = LGProfileBegin();
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        LGProfileEnd(@"widgets.inject", profileStart);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);
    BOOL hadGlass = (glass != nil);
    if (!LGShouldRefreshLiveCaptureForHost(view,
                                           @"Widgets.RenderingMode",
                                           kWidgetLastLiveCaptureTimeKey,
                                           LGWidgetLiveCaptureFPS(),
                                           hadGlass)) {
        LGPrepareWidgetGlassHostView(view);
        glass.cornerRadius = LGWidgetCornerRadius();
        glass.bezelWidth = LGWidgetBezelWidth();
        glass.glassThickness = LGWidgetGlassThickness();
        glass.refractionScale = LGWidgetRefractionScale();
        glass.refractiveIndex = LGWidgetRefractiveIndex();
        glass.specularOpacity = LGWidgetSpecularOpacity();
        glass.blur = LGWidgetBlur();
        glass.wallpaperScale = LGWidgetWallpaperScale();
        [view sendSubviewToBack:glass];
        ensureWidgetTintOverlay(view);
        [glass updateOrigin];
        LGProfileEnd(@"widgets.inject", profileStart);
        return;
    }

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getWallpaperImage(&wallpaperOrigin);
    if (!wallpaper && !LG_prefersLiveCapture(@"Widgets.RenderingMode")) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        LGProfileEnd(@"widgets.inject", profileStart);
        return;
    }

    LGPrepareWidgetGlassHostView(view);
    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:view.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.cornerRadius           = LGWidgetCornerRadius();
        glass.bezelWidth             = LGWidgetBezelWidth();
        glass.glassThickness         = LGWidgetGlassThickness();
        glass.refractionScale        = LGWidgetRefractionScale();
        glass.refractiveIndex        = LGWidgetRefractiveIndex();
        glass.specularOpacity        = LGWidgetSpecularOpacity();
        glass.blur                   = LGWidgetBlur();
        glass.wallpaperScale         = LGWidgetWallpaperScale();
        glass.updateGroup            = LGUpdateGroupWidgets;
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.cornerRadius = LGWidgetCornerRadius();
    glass.bezelWidth = LGWidgetBezelWidth();
    glass.glassThickness = LGWidgetGlassThickness();
    glass.refractionScale = LGWidgetRefractionScale();
    glass.refractiveIndex = LGWidgetRefractiveIndex();
    glass.specularOpacity = LGWidgetSpecularOpacity();
    glass.blur = LGWidgetBlur();
    glass.wallpaperScale = LGWidgetWallpaperScale();
    if (!LGApplyRenderingModeToGlassHost(view,
                                         glass,
                                         @"Widgets.RenderingMode",
                                         kWidgetBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        LGProfileEnd(@"widgets.inject", profileStart);
        return;
    }
    if (LG_prefersLiveCapture(@"Widgets.RenderingMode")) {
        LGMarkLiveCaptureRefreshedForHost(view, kWidgetLastLiveCaptureTimeKey);
    }
    [LGWidgetHostRegistry() addObject:view];
    [view sendSubviewToBack:glass];
    ensureWidgetTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureWidgetTintOverlay(view);
    });
    LGProfileEnd(@"widgets.inject", profileStart);
}

static void LGWidgetsRefreshAllHosts(void) {
    CFTimeInterval profileStart = LGProfileBegin();
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            LGApplyWidgetStackMaterialVisibility(view);
            if (!LGIsWidgetGlassHostView(view)) return;
            LGPrepareWidgetGlassHostView(view);
            LGInjectIntoWidgetGlassHostView(view);
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
    LGProfileEnd(@"widgets.refresh_all_hosts", profileStart);
}

static void LGWidgetsRefreshAttachedHosts(void) {
    CFTimeInterval profileStart = LGProfileBegin();
    for (UIView *view in LGWidgetHostRegistry().allObjects) {
        if (!view.window || !LGIsWidgetGlassHostView(view)) {
            LGDetachWidgetGlassHostView(view);
            continue;
        }
        LGInjectIntoWidgetGlassHostView(view);
    }
    LGProfileEnd(@"widgets.refresh_attached_hosts", profileStart);
}

static void LGWidgetsPrefsChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGWidgetsRefreshAllHosts();
    });
}

%group LGWidgetsSpringBoard

%hook CHUISAvocadoHostViewController

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed avocado material widget=%@", widget.extensionBundleIdentifier);
        return;
    }
    %orig;
}

- (id)screenshotManager {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed avocado screenshot widget=%@", widget.extensionBundleIdentifier);
        return nil;
    }
    return %orig;
}

%end

%hook CHUISWidgetHostViewController

- (void)_updateBackgroundMaterialAndColor {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed host material widget=%@", widget.extensionBundleIdentifier);
        return;
    }
    %orig;
}

- (void)_updatePersistedSnapshotContent {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed host snapshot widget=%@", widget.extensionBundleIdentifier);
        return;
    }
    %orig;
}

- (void)_updatePersistedSnapshotContentIfNecessary {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed host snapshot-if-needed widget=%@", widget.extensionBundleIdentifier);
        return;
    }
    %orig;
}

- (id)_snapshotImageFromURL:(id)arg1 {
    CHSWidget *widget = self.widget;
    if (widget.extensionBundleIdentifier.length && LGWidgetEnabled()) {
        LGDebugLog(@"widget springboard suppressed host snapshot image widget=%@", widget.extensionBundleIdentifier);
        return nil;
    }
    return %orig;
}

%end

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        LGRestoreWidgetStackMaterialView(self_);
        LGDetachWidgetGlassHostView(self_);
        return;
    }

    LGApplyWidgetStackMaterialVisibility(self_);
    if (!LGIsWidgetGlassHostView(self_)) return;
    LGInjectIntoWidgetGlassHostView(self_);
    if (![objc_getAssociatedObject(self_, kWidgetAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kWidgetAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sWidgetDisplayLinkState.activeCount++;
        LGDisplayLinkStateDidChangeActivity(&sWidgetDisplayLinkState);
        LGStartWidgetDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    LGApplyWidgetStackMaterialVisibility(self_);
    if (!LGIsWidgetGlassHostView(self_)) return;
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(self_);
        LGRestoreWidgetOriginalState(self_);
        return;
    }
    if (LG_prefersLiveCapture(@"Widgets.RenderingMode")) {
        LGInjectIntoWidgetGlassHostView(self_);
        return;
    }
    ensureWidgetTintOverlay(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kWidgetGlassKey);
    [glass updateOrigin];
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetDisplayLinkState.link) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetDisplayLinkState.link) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

%end

%hook BSUIScrollView

- (void)didMoveToWindow {
    %orig;
    UIView *host = LGWidgetAncestorContainerHostForView((UIView *)self);
    if (!host) return;
    if (!((UIView *)self).window) {
        LGDetachWidgetGlassHostView(host);
        return;
    }

    if (!LGWidgetEnabled()) {
        LGDetachWidgetGlassHostView(host);
        return;
    }

    LGInjectIntoWidgetGlassHostView(host);
    if (![objc_getAssociatedObject(host, kWidgetAttachedKey) boolValue]) {
        objc_setAssociatedObject(host, kWidgetAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sWidgetDisplayLinkState.activeCount++;
        LGDisplayLinkStateDidChangeActivity(&sWidgetDisplayLinkState);
        LGStartWidgetDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *host = LGWidgetAncestorContainerHostForView((UIView *)self);
    if (!host) return;
    if (!LGIsWidgetGlassHostView(host)) return;
    if (!LGWidgetEnabled()) {
        LGDetachWidgetGlassHostView(host);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(host, kWidgetGlassKey);
    if (!glass) {
        LGInjectIntoWidgetGlassHostView(host);
        glass = objc_getAssociatedObject(host, kWidgetGlassKey);
        if (!glass) return;
    }
    if (LG_prefersLiveCapture(@"Widgets.RenderingMode")) {
        LGInjectIntoWidgetGlassHostView(host);
        return;
    }
    ensureWidgetTintOverlay(host);
    [glass updateOrigin];
}

%end

%end

%ctor {
    if (LGIsSpringBoardProcess()) {
        LGObservePreferenceChanges(^{
            LGWidgetsPrefsChanged(NULL, NULL, NULL, NULL, NULL);
        });
        %init(LGWidgetsSpringBoard);
    }
}
