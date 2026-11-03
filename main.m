/*
Copyright (C) 2025 Serge Alagon

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "FloatingButtonWindow.h"
#import "PrivateHeaders.h"

static BOOL isImmortalized;
static BOOL isPhysicallyInBackground = NO;
static BOOL appInactive = NO;

static void prefsChanged() {
    isImmortalized = [[NSUserDefaults standardUserDefaults] boolForKey:@"immortalized"];
}

static void (*original_sceneID_updateWithSettingsDiff_transitionContext_completion)(id, SEL, id, id, id, id);

/* thanks to @khanhduytran0 for this wonderful hook. goat */
void new_sceneID_updateWithSettingsDiff_transitionContext_completion(id self, SEL _cmd, id arg1, id arg2, id arg3, id arg4) {
    if (!isImmortalized) {
        return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
    }

    NSString *diffDescription = [arg2 description];

    if ([diffDescription containsString:@"foreground = NotSet"] ||
        [diffDescription containsString:@"foreground = No"] ||
        [diffDescription containsString:@"foreground = BSSettingFlagNo"] ||
        [diffDescription containsString:@"foreground = NO"]) {
        return;
    }

    if ([diffDescription containsString:@"hostContextIdentifierForSnapshotting = 0"] ||
        [diffDescription containsString:@"scenePresenterRenderIdentifierForSnapshotting = 0"] ||
        [diffDescription containsString:@"targetOfEventDeferringEnvironments = (empty)"]) {
        return;
    }

    if ([diffDescription containsString:@"FBSceneSnapshotAction:"]) {
        return;
    }

    return original_sceneID_updateWithSettingsDiff_transitionContext_completion(self, _cmd, arg1, arg2, arg3, arg4);
}

// MARK: - Notification & Background Overrides

static UIApplicationState (*orig_applicationState)(id, SEL);

static UIApplicationState hook_applicationState(id self, SEL _cmd) {
    if (isPhysicallyInBackground) {
        void *returnAddress = __builtin_extract_return_addr(__builtin_return_address(0));
        Dl_info info;
        if (dladdr(returnAddress, &info) && info.dli_fname) {
            NSString *imageName = [NSString stringWithUTF8String:info.dli_fname];
            if ([imageName containsString:@"UserNotifications"] || [imageName containsString:@"PushKit"]) {
                return UIApplicationStateBackground;
            }
        }
        return UIApplicationStateActive;
    }
    return orig_applicationState ? orig_applicationState(self, _cmd) : UIApplicationStateActive;
}

static void (*orig_willPresent)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions));

static void hook_willPresent(id self, SEL _cmd, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions options)) {
    if (isPhysicallyInBackground) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge);
    } else if (orig_willPresent) {
        orig_willPresent(self, _cmd, center, notification, completionHandler);
    }
}

static void (*orig_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);

static void hook_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (orig_setDelegate) orig_setDelegate(self, _cmd, delegate);

    if (delegate) {
        Class delegateClass = [delegate class];
        SEL sel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        Method method = class_getInstanceMethod(delegateClass, sel);
        if (method) {
            IMP currentIMP = method_getImplementation(method);
            if (currentIMP != (IMP)hook_willPresent) {
                orig_willPresent = (void *)currentIMP;
                method_setImplementation(method, (IMP)hook_willPresent);
            }
        }
    }
}

// MARK: - Drop "leaving" notifications so apps don't pause themselves

static BOOL shouldDrop(NSString *name) {
    if (!isImmortalized || !name) return NO;

    BOOL leaving = [name isEqualToString:UIApplicationWillResignActiveNotification] ||
                   [name isEqualToString:UIApplicationDidEnterBackgroundNotification] ||
                   [name isEqualToString:UISceneWillDeactivateNotification] ||
                   [name isEqualToString:UISceneDidEnterBackgroundNotification];
    if (!leaving) return NO;

    appInactive = YES;
    if ([name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        isPhysicallyInBackground = YES;
    }
    return YES;
}

static void (*orig_postNotification)(id, SEL, NSNotification *);
static void hook_postNotification(id self, SEL _cmd, NSNotification *n) {
    if (shouldDrop(n.name)) return;
    orig_postNotification(self, _cmd, n);
}

static void (*orig_postNameObject)(id, SEL, NSNotificationName, id);
static void hook_postNameObject(id self, SEL _cmd, NSNotificationName name, id obj) {
    if (shouldDrop(name)) return;
    orig_postNameObject(self, _cmd, name, obj);
}

static void (*orig_postNameObjectInfo)(id, SEL, NSNotificationName, id, NSDictionary *);
static void hook_postNameObjectInfo(id self, SEL _cmd, NSNotificationName name, id obj, NSDictionary *info) {
    if (shouldDrop(name)) return;
    orig_postNameObjectInfo(self, _cmd, name, obj, info);
}

// MARK: - Ignore pause / audio session off while the app is leaving

static void (*orig_pause)(id, SEL);
static void hook_pause(id self, SEL _cmd) {
    if (isImmortalized && appInactive) return;
    orig_pause(self, _cmd);
}

static void (*orig_setRate)(id, SEL, float);
static void hook_setRate(id self, SEL _cmd, float rate) {
    if (isImmortalized && appInactive && rate == 0) return;
    orig_setRate(self, _cmd, rate);
}

static BOOL (*orig_setActive)(id, SEL, BOOL, NSError **);
static BOOL hook_setActive(id self, SEL _cmd, BOOL active, NSError **err) {
    if (isImmortalized && appInactive && !active) return YES;
    return orig_setActive(self, _cmd, active, err);
}

static BOOL (*orig_setActiveOpts)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL hook_setActiveOpts(id self, SEL _cmd, BOOL active, NSUInteger opts, NSError **err) {
    if (isImmortalized && appInactive && !active) return YES;
    return orig_setActiveOpts(self, _cmd, active, opts, err);
}

// MARK: - Setup

static void hookMethod(Class cls, SEL sel, IMP newImp, void **origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *origOut = (void *)method_getImplementation(m);
        method_setImplementation(m, newImp);
    }
}

static void setup() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. Scene Hook
        Class targetClass = objc_getClass("FBSWorkspaceScenesClient");
        SEL originalSelector = @selector(sceneID:updateWithSettingsDiff:transitionContext:completion:);
        Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
        if (originalMethod) {
            original_sceneID_updateWithSettingsDiff_transitionContext_completion = (void (*)(id, SEL, id, id, id, id))method_getImplementation(originalMethod);
            method_setImplementation(originalMethod, (IMP)new_sceneID_updateWithSettingsDiff_transitionContext_completion);
        }

        // 2. Application State Hook
        hookMethod(objc_getClass("UIApplication"), @selector(applicationState), (IMP)hook_applicationState, (void **)&orig_applicationState);

        // 3. Notification Delegate Hook
        hookMethod(objc_getClass("UNUserNotificationCenter"), @selector(setDelegate:), (IMP)hook_setDelegate, (void **)&orig_setDelegate);

        // 4. Drop "leaving" notifications while immortalized
        Class ncClass = objc_getClass("NSNotificationCenter");
        hookMethod(ncClass, @selector(postNotification:), (IMP)hook_postNotification, (void **)&orig_postNotification);
        hookMethod(ncClass, @selector(postNotificationName:object:), (IMP)hook_postNameObject, (void **)&orig_postNameObject);
        hookMethod(ncClass, @selector(postNotificationName:object:userInfo:), (IMP)hook_postNameObjectInfo, (void **)&orig_postNameObjectInfo);

        // 5. Ignore pause / audio session off while leaving
        Class playerClass = objc_getClass("AVPlayer");
        hookMethod(playerClass, @selector(pause), (IMP)hook_pause, (void **)&orig_pause);
        hookMethod(playerClass, @selector(setRate:), (IMP)hook_setRate, (void **)&orig_setRate);

        Class sessionClass = objc_getClass("AVAudioSession");
        hookMethod(sessionClass, @selector(setActive:error:), (IMP)hook_setActive, (void **)&orig_setActive);
        hookMethod(sessionClass, @selector(setActive:withOptions:error:), (IMP)hook_setActiveOpts, (void **)&orig_setActiveOpts);

        // 6. Track foreground state
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
            isPhysicallyInBackground = NO;
        }];

        // PATCH: when the app comes back, reset state and re-show the floating button
        void (^reactivated)(NSNotification *) = ^(NSNotification * _Nonnull note) {
            appInactive = NO;
            isPhysicallyInBackground = NO;
            [[FloatingButtonWindow sharedInstance] showButton];
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:reactivated];
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:reactivated];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)prefsChanged, CFSTR("com.sergy.immortalizerjailed.updateprefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        [[FloatingButtonWindow sharedInstance] showButton];
    });
}

__attribute__((constructor)) static void initialize() {
    prefsChanged();
    setup();
}
