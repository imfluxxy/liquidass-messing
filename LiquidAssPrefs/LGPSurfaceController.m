#import "LGPSurfaceController.h"
#import "LGPrefsDataSupport.h"
#import "LGPrefsUIHelpers.h"
#import "LGPrefsLiquidSlider.h"
#import "LGPrefsLiquidSwitch.h"
#import "../Shared/LGRWBSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGGlassRenderer.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGSharedSupport.h"
#import "../Shared/LGBackButtonSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#ifndef LG_PACKAGE_VERSION
#define LG_PACKAGE_VERSION @""
#endif

static NSURL *LGTemporaryPreferencesExportURL(void) {
    NSString *filename = [NSString stringWithFormat:@"liquidass-preferences-%@.json",
                          [[NSUUID UUID].UUIDString lowercaseString]];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}

static void *kLGPanelItemKey = &kLGPanelItemKey;
static void *kLGScrollTopBackdropViewKey = &kLGScrollTopBackdropViewKey;
static void *kLGScrollTopGlassViewKey = &kLGScrollTopGlassViewKey;
static void *kLGScrollTopBlurViewKey = &kLGScrollTopBlurViewKey;
static void *kLGScrollTopTintViewKey = &kLGScrollTopTintViewKey;
static void *kLGScrollTopLiveReadyKey = &kLGScrollTopLiveReadyKey;
static void *kLGDonationAddressKey = &kLGDonationAddressKey;

static BOOL LGPreferencesGoToTopButtonEnabled(void) {
    return [LGReadPreference(@"Preferences.GoToTop.Enabled", @NO) boolValue];
}

static BOOL LGItemVisibleForCurrentPreferences(NSDictionary *item) {
    NSString *visibleKey = item[@"visible_key"];
    NSArray *visibleValues = item[@"visible_values"];
    if (!visibleKey.length || visibleValues.count == 0) return YES;

    id fallback = item[@"visible_default"];
    id storedValue = LGReadPreferenceObject(visibleKey, fallback);
    NSString *currentValue = nil;
    if ([storedValue isKindOfClass:[NSString class]]) {
        currentValue = storedValue;
    } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
        currentValue = [storedValue stringValue];
    } else if ([storedValue respondsToSelector:@selector(description)]) {
        currentValue = [storedValue description];
    }
    if (!currentValue.length && [fallback isKindOfClass:[NSString class]]) {
        currentValue = fallback;
    }
    if (!currentValue.length) return NO;
    return [visibleValues containsObject:currentValue];
}

@implementation LGPSurfaceController {
    NSString *_screenTitle;
    NSString *_screenSubtitle;
    NSString *_screenIdentifier;
    UIColor *_accentColor;
    NSArray<NSDictionary *> *_items;
    UIScrollView *_scrollView;
    UIStackView *_contentStack;
    UIScrollView *_jumpScrollView;
    UIStackView *_jumpStack;
    NSMutableDictionary<NSString *, UIView *> *_sectionViews;
    UIView *_respringBar;
    UIView *_scrollTopButton;
    NSLayoutConstraint *_scrollTopBottomConstraint;
    BOOL _scrollTopButtonVisible;
    CGSize _lastBackdropLayoutSize;
    CFTimeInterval _lastFloatingGlassScrollRefreshTime;
}

- (void)updateVisibleValueControlledItemsAnimated:(BOOL)animated {
    for (UIView *panel in _contentStack.arrangedSubviews) {
        UIStackView *stack = nil;
        for (UIView *subview in panel.subviews) {
            if ([subview isKindOfClass:[UIStackView class]]) {
                stack = (UIStackView *)subview;
                break;
            }
        }
        if (!stack) continue;

        NSArray<UIView *> *arrangedSubviews = stack.arrangedSubviews;
        BOOL hasPanelItems = NO;
        for (UIView *subview in arrangedSubviews) {
            if (objc_getAssociatedObject(subview, kLGPanelItemKey) != nil) {
                hasPanelItems = YES;
                break;
            }
        }
        if (!hasPanelItems) continue;

        for (UIView *subview in arrangedSubviews) {
            NSDictionary *item = objc_getAssociatedObject(subview, kLGPanelItemKey);
            if (!item) continue;
            BOOL visible = LGItemVisibleForCurrentPreferences(item);
            void (^changes)(void) = ^{
                subview.hidden = !visible;
                subview.alpha = visible ? 1.0 : 0.0;
            };
            if (animated) {
                [UIView animateWithDuration:0.16
                                      delay:0.0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                                 animations:changes
                                 completion:nil];
            } else {
                changes();
            }
        }

        NSArray<UIView *> *visibleBodies = [arrangedSubviews filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UIView *evaluatedObject, NSDictionary *bindings) {
            (void)bindings;
            return objc_getAssociatedObject(evaluatedObject, kLGPanelItemKey) != nil && !evaluatedObject.hidden;
        }]];

        for (NSUInteger i = 0; i < arrangedSubviews.count; i++) {
            UIView *subview = arrangedSubviews[i];
            if (objc_getAssociatedObject(subview, kLGPanelItemKey) != nil) continue;
            BOOL previousVisible = NO;
            BOOL nextVisible = NO;
            for (NSInteger left = (NSInteger)i - 1; left >= 0; left--) {
                UIView *candidate = arrangedSubviews[(NSUInteger)left];
                if (objc_getAssociatedObject(candidate, kLGPanelItemKey) != nil) {
                    previousVisible = !candidate.hidden;
                    break;
                }
            }
            for (NSUInteger right = i + 1; right < arrangedSubviews.count; right++) {
                UIView *candidate = arrangedSubviews[right];
                if (objc_getAssociatedObject(candidate, kLGPanelItemKey) != nil) {
                    nextVisible = !candidate.hidden;
                    break;
                }
            }
            BOOL visible = previousVisible && nextVisible && visibleBodies.count > 1;
            subview.hidden = !visible;
        }
    }
}

- (void)reloadLocalizedContent {
    if ([_screenIdentifier isEqualToString:@"Homescreen"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.homescreen.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.homescreen.subtitle") copy];
        _accentColor = [UIColor systemBlueColor];
        _items = [LGHomescreenItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"Lockscreen"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.lockscreen.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.lockscreen.subtitle") copy];
        _accentColor = [UIColor systemRedColor];
        _items = [LGLockscreenItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"AppLibrary"]) {
        _screenTitle = [LGLocalized(@"prefs.surface.app_library.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.surface.app_library.subtitle") copy];
        _accentColor = [UIColor systemGreenColor];
        _items = [LGAppLibraryItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"MoreOptions"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.about.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.about.subtitle") copy];
        _accentColor = [UIColor systemIndigoColor];
        _items = [LGMoreOptionsItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"PrefsSettings"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.prefs_settings.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.prefs_settings.subtitle") copy];
        _accentColor = [UIColor systemGrayColor];
        _items = [LGPrefsSettingsItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"PreferencesControls"]) {
        _screenTitle = [LGLocalized(@"prefs.section.preferences.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.section.preferences.subtitle") copy];
        _accentColor = [UIColor systemIndigoColor];
        _items = [LGPrefsControlsItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"Experimental"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.experimental.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.experimental.subtitle") copy];
        _accentColor = [UIColor systemOrangeColor];
        _items = [LGExperimentalItems() copy];
    } else if ([_screenIdentifier isEqualToString:@"CustomViews"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.custom_views.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.custom_views.subtitle") copy];
        _accentColor = [UIColor systemPurpleColor];
        _items = [LGCustomViewInjectionItems() copy];
    } else if ([_screenIdentifier hasPrefix:@"CustomViewRule:"]) {
        NSString *ruleID = [_screenIdentifier substringFromIndex:@"CustomViewRule:".length];
        _screenTitle = [LGLocalized(@"prefs.custom_views.rule_details.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.custom_views.rule.subtitle") copy];
        _accentColor = [UIColor systemPurpleColor];
        _items = [LGCustomViewRuleItems(ruleID) copy];
    } else if ([_screenIdentifier isEqualToString:@"LiveCapture"]) {
        _screenTitle = [LGLocalized(@"prefs.misc.live_capture.title") copy];
        _screenSubtitle = [LGLocalized(@"prefs.misc.live_capture.subtitle") copy];
        _accentColor = [UIColor systemTealColor];
        _items = [LGLiveCaptureItems() copy];
    }
    self.title = _screenTitle;
}

- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                    tintColor:(UIColor *)tintColor
                   identifier:(NSString *)identifier
                        items:(NSArray<NSDictionary *> *)items {
    self = [super init];
    if (!self) return nil;
    _screenTitle = [title copy];
    _screenSubtitle = [subtitle copy];
    _screenIdentifier = [identifier copy];
    _accentColor = tintColor ?: [UIColor systemBlueColor];
    _items = [items copy];
    self.title = title;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self configureCustomBackButton];
    self.navigationItem.rightBarButtonItem = LGMakeCircularResetItem(self, @selector(handleResetPressed));
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    [self applyNavigationBarStyle];
    LGInstallScrollableStack(self, 23.25, 12.0, &_scrollView, &_contentStack);
    _scrollView.delegate = self;
    LGInstallBottomRespringBar(self, &_respringBar);
    _scrollTopButton = [self makeScrollTopButton];
    [self.view addSubview:_scrollTopButton];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    _scrollTopBottomConstraint = [_scrollTopButton.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0];
    [NSLayoutConstraint activateConstraints:@[
        [_scrollTopButton.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        _scrollTopBottomConstraint,
    ]];

    [self reloadVisibleSettings];
    LGObservePrefsNotifications(self);
    [self updateRespringBarAnimated:NO];
    _scrollTopButtonVisible = NO;
    [self updateScrollTopButtonAnimated:NO];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLanguageChanged:)
                                                 name:kLGPrefsLanguageChangedNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarStyle];
    if ([_screenIdentifier isEqualToString:@"CustomViews"] || [_screenIdentifier hasPrefix:@"CustomViewRule:"]) {
        [self reloadLocalizedContent];
        [self reloadVisibleSettings];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_screenIdentifier.length) {
        LGSetLastSurfaceIdentifier(_screenIdentifier);
    }
    LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    [self refreshScrollTopButtonBackdrop];
    LGScheduleRespringBarGlassRefresh(_respringBar);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize layoutSize = self.view.bounds.size;
    if (CGSizeEqualToSize(layoutSize, _lastBackdropLayoutSize)) return;
    _lastBackdropLayoutSize = layoutSize;
    LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
    LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    LGRefreshRespringBarGlass(_respringBar);
    [self refreshScrollTopButtonBackdrop];
}

- (void)configureCustomBackButton {
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem = LGMakeCircularBackItem(self, @selector(handleBackPressed));
    LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
}

- (void)applyNavigationBarStyle {
    LGApplyNavigationBarAppearance(self.navigationItem);
}

- (void)handleBackPressed {
    LGClearLastSurfaceIdentifierIfMatching(_screenIdentifier);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)handleResetPressed {
    LGPresentResetConfirmationWithBody(self, [self resetConfirmationBodyText], @selector(performAnimatedSurfacePreferenceReset));
}

- (void)performAnimatedPreferenceReset {
    [self animateVisibleControlsToDefaults];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGResetAllPreferences();
    });
}

- (NSArray<NSString *> *)currentPreferenceKeys {
    if ([_screenIdentifier isEqualToString:@"CustomViews"]) {
        return LGAllCustomViewPreferenceKeys();
    }
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *item in _items) {
        NSString *key = item[@"key"];
        if (key.length) [keys addObject:key];
        NSArray *itemKeys = item[@"keys"];
        if ([itemKeys isKindOfClass:NSArray.class]) {
            for (id itemKey in itemKeys) {
                if ([itemKey isKindOfClass:NSString.class] && [itemKey length]) {
                    [keys addObject:itemKey];
                }
            }
        }
    }
    return keys.array;
}

- (NSString *)resetConfirmationBodyText {
    NSString *scope = _screenTitle.length ? _screenTitle.lowercaseString : LGLocalized(@"prefs.button.reset");
    return [NSString stringWithFormat:LGLocalized(@"prefs.reset_confirm.surface_body_format"), scope];
}

- (void)performAnimatedSurfacePreferenceReset {
    if ([_screenIdentifier isEqualToString:@"PrefsSettings"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LGSetCurrentPrefsLanguageCode(@"en");
        });
        return;
    }
    [self animateVisibleControlsToDefaults];
    NSArray<NSString *> *keys = [self currentPreferenceKeys];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.67 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LGResetPreferencesForKeys(keys);
    });
}

- (void)handleRespringPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
    LGPresentRespringConfirmation(self);
}

- (void)handleLaterPressed {
    LGSetRespringBarDismissed(YES);
    [self updateRespringBarAnimated:YES];
}

- (void)openExperimental {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.misc.experimental.title")
                                                                          subtitle:LGLocalized(@"prefs.misc.experimental.subtitle")
                                                                         tintColor:[UIColor systemOrangeColor]
                                                                        identifier:@"Experimental"
                                                                             items:LGExperimentalItems()];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openPreferencesControls {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.section.preferences.title")
                                                                          subtitle:LGLocalized(@"prefs.section.preferences.subtitle")
                                                                         tintColor:[UIColor systemIndigoColor]
                                                                        identifier:@"PreferencesControls"
                                                                             items:LGPrefsControlsItems()];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openLiveCaptureConfiguration {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.misc.live_capture.title")
                                                                          subtitle:LGLocalized(@"prefs.misc.live_capture.subtitle")
                                                                         tintColor:[UIColor systemTealColor]
                                                                        identifier:@"LiveCapture"
                                                                             items:LGLiveCaptureItems()];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openCustomViewInjection {
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.misc.custom_views.title")
                                                                          subtitle:LGLocalized(@"prefs.misc.custom_views.subtitle")
                                                                         tintColor:[UIColor systemPurpleColor]
                                                                        identifier:@"CustomViews"
                                                                             items:LGCustomViewInjectionItems()];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)openCustomViewRule:(UIButton *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, kLGPanelItemKey);
    NSString *ruleID = item[@"rule_id"];
    if (![ruleID isKindOfClass:NSString.class] || !ruleID.length) return;
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.custom_views.rule_details.title")
                                                                          subtitle:LGLocalized(@"prefs.custom_views.rule.subtitle")
                                                                         tintColor:[UIColor systemPurpleColor]
                                                                        identifier:[@"CustomViewRule:" stringByAppendingString:ruleID]
                                                                             items:LGCustomViewRuleItems(ruleID)];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)addCustomViewRule:(UIButton *)sender {
    (void)sender;
    NSString *ruleID = LGCreateCustomViewRule();
    [self reloadLocalizedContent];
    [self reloadVisibleSettings];
    if (!ruleID.length) return;
    LGPSurfaceController *controller = [[LGPSurfaceController alloc] initWithTitle:LGLocalized(@"prefs.custom_views.rule_details.title")
                                                                          subtitle:LGLocalized(@"prefs.custom_views.rule.subtitle")
                                                                         tintColor:[UIColor systemPurpleColor]
                                                                        identifier:[@"CustomViewRule:" stringByAppendingString:ruleID]
                                                                             items:LGCustomViewRuleItems(ruleID)];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)deleteCustomViewRule {
    if (![_screenIdentifier hasPrefix:@"CustomViewRule:"]) return;
    NSString *ruleID = [_screenIdentifier substringFromIndex:@"CustomViewRule:".length];
    __weak typeof(self) weakSelf = self;
    LGPresentConfirmationSheet(self,
                               LGLocalized(@"prefs.custom_views.delete_rule.title"),
                               LGLocalized(@"prefs.custom_views.delete_rule.confirm"),
                               LGLocalized(@"prefs.button.cancel"),
                               LGLocalized(@"prefs.custom_views.delete_rule.title"),
                               YES,
                               ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        LGDeleteCustomViewRule(ruleID);
        [self.navigationController popViewControllerAnimated:YES];
    });
}

- (void)invalidateSnapshotCaches {
    LGPresentInvalidateCachesConfirmation(self);
}

- (void)exportPreferences {
    NSString *jsonString = LGExportPreferencesJSONString();
    if (!jsonString.length) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    NSURL *exportURL = LGTemporaryPreferencesExportURL();
    NSError *writeError = nil;
    if (![jsonString writeToURL:exportURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.export_prefs.title"),
                           writeError.localizedDescription ?: LGLocalized(@"prefs.export_prefs.error"));
        return;
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[exportURL] applicationActivities:nil];
    if (activityController.popoverPresentationController) {
        activityController.popoverPresentationController.sourceView = self.view;
        activityController.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    }
    [self presentViewController:activityController animated:YES completion:nil];
}

- (void)importPreferences {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)editThirdPartyAppRWB {
    NSString *existing = [LGReadPreferenceObject(@"RWB.ThirdPartyBundleIDs", LGRWBDefaultWidgetBundleIDsText()) isKindOfClass:[NSString class]]
        ? LGReadPreferenceObject(@"RWB.ThirdPartyBundleIDs", LGRWBDefaultWidgetBundleIDsText())
        : LGRWBDefaultWidgetBundleIDsText();
    LGPresentMultilineTextInputSheet(self,
                                     LGLocalized(@"prefs.misc.rwb_third_party.title"),
                                     LGLocalized(@"prefs.misc.rwb_third_party.editor_body"),
                                     existing,
                                     LGLocalized(@"prefs.misc.rwb_third_party.placeholder"),
                                     ^(NSString *text) {
        NSMutableOrderedSet<NSString *> *lines = [NSMutableOrderedSet orderedSet];
        [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] enumerateObjectsUsingBlock:^(NSString *rawLine, NSUInteger idx, BOOL *stop) {
            (void)idx;
            (void)stop;
            NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!line.length) return;
            [lines addObject:line];
        }];
        NSString *normalized = [[lines array] componentsJoinedByString:@"\n"];
        if (normalized.length) {
            LGWritePreferenceObject(@"RWB.ThirdPartyBundleIDs", normalized);
        } else {
            LGRemovePreference(@"RWB.ThirdPartyBundleIDs");
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSString *jsonString = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&readError];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (!jsonString.length) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           readError.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_read"));
        return;
    }

    NSError *error = nil;
    if (!LGImportPreferencesJSONString(jsonString, &error)) {
        LGPresentInfoSheet(self,
                           LGLocalized(@"prefs.misc.import_prefs.title"),
                           error.localizedDescription ?: LGLocalized(@"prefs.import_prefs.error_invalid"));
        return;
    }

    [self reloadLocalizedContent];
    [self reloadVisibleSettings];
    [self updateRespringBarAnimated:NO];
    LGPresentInfoSheet(self,
                       LGLocalized(@"prefs.misc.import_prefs.title"),
                       LGLocalized(@"prefs.import_prefs.success"));
}

- (void)dealloc {
    LGRemoveLiveBackdropCaptureView(_scrollTopButton, kLGScrollTopBackdropViewKey);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handlePrefsUIRefresh:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self animateVisibleControlsToDefaults];
}

- (void)handleRespringStateChanged:(NSNotification *)notification {
    (void)notification;
    [self updateRespringBarAnimated:YES];
}

- (void)handleLanguageChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.isViewLoaded) return;
    [self reloadLocalizedContent];
    [self reloadVisibleSettings];
    [self updateRespringBarAnimated:NO];
}

- (void)updateRespringBarAnimated:(BOOL)animated {
    BOOL shouldShow = LGNeedsRespring() && !LGRespringBarDismissed();
    if (!_respringBar) return;
    LGRefreshRespringBarGlass(_respringBar);
    _scrollTopBottomConstraint.constant = shouldShow ? -108.0 : -12.0;
    if (shouldShow == !_respringBar.hidden) {
        if (animated && !_scrollTopButton.hidden) {
            [UIView animateWithDuration:0.22 animations:^{
                [self.view layoutIfNeeded];
            }];
        } else {
            [self.view layoutIfNeeded];
        }
        if (shouldShow) {
            LGScheduleRespringBarGlassRefresh(_respringBar);
        }
        return;
    }
    if (shouldShow) {
        _respringBar.hidden = NO;
        LGRefreshRespringBarGlass(_respringBar);
        if (animated) {
            [UIView animateWithDuration:0.22 animations:^{
                _respringBar.alpha = 1.0;
                _respringBar.transform = CGAffineTransformIdentity;
                [self.view layoutIfNeeded];
            } completion:^(__unused BOOL finished) {
                LGRefreshRespringBarGlass(_respringBar);
            }];
        } else {
            _respringBar.alpha = 1.0;
            _respringBar.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
            LGRefreshRespringBarGlass(_respringBar);
        }
        LGScheduleRespringBarGlassRefresh(_respringBar);
    } else {
        void (^hideBlock)(void) = ^{
            _respringBar.alpha = 0.0;
            _respringBar.transform = CGAffineTransformMakeTranslation(0.0, 10.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            (void)finished;
            _respringBar.hidden = YES;
        };
        if (animated) {
            [UIView animateWithDuration:0.18 animations:hideBlock completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (UIView *)makeScrollTopButton {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    container.alpha = 0.0;
    container.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    LGSharedGlassView *glassView = [[LGSharedGlassView alloc] initWithFrame:CGRectZero sourceImage:nil sourceOrigin:CGPointZero];
    glassView.translatesAutoresizingMaskIntoConstraints = NO;
    glassView.userInteractionEnabled = NO;
    glassView.releasesSourceAfterUpload = NO;
    glassView.bezelWidth = 12.0;
    glassView.glassThickness = 100.0;
    glassView.refractionScale = 1.5;
    glassView.refractiveIndex = 1.5;
    glassView.specularOpacity = 0.03;
    glassView.blur = 3.0;
    glassView.sourceScale = 1.0;
    glassView.cornerRadius = 19.0;
    glassView.hidden = YES;
    [container addSubview:glassView];
    objc_setAssociatedObject(container, kLGScrollTopGlassViewKey, glassView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *blurView = LGMakeLowBlurFallbackView();
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.userInteractionEnabled = NO;
    blurView.hidden = NO;
    blurView.layer.cornerRadius = 19.0;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    [container addSubview:blurView];
    LGApplyLowBlurRadiusToView(blurView);
    objc_setAssociatedObject(container, kLGScrollTopBlurViewKey, blurView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *tintView = [[UIView alloc] initWithFrame:CGRectZero];
    tintView.translatesAutoresizingMaskIntoConstraints = NO;
    tintView.userInteractionEnabled = NO;
    tintView.backgroundColor = LGCustomTintColorForKey(@"Preferences.GoToTop.CustomTintColor") ?: [UIColor colorWithWhite:1.0 alpha:0.10];
    tintView.layer.cornerRadius = 19.0;
    tintView.layer.cornerCurve = kCACornerCurveContinuous;
    tintView.layer.borderWidth = 0.75;
    tintView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.14].CGColor;
    [container addSubview:tintView];
    objc_setAssociatedObject(container, kLGScrollTopTintViewKey, tintView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.go_to_top") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"chevron.up" withConfiguration:config] forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    button.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 12.0, 0.0, 12.0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -6.0);
    #pragma clang diagnostic pop
    [button addTarget:self action:@selector(handleScrollTopPressed) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:button];

    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:116.0],
        [container.heightAnchor constraintEqualToConstant:38.0],
        [glassView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [glassView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [glassView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [glassView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [blurView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [tintView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [tintView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [tintView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [tintView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.topAnchor constraintEqualToAnchor:container.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
    return container;
}

- (void)refreshScrollTopButtonBackdrop {
    if (!_scrollTopButton || _scrollTopButton.hidden || !_scrollTopButton.window || CGRectIsEmpty(_scrollTopButton.bounds)) return;
    LGSharedGlassView *glassView = objc_getAssociatedObject(_scrollTopButton, kLGScrollTopGlassViewKey);
    if (!glassView) return;
    UIView *blurView = objc_getAssociatedObject(_scrollTopButton, kLGScrollTopBlurViewKey);
    UIView *tintView = objc_getAssociatedObject(_scrollTopButton, kLGScrollTopTintViewKey);
    tintView.backgroundColor = LGCustomTintColorForKey(@"Preferences.GoToTop.CustomTintColor") ?: [UIColor colorWithWhite:1.0 alpha:0.10];
    BOOL glassEnabled = LGPreferencesGoToTopButtonEnabled();
    BOOL liveReady = [objc_getAssociatedObject(_scrollTopButton, kLGScrollTopLiveReadyKey) boolValue];
    glassView.hidden = !glassEnabled || !liveReady;
    if (blurView) {
        blurView.hidden = glassEnabled && liveReady;
        LGApplyLowBlurRadiusToView(blurView);
    }
    if (!glassEnabled) {
        objc_setAssociatedObject(_scrollTopButton, kLGScrollTopLiveReadyKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGRemoveLiveBackdropCaptureView(_scrollTopButton, kLGScrollTopBackdropViewKey);
        return;
    }
    glassView.cornerRadius = CGRectGetHeight(_scrollTopButton.bounds) * 0.5;
    CGPoint captureOrigin = CGPointZero;
    CGSize samplingResolution = CGSizeZero;
    if (LGCaptureLiveBackdropTextureForHost(_scrollTopButton,
                                            glassView,
                                            kLGScrollTopBackdropViewKey,
                                            &captureOrigin,
                                            &samplingResolution)) {
        objc_setAssociatedObject(_scrollTopButton, kLGScrollTopLiveReadyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glassView.hidden = NO;
        if (blurView) blurView.hidden = YES;
        glassView.wallpaperOrigin = captureOrigin;
        glassView.wallpaperSamplingResolution = samplingResolution;
        [glassView updateOrigin];
        [glassView scheduleDraw];
    }
}

- (CGFloat)scrollTopRevealThreshold {
    UIView *targetSection = _sectionViews[LGLocalized(@"prefs.section.folder_icons.title")];
    if (!targetSection) {
        NSArray<NSDictionary *> *sections = [self sectionItems];
        NSString *fallbackTitle = sections.count > 1 ? sections[1][@"title"] : sections.firstObject[@"title"];
        if (fallbackTitle.length) {
            targetSection = _sectionViews[fallbackTitle];
        }
    }
    if (targetSection) {
        CGRect targetRect = [_contentStack convertRect:targetSection.frame toView:_scrollView];
        CGFloat topInset = _scrollView.adjustedContentInset.top;
        return MAX(120.0, CGRectGetMinY(targetRect) - topInset - 24.0);
    }
    return 220.0;
}

- (void)updateScrollTopButtonAnimated:(BOOL)animated {
    if (!_scrollTopButton || !_scrollView) return;
    BOOL shouldShow = _scrollView.contentOffset.y >= [self scrollTopRevealThreshold];
    if (shouldShow == _scrollTopButtonVisible) return;
    _scrollTopButtonVisible = shouldShow;
    if (shouldShow) {
        _scrollTopButton.hidden = NO;
        [self refreshScrollTopButtonBackdrop];
        void (^showBlock)(void) = ^{
            _scrollTopButton.alpha = 1.0;
            _scrollTopButton.transform = CGAffineTransformIdentity;
            [self.view layoutIfNeeded];
            [self refreshScrollTopButtonBackdrop];
        };
        if (animated) {
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [UIView animateWithDuration:0.22
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                             animations:showBlock
                             completion:^(__unused BOOL finished) {
                [self refreshScrollTopButtonBackdrop];
            }];
        } else {
            showBlock();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshScrollTopButtonBackdrop];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self refreshScrollTopButtonBackdrop];
        });
    } else {
        void (^hideBlock)(void) = ^{
            _scrollTopButton.alpha = 0.0;
            _scrollTopButton.transform = CGAffineTransformMakeTranslation(0.0, 8.0);
            [self.view layoutIfNeeded];
        };
        void (^completion)(BOOL) = ^(BOOL finished) {
            if (!_scrollTopButtonVisible) {
                LGRemoveLiveBackdropCaptureView(_scrollTopButton, kLGScrollTopBackdropViewKey);
                _scrollTopButton.hidden = YES;
            }
        };
        if (animated) {
            [UIView animateWithDuration:0.20
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:hideBlock
                             completion:completion];
        } else {
            hideBlock();
            completion(YES);
        }
    }
}

- (void)handleScrollTopPressed {
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    [_scrollView setContentOffset:CGPointMake(0.0, -topInset) animated:YES];
}

- (void)reloadVisibleSettings {
    _sectionViews = [NSMutableDictionary dictionary];
    for (UIView *subview in [_contentStack.arrangedSubviews copy]) {
        [_contentStack removeArrangedSubview:subview];
        [subview removeFromSuperview];
    }
    [_contentStack addArrangedSubview:[self heroCard]];
    [_contentStack addArrangedSubview:LGMakeSectionDivider()];
    UIView *jumpView = [self jumpToViewIfNeeded];
    if (jumpView) {
        [_contentStack addArrangedSubview:jumpView];
    }
    NSUInteger index = 0;
    while (index < _items.count) {
        NSDictionary *item = _items[index];
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"about_content"]) {
            [_contentStack addArrangedSubview:[self aboutContentView]];
            index += 1;
            continue;
        }
        if ([type isEqualToString:@"section"]) {
            NSString *sectionTitle = item[@"title"] ?: @"";
            NSString *sectionSubtitle = item[@"subtitle"] ?: @"";
            if (!sectionTitle.length && !sectionSubtitle.length) {
                UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                spacer.backgroundColor = UIColor.clearColor;
                spacer.translatesAutoresizingMaskIntoConstraints = NO;
                NSNumber *height = item[@"height"];
                [spacer.heightAnchor constraintEqualToConstant:height ? height.doubleValue : 18.0].active = YES;
                UIView *previousView = _contentStack.arrangedSubviews.lastObject;
                if (previousView && height && [_contentStack respondsToSelector:@selector(setCustomSpacing:afterView:)]) {
                    [_contentStack setCustomSpacing:0.0 afterView:previousView];
                }
                [_contentStack addArrangedSubview:spacer];
                NSNumber *afterSpacing = item[@"after_spacing"];
                if (afterSpacing && [_contentStack respondsToSelector:@selector(setCustomSpacing:afterView:)]) {
                    [_contentStack setCustomSpacing:afterSpacing.doubleValue afterView:spacer];
                }
                index += 1;
                continue;
            }
            [_contentStack addArrangedSubview:[self sectionViewForItem:item]];
            NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
            index += 1;
            while (index < _items.count
                   && ![_items[index][@"type"] isEqualToString:@"section"]
                   && ![_items[index][@"type"] isEqualToString:@"about_content"]) {
                [groupItems addObject:_items[index]];
                index += 1;
            }
            if (groupItems.count) {
                [self appendSurfaceGroupItems:groupItems];
            }
            continue;
        }

        NSMutableArray<NSDictionary *> *groupItems = [NSMutableArray array];
        while (index < _items.count
               && ![_items[index][@"type"] isEqualToString:@"section"]
               && ![_items[index][@"type"] isEqualToString:@"about_content"]) {
            [groupItems addObject:_items[index]];
            index += 1;
        }
        if (groupItems.count) {
            [self appendSurfaceGroupItems:groupItems];
        }
    }
    [self updateVisibleValueControlledItemsAnimated:NO];
    [self updateScrollTopButtonAnimated:NO];
}

- (void)updatePanelsControlledByEnabledKey:(NSString *)enabledKey enabled:(BOOL)enabled animated:(BOOL)animated {
    if (!enabledKey.length) return;
    for (UIView *panel in _contentStack.arrangedSubviews) {
        NSString *controllerKey = objc_getAssociatedObject(panel, kLGControlledByEnabledKey);
        if (![controllerKey isEqualToString:enabledKey]) continue;
        panel.userInteractionEnabled = enabled;
        void (^changes)(void) = ^{
            panel.alpha = enabled ? 1.0 : 0.42;
        };
        if (animated) {
            [UIView animateWithDuration:0.18
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:changes
                             completion:nil];
        } else {
            changes();
        }
    }
}

- (void)animateVisibleControlsToDefaults {
    for (UIView *card in _contentStack.arrangedSubviews) {
        for (UIView *subview in [self lg_allSubviewsOfView:card]) {
            if ([subview isKindOfClass:[UISwitch class]]) {
                UISwitch *toggle = (UISwitch *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(toggle, kLGDefaultValueKey);
                NSString *preferenceKey = objc_getAssociatedObject(toggle, kLGPreferenceKeyKey);
                if ([preferenceKey isEqualToString:@"Global.Enabled"]) {
                    continue;
                }
                if (defaultValue) {
                    BOOL enabled = [defaultValue boolValue];
                    [toggle setOn:enabled animated:YES];
                    if ([objc_getAssociatedObject(toggle, kLGControlledByEnabledKey) boolValue]) {
                        [self updatePanelsControlledByEnabledKey:preferenceKey enabled:enabled animated:YES];
                    }
                }
            } else if ([subview isKindOfClass:[UISlider class]]) {
                UISlider *slider = (UISlider *)subview;
                NSNumber *defaultValue = objc_getAssociatedObject(slider, kLGDefaultValueKey);
                UILabel *valueLabel = objc_getAssociatedObject(slider, kLGValueLabelKey);
                NSNumber *decimalsNumber = objc_getAssociatedObject(slider, kLGDecimalsKey);
                if (defaultValue) {
                    float targetValue = [defaultValue floatValue];
                    NSInteger decimals = decimalsNumber ? [decimalsNumber integerValue] : 0;
                    LGAnimateSliderToDefault(slider, targetValue, valueLabel, decimals);
                }
            } else if ([subview isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)subview;
                NSString *preferenceKey = objc_getAssociatedObject(label, kLGPreferenceKeyKey);
                NSString *defaultValue = objc_getAssociatedObject(label, kLGDefaultValueKey);
                if (preferenceKey.length && [defaultValue isKindOfClass:[NSString class]]) {
                    label.text = defaultValue;
                }
            }
        }
    }
}

- (NSArray<UIView *> *)lg_allSubviewsOfView:(UIView *)view {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    for (UIView *subview in view.subviews) {
        [result addObject:subview];
        [result addObjectsFromArray:[self lg_allSubviewsOfView:subview]];
    }
    return result;
}

- (UIView *)heroCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = _screenTitle;
    titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = _screenSubtitle;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectZero];
    accentBar.translatesAutoresizingMaskIntoConstraints = NO;
    accentBar.backgroundColor = [_accentColor colorWithAlphaComponent:0.9];
    accentBar.layer.cornerRadius = 2.0;

    [card addSubview:accentBar];
    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [NSLayoutConstraint activateConstraints:@[
        [accentBar.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [accentBar.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [accentBar.widthAnchor constraintEqualToConstant:36.0],
        [accentBar.heightAnchor constraintEqualToConstant:4.0],
        [titleLabel.topAnchor constraintEqualToAnchor:accentBar.bottomAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0],
    ]];
    return card;
}

- (NSString *)currentPackageVersion {
    NSString *compiledVersion = LG_PACKAGE_VERSION;
    if (compiledVersion.length) {
        return compiledVersion;
    }
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (shortVersion.length) {
        return shortVersion;
    }
    NSString *bundleVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return bundleVersion.length ? bundleVersion : @"";
}

- (NSString *)latestBundledChangelogPathInBundle:(NSBundle *)bundle {
    NSString *directoryPath = [bundle pathForResource:@"changelogs" ofType:nil];
    if (!directoryPath.length) return nil;

    NSArray<NSString *> *filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:nil];
    NSMutableArray<NSString *> *markdownFilenames = [NSMutableArray array];
    for (NSString *filename in filenames) {
        if ([[filename pathExtension] isEqualToString:@"md"]) {
            [markdownFilenames addObject:filename];
        }
    }
    if (!markdownFilenames.count) return nil;

    [markdownFilenames sortUsingComparator:^NSComparisonResult(NSString *first, NSString *second) {
        NSString *firstVersion = [first stringByDeletingPathExtension];
        NSString *secondVersion = [second stringByDeletingPathExtension];
        return [firstVersion localizedStandardCompare:secondVersion];
    }];
    return [directoryPath stringByAppendingPathComponent:markdownFilenames.lastObject];
}

- (NSString *)aboutChangelogMarkdownText {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *version = [self currentPackageVersion];
    NSString *path = version.length ? [bundle pathForResource:version ofType:@"md" inDirectory:@"changelogs"] : nil;
    if (!path.length) {
        path = [self latestBundledChangelogPathInBundle:bundle];
    }
    if (!path.length) return @"";
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

- (UILabel *)aboutMarkdownLabelWithText:(NSString *)text
                                   font:(UIFont *)font
                                  color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.numberOfLines = 0;
    label.font = font;
    label.textColor = color;
    return label;
}

- (void)addMarkdownLine:(NSString *)line toStack:(UIStackView *)stack {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) {
        UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
        spacer.translatesAutoresizingMaskIntoConstraints = NO;
        [spacer.heightAnchor constraintEqualToConstant:4.0].active = YES;
        [stack addArrangedSubview:spacer];
        return;
    }

    NSUInteger headingLevel = 0;
    while (headingLevel < trimmed.length && [trimmed characterAtIndex:headingLevel] == '#') {
        headingLevel += 1;
    }
    if (headingLevel > 0 && headingLevel < trimmed.length && [trimmed characterAtIndex:headingLevel] == ' ') {
        NSString *heading = [[trimmed substringFromIndex:headingLevel + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        CGFloat fontSize = headingLevel == 1 ? 20.0 : 17.0;
        UILabel *label = [self aboutMarkdownLabelWithText:heading
                                                     font:[UIFont systemFontOfSize:fontSize weight:UIFontWeightBold]
                                                    color:[UIColor labelColor]];
        [stack addArrangedSubview:label];
        return;
    }

    BOOL isBullet = [trimmed hasPrefix:@"- "] || [trimmed hasPrefix:@"* "];
    NSString *body = isBullet ? [trimmed substringFromIndex:2] : trimmed;
    if (isBullet) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *bullet = [self aboutMarkdownLabelWithText:@"•"
                                                      font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
                                                     color:[UIColor secondaryLabelColor]];
        UILabel *label = [self aboutMarkdownLabelWithText:body
                                                     font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular]
                                                    color:[UIColor labelColor]];
        [row addSubview:bullet];
        [row addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [bullet.topAnchor constraintEqualToAnchor:row.topAnchor constant:1.0],
            [bullet.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [bullet.widthAnchor constraintEqualToConstant:18.0],
            [label.topAnchor constraintEqualToAnchor:row.topAnchor],
            [label.leadingAnchor constraintEqualToAnchor:bullet.trailingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        ]];
        [stack addArrangedSubview:row];
        return;
    }

    UILabel *label = [self aboutMarkdownLabelWithText:body
                                                 font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular]
                                                color:[UIColor labelColor]];
    [stack addArrangedSubview:label];
}

- (void)handleDonationRowPressed:(UIButton *)sender {
    NSString *address = objc_getAssociatedObject(sender, kLGDonationAddressKey);
    if (!address.length) return;
    UIPasteboard.generalPasteboard.string = address;
    LGPresentInfoSheet(self, @"Copied", @"Wallet address copied to clipboard.");
}

- (UIView *)donationRowWithName:(NSString *)name
                        network:(NSString *)network
                         symbol:(NSString *)symbol
                          color:(UIColor *)color
                        address:(NSString *)address {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    [button addTarget:self action:@selector(handleDonationRowPressed:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, kLGDonationAddressKey, address, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.userInteractionEnabled = NO;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:body];

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectZero];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.text = symbol;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = color;
    badge.layer.cornerRadius = 14.0;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    badge.layer.masksToBounds = YES;

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.text = name;
    nameLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];

    UILabel *networkLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    networkLabel.translatesAutoresizingMaskIntoConstraints = NO;
    networkLabel.text = network;
    networkLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    networkLabel.textColor = [UIColor secondaryLabelColor];

    UILabel *addressLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    addressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    addressLabel.text = address;
    addressLabel.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    addressLabel.textColor = [UIColor tertiaryLabelColor];
    addressLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    addressLabel.numberOfLines = 1;

    UIImageView *copyIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]];
    copyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    copyIcon.tintColor = [UIColor tertiaryLabelColor];
    copyIcon.contentMode = UIViewContentModeScaleAspectFit;

    UIView *titleRow = [[UIView alloc] initWithFrame:CGRectZero];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [titleRow addSubview:nameLabel];
    [titleRow addSubview:networkLabel];

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleRow, addressLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3.0;

    [body addSubview:badge];
    [body addSubview:textStack];
    [body addSubview:copyIcon];

    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:button.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
        [badge.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [badge.centerYAnchor constraintEqualToAnchor:body.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:28.0],
        [badge.heightAnchor constraintEqualToConstant:28.0],
        [copyIcon.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [copyIcon.centerYAnchor constraintEqualToAnchor:body.centerYAnchor],
        [copyIcon.widthAnchor constraintEqualToConstant:18.0],
        [copyIcon.heightAnchor constraintEqualToConstant:18.0],
        [nameLabel.topAnchor constraintEqualToAnchor:titleRow.topAnchor],
        [nameLabel.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [nameLabel.bottomAnchor constraintEqualToAnchor:titleRow.bottomAnchor],
        [networkLabel.firstBaselineAnchor constraintEqualToAnchor:nameLabel.firstBaselineAnchor],
        [networkLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:nameLabel.trailingAnchor constant:8.0],
        [networkLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],
        [textStack.topAnchor constraintEqualToAnchor:body.topAnchor constant:10.0],
        [textStack.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12.0],
        [textStack.trailingAnchor constraintEqualToAnchor:copyIcon.leadingAnchor constant:-12.0],
        [textStack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-10.0],
    ]];

    return button;
}

- (UIView *)donationCard {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 23.25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *headerStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    headerStack.axis = UILayoutConstraintAxisVertical;
    headerStack.spacing = 3.0;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:headerStack];

    UILabel *title = [self aboutMarkdownLabelWithText:@"Donate"
                                                 font:[UIFont systemFontOfSize:20.0 weight:UIFontWeightBold]
                                                color:[UIColor labelColor]];
    UILabel *subtitle = [self aboutMarkdownLabelWithText:@"Crypto only for now. Tap a row to copy the address."
                                                    font:[UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium]
                                                   color:[UIColor secondaryLabelColor]];
    [headerStack addArrangedSubview:title];
    [headerStack addArrangedSubview:subtitle];
    [stack addArrangedSubview:header];

    // BTC: bc1qlv830emqsffqslns2e3kglkgcdnlag0nfnyj4k
    // ETH: 0x6245EF47c749D1b5c2830b145cB943a8aD826bea
    // LTC: ltc1q7j6vlgvymxdtwm46u0n22h7m4890cexfp22vfm
    // DOGE: D76nuR1HWSymSLhFYYhkfpc4JHg1HjvgWD
    // SOL: F1rH3PSMHFHXbGLGQiWXGLRaahfYoVULUwhsvrewM37W
    // TRX: TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX
    // USDC (Polygon): 0x6245EF47c749D1b5c2830b145cB943a8aD826bea
    // USDT (Tron/trc-20): TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX

    NSArray<NSDictionary *> *methods = @[
        @{@"name": @"BTC", @"network": @"Bitcoin", @"symbol": @"B", @"color": [UIColor systemOrangeColor], @"address": @"bc1qlv830emqsffqslns2e3kglkgcdnlag0nfnyj4k"},
        @{@"name": @"ETH", @"network": @"Ethereum", @"symbol": @"E", @"color": [UIColor systemIndigoColor], @"address": @"0x6245EF47c749D1b5c2830b145cB943a8aD826bea"},
        @{@"name": @"LTC", @"network": @"Litecoin", @"symbol": @"L", @"color": [UIColor systemGrayColor], @"address": @"ltc1q7j6vlgvymxdtwm46u0n22h7m4890cexfp22vfm"},
        @{@"name": @"DOGE", @"network": @"Dogecoin", @"symbol": @"D", @"color": [UIColor systemYellowColor], @"address": @"D76nuR1HWSymSLhFYYhkfpc4JHg1HjvgWD"},
        @{@"name": @"SOL", @"network": @"Solana", @"symbol": @"S", @"color": [UIColor systemPurpleColor], @"address": @"F1rH3PSMHFHXbGLGQiWXGLRaahfYoVULUwhsvrewM37W"},
        @{@"name": @"TRX", @"network": @"Tron", @"symbol": @"T", @"color": [UIColor systemRedColor], @"address": @"TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX"},
        @{@"name": @"USDC", @"network": @"Polygon", @"symbol": @"U", @"color": [UIColor systemBlueColor], @"address": @"0x6245EF47c749D1b5c2830b145cB943a8aD826bea"},
        @{@"name": @"USDT", @"network": @"Tron TRC-20", @"symbol": @"U", @"color": [UIColor systemGreenColor], @"address": @"TVuW2KcYBMcr2VAMhYVqYmoT15N3MbZ8eX"},
    ];

    for (NSUInteger index = 0; index < methods.count; index++) {
        NSDictionary *method = methods[index];
        UIView *row = [self donationRowWithName:method[@"name"]
                                        network:method[@"network"]
                                         symbol:method[@"symbol"]
                                          color:method[@"color"]
                                        address:method[@"address"]];
        [stack addArrangedSubview:row];
        if (index + 1 < methods.count) {
            UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
            dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *divider = LGMakeSectionDivider();
            [dividerRow addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:54.0],
                [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
                [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
            ]];
            [stack addArrangedSubview:dividerRow];
        }
    }

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [headerStack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16.0],
        [headerStack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16.0],
        [headerStack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [headerStack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-13.0],
    ]];

    return card;
}

- (UIView *)aboutContentView {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = UIColor.clearColor;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 7.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    UIImage *icon = [UIImage imageNamed:@"original" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!icon) {
        icon = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
    }
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.layer.cornerRadius = 19.0;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [iconView.widthAnchor constraintEqualToConstant:82.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:82.0].active = YES;

    UILabel *nameLabel = [self aboutMarkdownLabelWithText:LGLocalized(@"prefs.app_name")
                                                     font:[UIFont systemFontOfSize:28.0 weight:UIFontWeightBold]
                                                    color:[UIColor labelColor]];
    nameLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitleLabel = [self aboutMarkdownLabelWithText:LGLocalized(@"prefs.hero.subtitle")
                                                         font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium]
                                                        color:[UIColor secondaryLabelColor]];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;

    UIView *markdownCard = [[UIView alloc] initWithFrame:CGRectZero];
    markdownCard.translatesAutoresizingMaskIntoConstraints = NO;
    markdownCard.backgroundColor = LGSubpageCardBackgroundColor();
    markdownCard.layer.cornerRadius = 23.25;
    markdownCard.layer.cornerCurve = kCACornerCurveContinuous;
    markdownCard.layer.masksToBounds = YES;

    UIStackView *markdownStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    markdownStack.axis = UILayoutConstraintAxisVertical;
    markdownStack.alignment = UIStackViewAlignmentFill;
    markdownStack.spacing = 7.0;
    markdownStack.translatesAutoresizingMaskIntoConstraints = NO;
    [markdownCard addSubview:markdownStack];

    NSString *markdownText = [self aboutChangelogMarkdownText];
    if (markdownText.length) {
        NSArray<NSString *> *lines = [markdownText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            [self addMarkdownLine:line toStack:markdownStack];
        }
    } else {
        UILabel *fallbackLabel = [self aboutMarkdownLabelWithText:[NSString stringWithFormat:@"No changelog found for %@.", [self currentPackageVersion]]
                                                             font:[UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular]
                                                            color:[UIColor secondaryLabelColor]];
        [markdownStack addArrangedSubview:fallbackLabel];
    }

    [stack addArrangedSubview:iconView];
    [stack addArrangedSubview:nameLabel];
    [stack addArrangedSubview:subtitleLabel];
    [stack setCustomSpacing:18.0 afterView:subtitleLabel];
    UIView *donationCard = [self donationCard];
    [stack addArrangedSubview:markdownCard];
    [stack setCustomSpacing:12.0 afterView:markdownCard];
    [stack addArrangedSubview:donationCard];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:18.0],
        [nameLabel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-18.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:22.0],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-22.0],
        [markdownCard.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [markdownCard.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [donationCard.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [donationCard.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [markdownStack.topAnchor constraintEqualToAnchor:markdownCard.topAnchor constant:16.0],
        [markdownStack.leadingAnchor constraintEqualToAnchor:markdownCard.leadingAnchor constant:16.0],
        [markdownStack.trailingAnchor constraintEqualToAnchor:markdownCard.trailingAnchor constant:-16.0],
        [markdownStack.bottomAnchor constraintEqualToAnchor:markdownCard.bottomAnchor constant:-16.0],
    ]];

    return container;
}

- (NSArray<NSDictionary *> *)sectionItems {
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSDictionary *item in _items) {
        if ([item[@"type"] isEqualToString:@"section"] && [item[@"title"] length]) {
            [sections addObject:item];
        }
    }
    return [sections copy];
}

- (UIView *)jumpToViewIfNeeded {
    NSArray<NSDictionary *> *sections = [self sectionItems];
    if (sections.count < 2) return nil;

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = UIColor.clearColor;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.jump_to.title");
    titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];

    _jumpScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _jumpScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpScrollView.showsHorizontalScrollIndicator = NO;
    _jumpScrollView.alwaysBounceHorizontal = YES;
    _jumpScrollView.backgroundColor = UIColor.clearColor;

    _jumpStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _jumpStack.translatesAutoresizingMaskIntoConstraints = NO;
    _jumpStack.axis = UILayoutConstraintAxisHorizontal;
    _jumpStack.spacing = 10.0;
    [_jumpScrollView addSubview:_jumpStack];

    [container addSubview:titleLabel];
    [container addSubview:_jumpScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:container.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:2.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-2.0],
        [_jumpScrollView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [_jumpScrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [_jumpScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [_jumpScrollView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [_jumpScrollView.heightAnchor constraintEqualToConstant:38.0],
        [_jumpStack.topAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.topAnchor],
        [_jumpStack.leadingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.leadingAnchor],
        [_jumpStack.trailingAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.trailingAnchor],
        [_jumpStack.bottomAnchor constraintEqualToAnchor:_jumpScrollView.contentLayoutGuide.bottomAnchor],
        [_jumpStack.heightAnchor constraintEqualToAnchor:_jumpScrollView.frameLayoutGuide.heightAnchor],
    ]];

    for (NSDictionary *section in sections) {
        NSString *title = section[@"title"];
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [button setTitle:title forState:UIControlStateNormal];
        [button setTitleColor:_accentColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        button.backgroundColor = [_accentColor colorWithAlphaComponent:(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.16 : 0.10)];
        button.layer.cornerRadius = 19.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        button.contentEdgeInsets = UIEdgeInsetsMake(0.0, 14.0, 0.0, 14.0);
        #pragma clang diagnostic pop
        [button.heightAnchor constraintEqualToConstant:38.0].active = YES;
        [button addTarget:self action:@selector(handleJumpChipPressed:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(button, @selector(handleJumpChipPressed:), title, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [_jumpStack addArrangedSubview:button];
    }

    return container;
}

- (void)handleJumpChipPressed:(UIButton *)sender {
    NSString *title = objc_getAssociatedObject(sender, _cmd);
    if (title.length) {
        [self jumpToSectionNamed:title];
    }
}

- (void)handleSliderValueLabelTapped:(UITapGestureRecognizer *)gesture {
    LGPresentSliderValuePrompt(self, (UILabel *)gesture.view);
}

- (void)handleSliderInfoPressed:(UIButton *)sender {
    NSString *controlTitle = objc_getAssociatedObject(sender, kLGControlTitleKey);
    NSString *subtitle = objc_getAssociatedObject(sender, kLGControlSubtitleKey);
    LGPresentInfoSheet(self, (controlTitle.length ? controlTitle : LGLocalized(@"prefs.info.title")), subtitle);
}

- (void)jumpToSectionNamed:(NSString *)title {
    UIView *sectionView = _sectionViews[title];
    if (!sectionView || !_scrollView) return;
    CGRect targetRect = [_contentStack convertRect:sectionView.frame toView:_scrollView];
    CGFloat topInset = _scrollView.adjustedContentInset.top;
    CGFloat targetY = MAX(-topInset, CGRectGetMinY(targetRect) - 12.0);
    [_scrollView setContentOffset:CGPointMake(0.0, targetY) animated:YES];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _scrollView) {
        [self updateScrollTopButtonAnimated:YES];
        CFTimeInterval now = CACurrentMediaTime();
        if (now - _lastFloatingGlassScrollRefreshTime >= (1.0 / 30.0)) {
            _lastFloatingGlassScrollRefreshTime = now;
            LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
            LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
            LGRefreshRespringBarGlass(_respringBar);
            [self refreshScrollTopButtonBackdrop];
        }
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView != _scrollView) return;
    if (!decelerate) {
        [self refreshScrollTopButtonBackdrop];
        LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
        LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == _scrollView) {
        [self refreshScrollTopButtonBackdrop];
        LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
        LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (scrollView == _scrollView) {
        [self refreshScrollTopButtonBackdrop];
        LGRefreshCircularBackItem(self.navigationItem.leftBarButtonItem);
        LGRefreshCircularBackItem(self.navigationItem.rightBarButtonItem);
    }
}

- (UIView *)sectionViewForItem:(NSDictionary *)item {
    UIView *sectionView = [[UIView alloc] initWithFrame:CGRectZero];
    sectionView.backgroundColor = UIColor.clearColor;
    NSString *sectionTitleText = item[@"title"];
    if (sectionTitleText.length) {
        _sectionViews[sectionTitleText] = sectionView;
    }

    UIStackView *sectionStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    sectionStack.axis = UILayoutConstraintAxisVertical;
    sectionStack.spacing = 3.0;
    sectionStack.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *sectionTitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionTitle.text = item[@"title"];
    sectionTitle.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];

    UILabel *sectionSubtitle = [[UILabel alloc] initWithFrame:CGRectZero];
    sectionSubtitle.text = item[@"subtitle"];
    sectionSubtitle.numberOfLines = 0;
    sectionSubtitle.textColor = [UIColor secondaryLabelColor];
    sectionSubtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];

    [sectionStack addArrangedSubview:sectionTitle];
    [sectionStack addArrangedSubview:sectionSubtitle];
    [sectionView addSubview:sectionStack];
    [NSLayoutConstraint activateConstraints:@[
        [sectionStack.topAnchor constraintEqualToAnchor:sectionView.topAnchor constant:4.0],
        [sectionStack.leadingAnchor constraintEqualToAnchor:sectionView.leadingAnchor constant:2.0],
        [sectionStack.trailingAnchor constraintEqualToAnchor:sectionView.trailingAnchor constant:-2.0],
        [sectionStack.bottomAnchor constraintEqualToAnchor:sectionView.bottomAnchor constant:-1.0],
    ]];
    return sectionView;
}

- (UILabel *)controlTitleLabelForItem:(NSDictionary *)item {
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = item[@"title"];
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    return titleLabel;
}

- (UILabel *)controlSubtitleLabelWithText:(NSString *)text {
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.text = text;
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    return subtitleLabel;
}

- (UIView *)controlHeaderRowWithTitleLabel:(UILabel *)titleLabel
                            accessoryViews:(NSArray<UIView *> *)accessoryViews
                                   spacing:(CGFloat)spacing {
    UIView *headerRow = [[UIView alloc] initWithFrame:CGRectZero];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [headerRow addSubview:titleLabel];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor].active = YES;
    [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor].active = YES;
    [titleLabel.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor].active = YES;

    UIView *rightmostView = nil;
    for (UIView *accessoryView in accessoryViews) {
        [headerRow addSubview:accessoryView];
        accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
        [accessoryView.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor].active = YES;
        if (!rightmostView) {
            [accessoryView.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
        } else {
            [accessoryView.trailingAnchor constraintEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        }
        rightmostView = accessoryView;
    }

    if (rightmostView) {
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:rightmostView.leadingAnchor constant:-spacing].active = YES;
        [rightmostView.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:spacing].active = YES;
    } else {
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor].active = YES;
    }

    return headerRow;
}

- (UISwitch *)configuredToggleForItem:(NSDictionary *)item {
    UISwitch *toggle = [[LGPrefsSwitchClass() alloc] initWithFrame:CGRectZero];
    toggle.onTintColor = _accentColor;
    toggle.on = [LGReadPreference(item[@"key"], item[@"default"]) boolValue];
    objc_setAssociatedObject(toggle, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(toggle, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISwitch *sender = (UISwitch *)action.sender;
        if ([item[@"key"] isEqualToString:@"SettingsControls.Enabled"]) {
            LGWritePreference(item[@"key"], @(sender.isOn));
            LGPresentReopenSettingsConfirmation(self);
        } else if ([item[@"key"] hasPrefix:@"Preferences."]) {
            LGWritePreference(item[@"key"], @(sender.isOn));
            [self configureCustomBackButton];
            [self updateScrollTopButtonAnimated:YES];
            [self refreshScrollTopButtonBackdrop];
            LGRefreshRespringBarGlass(_respringBar);
        } else {
            LGWritePreferenceAndMaybeRequireRespring(item[@"key"], @(sender.isOn));
            [self handleRespringStateChanged:nil];
        }
        if ([item[@"key"] isEqualToString:@"Tint.Override.PerSurfaceEnabled"] ||
            [item[@"key"] isEqualToString:@"DisplayLink.PerSurfaceEnabled"]) {
            [self reloadLocalizedContent];
            [self reloadVisibleSettings];
        }
        if ([item[@"controls_following_panel"] boolValue]) {
            [self updatePanelsControlledByEnabledKey:item[@"key"] enabled:sender.isOn animated:YES];
        }
    }] forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(toggle, kLGControlledByEnabledKey, item[@"controls_following_panel"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return toggle;
}

- (UIButton *)sliderInfoButtonForItem:(NSDictionary *)item
                             subtitle:(NSString *)subtitle
                             minValue:(CGFloat)minValue
                             maxValue:(CGFloat)maxValue
                             decimals:(NSInteger)decimals {
    UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *infoConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    [infoButton setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:infoConfig] forState:UIControlStateNormal];
    [infoButton setTintColor:[UIColor tertiaryLabelColor]];
    objc_setAssociatedObject(infoButton, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(infoButton, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [infoButton addTarget:self action:@selector(handleSliderInfoPressed:) forControlEvents:UIControlEventTouchUpInside];
    [infoButton.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [infoButton.heightAnchor constraintEqualToConstant:18.0].active = YES;
    return infoButton;
}

- (UILabel *)sliderValueLabelForStoredValue:(NSNumber *)stored
                                   decimals:(NSInteger)decimals
                                       item:(NSDictionary *)item
                                   subtitle:(NSString *)subtitle
                                   minValue:(CGFloat)minValue
                                   maxValue:(CGFloat)maxValue
                                     slider:(UISlider *)slider {
    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.text = LGFormatSliderValue([stored doubleValue], decimals);
    valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    valueLabel.textColor = _accentColor;
    valueLabel.userInteractionEnabled = YES;
    objc_setAssociatedObject(slider, kLGDefaultValueKey, item[@"default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(slider, kLGValueLabelKey, valueLabel, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(slider, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGSliderKey, slider, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(valueLabel, kLGPreferenceKeyKey, item[@"key"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMinValueKey, @(minValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGMaxValueKey, @(maxValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGDecimalsKey, @(decimals), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlTitleKey, item[@"title"], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGControlSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [valueLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSliderValueLabelTapped:)]];
    return valueLabel;
}

- (NSString *)menuSelectionTitleForItem:(NSDictionary *)item {
    NSString *key = item[@"key"];
    NSString *currentValue = nil;
    if ([key isEqualToString:kLGPrefsLanguageKey]) {
        currentValue = LGCurrentPrefsLanguageCode();
    } else {
        id storedValue = LGReadPreferenceObject(key, item[@"default"]);
        if ([storedValue isKindOfClass:[NSString class]]) {
            currentValue = storedValue;
        } else if ([storedValue respondsToSelector:@selector(stringValue)]) {
            currentValue = [storedValue stringValue];
        } else {
            currentValue = [[storedValue description] copy];
        }
    }
    for (NSDictionary *choice in item[@"choices"]) {
        if ([choice[@"value"] isEqual:currentValue]) {
            return choice[@"title"];
        }
    }
    for (NSDictionary *choice in item[@"choices"]) {
        if ([choice[@"value"] isEqual:item[@"default"]]) {
            return choice[@"title"];
        }
    }
    return @"";
}

- (UIMenu *)menuForItem:(NSDictionary *)item
           currentValue:(NSString *)currentValue
             menuButton:(UIButton *)menuButton
            titleUpdate:(void (^)(NSString *newTitle))applyMenuSelectionTitle {
    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakMenuButton = menuButton;
    __block NSString *selectedValue = [currentValue copy];
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (NSDictionary *choice in item[@"choices"]) {
        NSString *value = choice[@"value"];
        NSString *title = choice[@"title"];
        if (!value.length || !title.length) continue;
        UIAction *action = [UIAction actionWithTitle:title
                                               image:nil
                                          identifier:nil
                                             handler:^(__kindof UIAction * _Nonnull actionObj) {
            (void)actionObj;
            if ([item[@"key"] isEqualToString:kLGPrefsLanguageKey]) {
                LGSetCurrentPrefsLanguageCode(value);
                selectedValue = [LGCurrentPrefsLanguageCode() copy];
            } else {
                LGWritePreferenceObject(item[@"key"], value);
                selectedValue = [value copy];
                if (LGPreferenceRequiresRespring(item[@"key"])) {
                    LGSetRespringBarDismissed(NO);
                    LGSetNeedsRespring(YES);
                }
            }
            applyMenuSelectionTitle(title);
            __strong typeof(weakSelf) strongSelf = weakSelf;
            UIButton *strongMenuButton = weakMenuButton;
            if (strongSelf && strongMenuButton) {
                strongMenuButton.menu = [strongSelf menuForItem:item
                                                   currentValue:selectedValue
                                                     menuButton:strongMenuButton
                                                    titleUpdate:applyMenuSelectionTitle];
                if ([item[@"reload_on_change"] boolValue]) {
                    [strongSelf updateVisibleValueControlledItemsAnimated:YES];
                }
                [strongSelf updateRespringBarAnimated:YES];
            }
        }];
        if ([action respondsToSelector:@selector(setState:)]) {
            action.state = [value isEqualToString:selectedValue] ? UIMenuElementStateOn : UIMenuElementStateOff;
        }
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"" children:actions];
}

- (UIView *)menuControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    menuButton.showsMenuAsPrimaryAction = YES;
    menuButton.tintColor = _accentColor;
    menuButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    menuButton.contentEdgeInsets = UIEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
    menuButton.imageEdgeInsets = UIEdgeInsetsMake(0.0, 6.0, 0.0, -6.0);
    #pragma clang diagnostic pop
    menuButton.backgroundColor = UIColor.clearColor;
    menuButton.layer.cornerRadius = 0.0;

    NSString *selectedTitle = [self menuSelectionTitleForItem:item];
    __block NSString *currentValue = [item[@"key"] isEqualToString:kLGPrefsLanguageKey]
        ? LGCurrentPrefsLanguageCode()
        : [[LGReadPreferenceObject(item[@"key"], item[@"default"]) description] copy];
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.title = selectedTitle;
        config.image = [UIImage systemImageNamed:@"chevron.down"];
        config.imagePlacement = NSDirectionalRectEdgeTrailing;
        config.imagePadding = 6.0;
        config.baseForegroundColor = _accentColor;
        config.background.backgroundColor = UIColor.clearColor;
        config.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
        menuButton.configuration = config;
    } else {
        [menuButton setTitle:selectedTitle forState:UIControlStateNormal];
        [menuButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
        menuButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }

    __weak typeof(self) weakSelf = self;
    __weak UIButton *weakMenuButton = menuButton;
    void (^applyMenuSelectionTitle)(NSString *) = ^(NSString *newTitle) {
        if (!newTitle.length) return;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        UIButton *strongMenuButton = weakMenuButton;
        if (!strongSelf || !strongMenuButton) return;
        if (@available(iOS 15.0, *)) {
            UIButtonConfiguration *updatedConfig = strongMenuButton.configuration ?: [UIButtonConfiguration plainButtonConfiguration];
            updatedConfig.title = newTitle;
            updatedConfig.image = [UIImage systemImageNamed:@"chevron.down"];
            updatedConfig.imagePlacement = NSDirectionalRectEdgeTrailing;
            updatedConfig.imagePadding = 6.0;
            updatedConfig.baseForegroundColor = strongSelf->_accentColor;
            updatedConfig.background.backgroundColor = UIColor.clearColor;
            updatedConfig.contentInsets = NSDirectionalEdgeInsetsMake(4.0, 8.0, 4.0, 8.0);
            strongMenuButton.configuration = updatedConfig;
        } else {
            [strongMenuButton setTitle:newTitle forState:UIControlStateNormal];
        }
    };

    menuButton.menu = [self menuForItem:item
                           currentValue:currentValue
                             menuButton:menuButton
                            titleUpdate:applyMenuSelectionTitle];

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[menuButton]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    NSString *subtitle = item[@"subtitle"];
    if (subtitle.length) {
        [stack addArrangedSubview:[self controlSubtitleLabelWithText:subtitle]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)switchControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[[self configuredToggleForItem:item]]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:[self controlSubtitleLabelWithText:item[@"subtitle"]]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)sliderControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    NSNumber *stored = LGReadPreference(item[@"key"], item[@"default"]);
    CGFloat minValue = [item[@"min"] doubleValue];
    CGFloat maxValue = [item[@"max"] doubleValue];
    NSInteger decimals = [item[@"decimals"] integerValue];
    NSString *subtitle = item[@"subtitle"];

    UISlider *slider = [[LGPrefsSliderClass() alloc] initWithFrame:CGRectZero];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = [stored doubleValue];
    slider.minimumTrackTintColor = _accentColor;

    UILabel *valueLabel = [self sliderValueLabelForStoredValue:stored
                                                      decimals:decimals
                                                          item:item
                                                      subtitle:subtitle
                                                      minValue:minValue
                                                      maxValue:maxValue
                                                        slider:slider];
    UIButton *infoButton = [self sliderInfoButtonForItem:item
                                                subtitle:subtitle
                                                minValue:minValue
                                                maxValue:maxValue
                                                decimals:decimals];
    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[valueLabel, infoButton]
                                                     spacing:8.0];

    NSString *preferenceKey = item[@"key"];
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        valueLabel.text = LGFormatSliderValue(sender.value, decimals);
    }] forControlEvents:UIControlEventValueChanged];
    UIControlEvents commitEvents = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel;
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UISlider *sender = (UISlider *)action.sender;
        CGFloat value = sender.value;
        valueLabel.text = LGFormatSliderValue(value, decimals);
        LGWritePreference(preferenceKey, @(value));
    }] forControlEvents:commitEvents];

    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:slider];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)stringControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    button.contentEdgeInsets = UIEdgeInsetsZero;
    #pragma clang diagnostic pop

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.userInteractionEnabled = NO;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    NSString *preferenceKey = item[@"key"];
    NSString *fallback = item[@"default"];
    id storedObject = LGReadPreferenceObject(preferenceKey, fallback);
    NSString *stored = [storedObject isKindOfClass:[NSString class]] ? storedObject : fallback;

    UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    valueLabel.text = stored.length ? stored : fallback;
    valueLabel.font = [UIFont monospacedSystemFontOfSize:15.0 weight:UIFontWeightSemibold];
    valueLabel.textColor = _accentColor;
    valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    objc_setAssociatedObject(valueLabel, kLGPreferenceKeyKey, preferenceKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(valueLabel, kLGDefaultValueKey, fallback, OBJC_ASSOCIATION_COPY_NONATOMIC);

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [chevron.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [chevron.heightAnchor constraintEqualToConstant:20.0].active = YES;

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[chevron, valueLabel]
                                                     spacing:8.0];
    [stack addArrangedSubview:headerRow];
    NSString *subtitle = item[@"subtitle"];
    if (subtitle.length) {
        [stack addArrangedSubview:[self controlSubtitleLabelWithText:subtitle]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [valueLabel.widthAnchor constraintLessThanOrEqualToConstant:150.0],
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];

    [button addSubview:body];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:button.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    __weak UILabel *weakValueLabel = valueLabel;
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *current = weakValueLabel.text.length ? weakValueLabel.text : fallback;
        LGPresentTextInputSheet(strongSelf,
                                item[@"title"],
                                item[@"subtitle"],
                                current,
                                item[@"placeholder"],
                                UIKeyboardTypeASCIICapable,
                                YES,
                                ^(NSString *inputText) {
            NSString *text = inputText ?: @"";
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!text.length) text = fallback ?: @"";
            weakValueLabel.text = text;
            LGWritePreferenceObject(preferenceKey, text);
        });
    }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UITextField *)customClassFilterTextFieldForField:(NSDictionary *)field {
    NSString *preferenceKey = field[@"key"];
    NSString *stored = LGReadPreferenceObject(preferenceKey, @"");
    if (![stored isKindOfClass:NSString.class]) stored = @"";

    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
    textField.translatesAutoresizingMaskIntoConstraints = NO;
    textField.text = stored;
    textField.placeholder = field[@"placeholder"];
    textField.textColor = UIColor.labelColor;
    textField.tintColor = _accentColor;
    textField.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    textField.textAlignment = NSTextAlignmentRight;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.smartDashesType = UITextSmartDashesTypeNo;
    textField.smartQuotesType = UITextSmartQuotesTypeNo;
    textField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    textField.keyboardType = UIKeyboardTypeASCIICapable;
    textField.returnKeyType = UIReturnKeyDone;
    objc_setAssociatedObject(textField, kLGPreferenceKeyKey, preferenceKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textField, kLGDefaultValueKey, @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    [textField addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        UITextField *sender = (UITextField *)action.sender;
        NSString *key = objc_getAssociatedObject(sender, kLGPreferenceKeyKey);
        NSString *text = [sender.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) {
            LGWritePreferenceObject(key, text);
        } else {
            LGRemovePreference(key);
        }
    }] forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
    return textField;
}

- (UIView *)customClassFiltersBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    [stack addArrangedSubview:titleLabel];
    NSString *subtitle = item[@"subtitle"];
    if (subtitle.length) {
        [stack addArrangedSubview:[self controlSubtitleLabelWithText:subtitle]];
    }

    NSArray<NSDictionary *> *fields = item[@"fields"];
    UIStackView *fieldStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    fieldStack.axis = UILayoutConstraintAxisVertical;
    fieldStack.spacing = 7.0;
    fieldStack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:fieldStack];

    for (NSDictionary *field in fields) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        row.layer.cornerRadius = 12.0;
        row.layer.cornerCurve = kCACornerCurveContinuous;
        row.layer.masksToBounds = YES;

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = field[@"title"];
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        label.textColor = UIColor.labelColor;
        [row addSubview:label];

        UITextField *textField = [self customClassFilterTextFieldForField:field];
        [row addSubview:textField];

        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintGreaterThanOrEqualToConstant:42.0],
            [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
            [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [label.widthAnchor constraintEqualToConstant:126.0],
            [textField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10.0],
            [textField.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12.0],
            [textField.topAnchor constraintEqualToAnchor:row.topAnchor constant:6.0],
            [textField.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-6.0],
        ]];
        [fieldStack addArrangedSubview:row];
    }

    UILabel *hint = [self controlSubtitleLabelWithText:LGLocalized(@"prefs.custom_views.class_filters.hint")];
    [stack addArrangedSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];
    return body;
}

- (UIView *)navControlBodyForItem:(NSDictionary *)item titleLabel:(UILabel *)titleLabel {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    button.contentEdgeInsets = UIEdgeInsetsZero;
    #pragma clang diagnostic pop
    NSString *actionName = item[@"action"];
    if (actionName.length) {
        SEL action = NSSelectorFromString(actionName);
        if ([self respondsToSelector:action]) {
            [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        }
    }
    objc_setAssociatedObject(button, kLGPanelItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *body = [[UIView alloc] initWithFrame:CGRectZero];
    body.userInteractionEnabled = NO;
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 9.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:stack];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [chevron.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [chevron.heightAnchor constraintEqualToConstant:20.0].active = YES;

    UIView *headerRow = [self controlHeaderRowWithTitleLabel:titleLabel
                                              accessoryViews:@[chevron]
                                                     spacing:12.0];
    [stack addArrangedSubview:headerRow];
    [stack addArrangedSubview:[self controlSubtitleLabelWithText:item[@"subtitle"]]];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:body.topAnchor constant:13.0],
        [stack.leadingAnchor constraintEqualToAnchor:body.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:body.trailingAnchor constant:-14.0],
        [stack.bottomAnchor constraintEqualToAnchor:body.bottomAnchor constant:-13.0],
    ]];

    [button addSubview:body];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:button.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:button.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:button.bottomAnchor],
    ]];
    return button;
}

- (UIView *)controlBodyForItem:(NSDictionary *)item {
    UILabel *titleLabel = [self controlTitleLabelForItem:item];
    if ([item[@"type"] isEqualToString:@"nav"]) {
        return [self navControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"menu"]) {
        return [self menuControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"switch"]) {
        return [self switchControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"string"]) {
        return [self stringControlBodyForItem:item titleLabel:titleLabel];
    }
    if ([item[@"type"] isEqualToString:@"custom_class_filters"]) {
        return [self customClassFiltersBodyForItem:item titleLabel:titleLabel];
    }
    return [self sliderControlBodyForItem:item titleLabel:titleLabel];
}

- (UIView *)groupedPanelForItems:(NSArray<NSDictionary *> *)items {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = LGSubpageCardBackgroundColor();
    card.layer.cornerRadius = 23.25;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    for (NSUInteger i = 0; i < items.count; i++) {
        UIView *body = [self controlBodyForItem:items[i]];
        objc_setAssociatedObject(body, kLGPanelItemKey, items[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stack addArrangedSubview:body];
        if (i + 1 < items.count) {
            UIView *dividerRow = [[UIView alloc] initWithFrame:CGRectZero];
            dividerRow.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *divider = LGMakeSectionDivider();
            [dividerRow addSubview:divider];
            [NSLayoutConstraint activateConstraints:@[
                [divider.leadingAnchor constraintEqualToAnchor:dividerRow.leadingAnchor constant:14.0],
                [divider.trailingAnchor constraintEqualToAnchor:dividerRow.trailingAnchor constant:-14.0],
                [divider.centerYAnchor constraintEqualToAnchor:dividerRow.centerYAnchor],
            ]];
            [stack addArrangedSubview:dividerRow];
        }
    }

    return card;
}

- (void)appendSurfaceGroupItems:(NSArray<NSDictionary *> *)items {
    if (!items.count) return;
    NSUInteger startIndex = 0;
    NSDictionary *fpsItem = nil;
    NSDictionary *enabledItem = nil;

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        NSString *type = candidate[@"type"];
        NSString *key = candidate[@"key"];
        if ([type isEqualToString:@"slider"] && [key hasSuffix:@".FPS"]) {
            fpsItem = candidate;
            startIndex += 1;
        }
    }

    if (startIndex < items.count) {
        NSDictionary *candidate = items[startIndex];
        if ([candidate[@"type"] isEqualToString:@"switch"]
            && [candidate[@"controls_following_panel"] boolValue]) {
            enabledItem = candidate;
            startIndex += 1;
        }
    }

    if (fpsItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[fpsItem]]];
    }

    if (enabledItem) {
        [_contentStack addArrangedSubview:[self groupedPanelForItems:@[enabledItem]]];
    }

    if (startIndex >= items.count) return;

    NSArray<NSDictionary *> *panelItems = [items subarrayWithRange:NSMakeRange(startIndex, items.count - startIndex)];
    UIView *panel = [self groupedPanelForItems:panelItems];
    NSString *controllerKey = enabledItem[@"key"];
    id controllerDefault = enabledItem[@"default"];
    if (!controllerKey.length) {
        controllerKey = panelItems.firstObject[@"enabled_key"];
        controllerDefault = panelItems.firstObject[@"enabled_default"];
    }
    BOOL enabled = controllerKey.length ? [LGReadPreference(controllerKey, controllerDefault ?: @YES) boolValue] : YES;
    if (controllerKey.length) {
        objc_setAssociatedObject(panel, kLGControlledByEnabledKey, controllerKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    panel.alpha = enabled ? 1.0 : 0.42;
    panel.userInteractionEnabled = enabled;
    [_contentStack addArrangedSubview:panel];
}

@end
