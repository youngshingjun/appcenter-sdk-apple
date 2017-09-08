#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import "MSNSAppDelegate.h"
#else
#import <UIKit/UIKit.h>
#import "MSUIAppDelegate.h"
#endif

#import "MSAppDelegateForwarderPrivate.h"
#import "MSLogger.h"
#import "MSMobileCenterInternal.h"
#import "MSUtility+Application.h"

static NSString *const kMSCustomSelectorPrefix = @"custom_";
static NSString *const kMSReturnedValueSelectorPart = @"returnedValue:";
static NSString *const kMSIsAppDelegateForwarderEnabledKey = @"MobileCenterAppDelegateForwarderEnabled";

// Original selectors with special handling.
static NSString *const kMSDidReceiveRemoteNotificationFetchHandler =
    @"application:didReceiveRemoteNotification:fetchCompletionHandler:";
static NSString *const kMSOpenURLSourceApplicationAnnotation = @"application:openURL:sourceApplication:annotation:";
static NSString *const kMSOpenURLOptions = @"application:openURL:options:";

static NSHashTable<id<MSAppDelegate>> *_delegates = nil;
static NSMutableSet<NSString *> *_selectorsToSwizzle = nil;
static NSArray<NSString *> *_selectorsNotToOverride = nil;
static NSDictionary<NSString *, NSString *> *_deprecatedSelectors = nil;
static NSMutableDictionary<NSString *, NSValue *> *_originalImplementations = nil;
static NSMutableArray<dispatch_block_t> *_traceBuffer = nil;
static IMP _originalSetDelegateImp = NULL;
static BOOL _enabled = YES;

@implementation MSAppDelegateForwarder

+ (void)load {

  /*
   * The application starts querying its delegate for its implementation as soon as it is set then may never query
   * again. It means that if the application delegate doesn't implement an optional method of the
   * `UIApplicationDelegate` protocol at that time then that method may never be called even if added later via
   * swizzling. This is why the application delegate swizzling should happen at the time it is set to the application
   * object.
   */
  NSDictionary *appForwarderEnabledNum =
      [[NSBundle mainBundle] objectForInfoDictionaryKey:kMSIsAppDelegateForwarderEnabledKey];
  BOOL appForwarderEnabled = appForwarderEnabledNum ? [((NSNumber *)appForwarderEnabledNum)boolValue] : YES;
  MSAppDelegateForwarder.enabled = appForwarderEnabled;

  // Swizzle `setDelegate:` of Application class.
  if (MSAppDelegateForwarder.enabled) {
    [MSAppDelegateForwarder.traceBuffer addObject:^{
      MSLogDebug([MSMobileCenter logTag], @"Application delegate forwarder is enabled. It may use swizzling.");
    }];
  } else {
    [MSAppDelegateForwarder.traceBuffer addObject:^{
      MSLogDebug([MSMobileCenter logTag], @"Application delegate forwarder is disabled. It won't use swizzling.");
    }];
  }
}

+ (instancetype)sharedInstance {
  static MSAppDelegateForwarder *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [self new];
  });
  return sharedInstance;
}

#pragma mark - Accessors

+ (NSHashTable<id<MSAppDelegate>> *)delegates {
  return _delegates ?: (_delegates = [NSHashTable weakObjectsHashTable]);
}

+ (void)setDelegates:(NSHashTable<id<MSAppDelegate>> *)delegates {
  _delegates = delegates;
}

+ (NSMutableSet<NSString *> *)selectorsToSwizzle {
  return _selectorsToSwizzle ?: (_selectorsToSwizzle = [NSMutableSet new]);
}

+ (NSArray<NSString *> *)selectorsNotToOverride {
  if (!_selectorsNotToOverride) {
#if !TARGET_OS_OSX
    _selectorsNotToOverride = @[ kMSDidReceiveRemoteNotificationFetchHandler ];
#endif
  }
  return _selectorsNotToOverride;
}

+ (NSDictionary<NSString *, NSString *> *)deprecatedSelectors {
  if (!_deprecatedSelectors) {
#if TARGET_OS_OSX
    _deprecatedSelectors = @{};
#else
    _deprecatedSelectors = @{kMSOpenURLOptions : kMSOpenURLSourceApplicationAnnotation};
#endif
  }
  return _deprecatedSelectors;
}

+ (NSMutableDictionary<NSString *, NSValue *> *)originalImplementations {
  return _originalImplementations ?: (_originalImplementations = [NSMutableDictionary new]);
}

+ (NSMutableArray<dispatch_block_t> *)traceBuffer {
  return _traceBuffer ?: (_traceBuffer = [NSMutableArray new]);
}

+ (IMP)originalSetDelegateImp {
  return _originalSetDelegateImp;
}

+ (void)setOriginalSetDelegateImp:(IMP)originalSetDelegateImp {
  _originalSetDelegateImp = originalSetDelegateImp;
}

+ (BOOL)enabled {
  @synchronized(self) {
    return _enabled;
  }
}

+ (void)setEnabled:(BOOL)enabled {
  @synchronized(self) {
    _enabled = enabled;
    if (!enabled) {
      [self.delegates removeAllObjects];
    }
  }
}

#pragma mark - Delegates

+ (void)addDelegate:(id<MSAppDelegate>)delegate {
  @synchronized(self) {
    if (self.enabled) {
      [self.delegates addObject:delegate];
    }
  }
}

+ (void)removeDelegate:(id<MSAppDelegate>)delegate {
  @synchronized(self) {
    if (self.enabled) {
      [self.delegates removeObject:delegate];
    }
  }
}

#pragma mark - Swizzling

+ (void)swizzleOriginalDelegate:(id<MSApplicationDelegate>)originalDelegate {
  IMP originalImp = NULL;
  Class delegateClass = [originalDelegate class];
  SEL originalSelector, customSelector;

  // Swizzle all registered selectors.
  for (NSString *selectorString in self.selectorsToSwizzle) {
    originalSelector = NSSelectorFromString(selectorString);
    customSelector = NSSelectorFromString([kMSCustomSelectorPrefix stringByAppendingString:selectorString]);
    originalImp =
        [self swizzleOriginalSelector:originalSelector withCustomSelector:customSelector originalClass:delegateClass];
    if (originalImp) {

      // Save the original implementation for later use.
      MSAppDelegateForwarder.originalImplementations[selectorString] =
          [NSValue valueWithBytes:&originalImp objCType:@encode(IMP)];
    }
  }
  [self.selectorsToSwizzle removeAllObjects];
}

+ (IMP)swizzleOriginalSelector:(SEL)originalSelector
            withCustomSelector:(SEL)customSelector
                 originalClass:(Class)originalClass {

  // Replace original implementation
  NSString *originalSelectorStr = NSStringFromSelector(originalSelector);
  Method originalMethod = class_getInstanceMethod(originalClass, originalSelector);
  IMP customImp = class_getMethodImplementation(self, customSelector);
  IMP originalImp = NULL;
  BOOL methodAdded = NO;
  BOOL skipped = NO;
  NSString *warningMsg;
  NSString *remediationMsg = @"You need to explicitly call the Mobile Center API"
                             @" from your app delegate implementation.";

  // Replace original implementation by the custom one.
  if (originalMethod) {

    /*
     * Also, some selectors should not be overridden mostly because the original implementation highly
     * depend on the SDK return value for its own logic so customers already have to call the SDK API
     * in their implementation which makes swizzling useless.
     */
    if (![self.selectorsNotToOverride containsObject:originalSelectorStr]) {
      originalImp = method_setImplementation(originalMethod, customImp);
    } else {
      warningMsg =
          [NSString stringWithFormat:@"This selector is not supported when already implemented. %@", remediationMsg];
    }
  } else if (![originalClass instancesRespondToSelector:originalSelector]) {

    // Check for deprecation.
    NSString *deprecatedSelectorStr = self.deprecatedSelectors[originalSelectorStr];
    if (deprecatedSelectorStr &&
        [originalClass instancesRespondToSelector:NSSelectorFromString(deprecatedSelectorStr)]) {

      /*
       * An implementation for the deprecated selector exists. Don't add the new method, it might eclipse the original
       * implementation.
       */
      warningMsg = [NSString
          stringWithFormat:
              @"No implementation found for this selector, though an implementation of its deprecated API '%@' exists.",
              deprecatedSelectorStr];
    } else {

      // Skip this selector if it's deprecated and doesn't have an implementation.
      if ([self.deprecatedSelectors.allValues containsObject:originalSelectorStr]) {
        skipped = YES;
      } else {

        /*
         * The original class may not implement the selector (e.g.: optional method from protocol),
         * add the method to the original class and associate it with the custom implementation.
         */
        Method customMethod = class_getInstanceMethod(self, customSelector);
        methodAdded = class_addMethod(originalClass, originalSelector, customImp, method_getTypeEncoding(customMethod));
      }
    }
  }

  /*
   * If class instances respond to the selector but no implementation is found it's likely that the original class
   * is doing message forwarding, in this case we can't add our implementation to the class or we will break the
   * forwarding.
   */

  // Validate swizzling.
  if (!skipped) {
    if (!originalImp && !methodAdded) {
      [self.traceBuffer addObject:^{
        NSString *message = [NSString
            stringWithFormat:@"Cannot swizzle selector '%@' of class '%@'.", originalSelectorStr, originalClass];
        if (warningMsg) {
          MSLogWarning([MSMobileCenter logTag], @"%@ %@", message, warningMsg);
        } else {
          MSLogError([MSMobileCenter logTag], @"%@ %@", message, remediationMsg);
        }
      }];
    } else {
      [self.traceBuffer addObject:^{
        MSLogDebug([MSMobileCenter logTag], @"Selector '%@' of class '%@' is swizzled.", originalSelectorStr,
                   originalClass);
      }];
    }
  }
  return originalImp;
}

+ (void)addAppDelegateSelectorToSwizzle:(SEL)selector {
  if (self.enabled) {

    // Swizzle only once and only if needed. No selector to swizzle then no swizzling at all.
    static dispatch_once_t appSwizzleOnceToken;
    dispatch_once(&appSwizzleOnceToken, ^{
      MSAppDelegateForwarder.originalSetDelegateImp =
          [MSAppDelegateForwarder swizzleOriginalSelector:@selector(setDelegate:)
                                       withCustomSelector:@selector(custom_setDelegate:)
#if TARGET_OS_OSX
                                            originalClass:[NSApplication class]];
#else
                                            originalClass:[UIApplication class]];
#endif
    });

    /*
     * TODO: We could register custom delegate classes and then query those classes if they responds to selector.
     * If so just add that selector to be swizzled. Just make sure it doesn't have an heavy impact on performances.
     */
    [self.selectorsToSwizzle addObject:NSStringFromSelector(selector)];
  }
}

#pragma mark - Custom Application

- (void)custom_setDelegate:(id<MSApplicationDelegate>)delegate {

  // Swizzle only once.
  static dispatch_once_t delegateSwizzleOnceToken;
  dispatch_once(&delegateSwizzleOnceToken, ^{

    // Swizzle the app delegate before it's actually set.
    [MSAppDelegateForwarder swizzleOriginalDelegate:delegate];
  });

  // Forward to the original `setDelegate:` implementation.
  IMP originalImp = MSAppDelegateForwarder.originalSetDelegateImp;
  if (originalImp) {
    ((void (*)(id, SEL, id<MSApplicationDelegate>))originalImp)(self, _cmd, delegate);
  }
}

#pragma mark - Custom UIApplicationDelegate

#if !TARGET_OS_OSX
/*
 * Those methods will never get called but their implementation will be used by swizzling.
 * Those implementations will run within the delegate context. Meaning that `self` will point
 * to the original app delegate and not this forwarder.
 */
- (BOOL)custom_application:(UIApplication *)application
                   openURL:(NSURL *)url
         sourceApplication:(nullable NSString *)sourceApplication
                annotation:(id)annotation {
  BOOL result = NO;
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
    result = ((BOOL(*)(id, SEL, UIApplication *, NSURL *, NSString *, id))originalImp)(self, _cmd, application, url,
                                                                                       sourceApplication, annotation);
  }

  // Forward to custom delegates.
  return [[MSAppDelegateForwarder sharedInstance] application:application
                                                      openURL:url
                                            sourceApplication:sourceApplication
                                                   annotation:annotation
                                                returnedValue:result];
}

- (BOOL)custom_application:(UIApplication *)application
                   openURL:(nonnull NSURL *)url
                   options:(nonnull NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
  BOOL result = NO;
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
    result =
        ((BOOL(*)(id, SEL, UIApplication *, NSURL *, NSDictionary<UIApplicationOpenURLOptionsKey, id> *))originalImp)(
            self, _cmd, application, url, options);
  }

  // Forward to custom delegates.
  return [[MSAppDelegateForwarder sharedInstance] application:application
                                                      openURL:url
                                                      options:options
                                                returnedValue:result];
}
#endif

#if TARGET_OS_OSX
- (void)custom_application:(NSApplication *)application
#else
- (void)custom_application:(UIApplication *)application
#endif
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
#if TARGET_OS_OSX
    ((void (*)(id, SEL, NSApplication *, NSData *))originalImp)(self, _cmd, application, deviceToken);
#else
    ((void (*)(id, SEL, UIApplication *, NSData *))originalImp)(self, _cmd, application, deviceToken);
#endif
  }

  // Forward to custom delegates.
  [[MSAppDelegateForwarder sharedInstance] application:application
      didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

#if TARGET_OS_OSX
- (void)custom_application:(NSApplication *)application
#else
- (void)custom_application:(UIApplication *)application
#endif
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
#if TARGET_OS_OSX
    ((void (*)(id, SEL, NSApplication *, NSError *))originalImp)(self, _cmd, application, error);
#else
    ((void (*)(id, SEL, UIApplication *, NSError *))originalImp)(self, _cmd, application, error);
#endif
  }

  // Forward to custom delegates.
  [[MSAppDelegateForwarder sharedInstance] application:application
      didFailToRegisterForRemoteNotificationsWithError:error];
}

#if TARGET_OS_OSX
- (void)custom_application:(NSApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
#else
- (void)custom_application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo {
#endif
  IMP originalImp = NULL;

  // Forward to the original delegate.
  [MSAppDelegateForwarder.originalImplementations[NSStringFromSelector(_cmd)] getValue:&originalImp];
  if (originalImp) {
#if TARGET_OS_OSX
    ((void (*)(id, SEL, NSApplication *, NSDictionary *))originalImp)(self, _cmd, application, userInfo);
#else
    ((void (*)(id, SEL, UIApplication *, NSDictionary *))originalImp)(self, _cmd, application, userInfo);
#endif
  }

  // Forward to custom delegates.
  [[MSAppDelegateForwarder sharedInstance] application:application didReceiveRemoteNotification:userInfo];
}

#if !TARGET_OS_OSX
- (void)custom_application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

  // Collect `UIBackgroundFetchResult` from delegates in order to call the original completion handler later.
  __block UIBackgroundFetchResult forwardedFetchResult = UIBackgroundFetchResultNoData;
  void (^forwardedCompletionHandler)(UIBackgroundFetchResult) = ^(UIBackgroundFetchResult fetchResult) {
    forwardedFetchResult = fetchResult;
  };

  /*
   * FIXME: We still need to chain the forwardedFetchResult somehow in case of multiple custom delegate implementing
   * this selector.
   */

  /*
   * Forward to custom delegates. This method doesn't override original the delegate implementation so there is no need
   * to forward to the original implementation. As a consequence customers must call the corresponding APIs in the SDK
   * if they implement this selector in their delegate.
   */
  [[MSAppDelegateForwarder sharedInstance] application:application
                          didReceiveRemoteNotification:userInfo
                                fetchCompletionHandler:forwardedCompletionHandler];

  // Must call the original completion handler.
  completionHandler(forwardedFetchResult);
}
#endif

#pragma mark - Forwarding

- (void)forwardInvocation:(NSInvocation *)invocation {
  @synchronized([self class]) {
    BOOL forwarded = NO;
    BOOL hasReturnedValue = ([NSStringFromSelector(invocation.selector) hasSuffix:kMSReturnedValueSelectorPart]);
    NSUInteger returnedValueIdx = NULL;
    void *returnedValuePtr = NULL;

    // Prepare returned value if any.
    if (hasReturnedValue) {

      // Returned value argument is always the last one.
      returnedValueIdx = invocation.methodSignature.numberOfArguments - 1;
      returnedValuePtr = malloc(invocation.methodSignature.methodReturnLength);
    }

    // Forward to delegates executing a custom method.
    for (id<MSAppDelegate> delegate in [self class].delegates) {
      if ([delegate respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:delegate];

        // Chaining return values.
        if (hasReturnedValue) {
          [invocation getReturnValue:returnedValuePtr];
          [invocation setArgument:returnedValuePtr atIndex:returnedValueIdx];
        }
        forwarded = YES;
      }
    }

    // Forward back the original return value if no delegates to receive the message.
    if (hasReturnedValue && !forwarded) {
      [invocation getArgument:returnedValuePtr atIndex:returnedValueIdx];
      [invocation setReturnValue:returnedValuePtr];
    }
    free(returnedValuePtr);
  }
}

#pragma mark - Logging

+ (void)flushTraceBuffer {

  // Only trace once.
  static dispatch_once_t traceOnceToken;
  dispatch_once(&traceOnceToken, ^{
    for (dispatch_block_t traceBlock in self.traceBuffer) {
      traceBlock();
    }
    [self.traceBuffer removeAllObjects];
  });
}

#pragma mark - Testing

+ (void)reset {
  [self.delegates removeAllObjects];
  [self.originalImplementations removeAllObjects];
  [self.selectorsToSwizzle removeAllObjects];
}

@end
