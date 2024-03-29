// Copyright 2004-present Facebook. All Rights Reserved.

#import "RCTBridge.h"

#import <dlfcn.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "RCTConvert.h"
#import "RCTInvalidating.h"
#import "RCTEventDispatcher.h"
#import "RCTLog.h"
#import "RCTUtils.h"

/**
 * Must be kept in sync with `MessageQueue.js`.
 */
typedef NS_ENUM(NSUInteger, RCTBridgeFields) {
  RCTBridgeFieldRequestModuleIDs = 0,
  RCTBridgeFieldMethodIDs,
  RCTBridgeFieldParamss,
  RCTBridgeFieldResponseCBIDs,
  RCTBridgeFieldResponseReturnValues,
  RCTBridgeFieldFlushDateMillis
};

/**
 * This private class is used as a container for exported method info
 */
@interface RCTModuleMethod : NSObject

@property (readonly, nonatomic, assign) SEL selector;
@property (readonly, nonatomic, copy) NSString *JSMethodName;
@property (readonly, nonatomic, assign) NSUInteger arity;
@property (readonly, nonatomic, copy) NSIndexSet *blockArgumentIndexes;

@end

@implementation RCTModuleMethod

- (instancetype)initWithSelector:(SEL)selector
                    JSMethodName:(NSString *)JSMethodName
                           arity:(NSUInteger)arity
            blockArgumentIndexes:(NSIndexSet *)blockArgumentIndexes
{
  if ((self = [super init])) {
    _selector = selector;
    _JSMethodName = [JSMethodName copy];
    _arity = arity;
    _blockArgumentIndexes = [blockArgumentIndexes copy];
  }
  return self;
}

- (NSString *)description
{
  NSString *blocks = @"no block args";
  if (self.blockArgumentIndexes.count > 0) {
    NSMutableString *indexString = [NSMutableString string];
    [self.blockArgumentIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      [indexString appendFormat:@", %tu", idx];
    }];
    blocks = [NSString stringWithFormat:@"block args at %@", [indexString substringFromIndex:2]];
  }
  
  return [NSString stringWithFormat:@"<%@: %p; exports -%@ as %@; %@>", NSStringFromClass(self.class), self, NSStringFromSelector(self.selector), self.JSMethodName, blocks];
}

@end

#ifdef __LP64__
typedef uint64_t RCTExportValue;
typedef struct section_64 RCTExportSection;
#define RCTGetSectByNameFromHeader getsectbynamefromheader_64
#else
typedef uint32_t RCTExportValue;
typedef struct section RCTExportSection;
#define RCTGetSectByNameFromHeader getsectbynamefromheader
#endif

/**
 * This function parses the exported methods inside RCTBridgeModules and
 * generates a dictionary of arrays of RCTModuleMethod objects, keyed
 * by module name.
 */
static NSDictionary *RCTExportedMethodsByModule(void)
{
  static NSMutableDictionary *methodsByModule;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    
    Dl_info info;
    dladdr(&RCTExportedMethodsByModule, &info);
    
    const RCTExportValue mach_header = (RCTExportValue)info.dli_fbase;
    const RCTExportSection *section = RCTGetSectByNameFromHeader((void *)mach_header, "__DATA", "RCTExport");
    
    if (section == NULL) {
      return;
    }
    
    methodsByModule = [NSMutableDictionary dictionary];
    NSCharacterSet *plusMinusCharacterSet = [NSCharacterSet characterSetWithCharactersInString:@"+-"];
    
    for (RCTExportValue addr = section->offset;
         addr < section->offset + section->size;
         addr += sizeof(id) * 2) {
      
      const char **entry = (const char **)(mach_header + addr);
      NSScanner *scanner = [NSScanner scannerWithString:@(entry[0])];
      
      NSString *plusMinus;
      if (![scanner scanCharactersFromSet:plusMinusCharacterSet intoString:&plusMinus]) continue;
      if (![scanner scanString:@"[" intoString:NULL]) continue;
      
      NSString *className;
      if (![scanner scanUpToString:@" " intoString:&className]) continue;
      [scanner scanString:@" " intoString:NULL];
      
      NSString *selectorName;
      if (![scanner scanUpToString:@"]" intoString:&selectorName]) continue;
      
      Class class = NSClassFromString(className);
      if (class == Nil) continue;
      
      SEL selector = NSSelectorFromString(selectorName);
      Method method = ([plusMinus characterAtIndex:0] == '+' ? class_getClassMethod : class_getInstanceMethod)(class, selector);
      if (method == nil) continue;
      
      unsigned int argumentCount = method_getNumberOfArguments(method);
      NSMutableIndexSet *blockArgumentIndexes = [NSMutableIndexSet indexSet];
      static const char *blockType = @encode(typeof(^{}));
      for (unsigned int i = 2; i < argumentCount; i++) {
        char *type = method_copyArgumentType(method, i);
        if (!strcmp(type, blockType)) {
          [blockArgumentIndexes addIndex:i - 2];
        }
        free(type);
      }
      
      NSString *JSMethodName = strlen(entry[1]) ? @(entry[1]) : [NSStringFromSelector(selector) componentsSeparatedByString:@":"][0];
      RCTModuleMethod *moduleMethod =
      [[RCTModuleMethod alloc] initWithSelector:selector
                                   JSMethodName:JSMethodName
                                          arity:method_getNumberOfArguments(method) - 2
                           blockArgumentIndexes:blockArgumentIndexes];
      
      NSString *moduleName = [class respondsToSelector:@selector(moduleName)] ? [class moduleName] : className;
      NSArray *moduleMap = methodsByModule[moduleName];
      methodsByModule[moduleName] = (moduleMap != nil) ? [moduleMap arrayByAddingObject:moduleMethod] : @[moduleMethod];
    }
    
  });
  
  return methodsByModule;
}

/**
 * This function scans all classes available at runtime and returns a dictionary
 * of classes that implement the RTCBridgeModule protocol, keyed by module name.
 */
static NSDictionary *RCTBridgeModuleClasses(void)
{
  static NSMutableDictionary *modules;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    modules = [NSMutableDictionary dictionary];
    
    unsigned int classCount;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
      
      Class cls = classes[i];
      
      if (!class_getSuperclass(cls)) {
        // Class has no superclass - it's probably something weird
        continue;
      }
      
      if (![cls conformsToProtocol:@protocol(RCTBridgeModule)]) {
        // Not an RCTBridgeModule
        continue;
      }
      
      // Get module name
      NSString *moduleName = [cls respondsToSelector:@selector(moduleName)] ? [cls moduleName] : NSStringFromClass(cls);
      
      // Check module name is unique
      id existingClass = modules[moduleName];
      RCTCAssert(existingClass == Nil, @"Attempted to register RCTBridgeModule class %@ for the name '%@', but name was already registered by class %@", cls, moduleName, existingClass);
      modules[moduleName] = cls;
    }
    
    free(classes);
  });
  
  return modules;
}

/**
 * This constructs the remote modules configuration data structure,
 * which represents the native modules and methods that will be called
 * by JS. A numeric ID is assigned to each module and method, which will
 * be used to communicate via the bridge. The structure of each
 * module is as follows:
 *
 * "ModuleName1": {
 *   "moduleID": 0,
 *   "methods": {
 *     "methodName1": {
 *       "methodID": 0,
 *       "type": "remote"
 *     },
 *     "methodName2": {
 *       "methodID": 1,
 *       "type": "remote"
 *     },
 *     etc...
 *   },
 *   "constants": {
 *     ...
 *   }
 * },
 * etc...
 */
static NSMutableDictionary *RCTRemoteModulesByID;
static NSDictionary *RCTRemoteModulesConfig()
{
  static NSMutableDictionary *remoteModules;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    
    RCTRemoteModulesByID = [[NSMutableDictionary alloc] init];
    
    remoteModules = [[NSMutableDictionary alloc] init];
    [RCTExportedMethodsByModule() enumerateKeysAndObjectsUsingBlock:^(NSString *moduleName, NSArray *rawMethods, BOOL *stop) {
      
      NSMutableDictionary *methods = [NSMutableDictionary dictionaryWithCapacity:rawMethods.count];
      [rawMethods enumerateObjectsUsingBlock:^(RCTModuleMethod *method, NSUInteger methodID, BOOL *stop) {
        methods[method.JSMethodName] = @{
                                         @"methodID": @(methodID),
                                         @"type": @"remote",
                                         };
      }];
      
      NSDictionary *module = @{
                               @"moduleID": @(remoteModules.count),
                               @"methods": methods
                               };
      
      Class cls = RCTBridgeModuleClasses()[moduleName];
      if (RCTClassOverridesClassMethod(cls, @selector(constantsToExport))) {
        module = [module mutableCopy];
        ((NSMutableDictionary *)module)[@"constants"] = [cls constantsToExport];
      }
      remoteModules[moduleName] = module;
      
      // Add module lookup
      RCTRemoteModulesByID[module[@"moduleID"]] = moduleName;
      
    }];
  });
  
  return remoteModules;
}

/**
 * As above, but for local modules/methods, which represent JS classes
 * and methods that will be called by the native code via the bridge.
 * Structure is essentially the same as for remote modules:
 *
 * "ModuleName1": {
 *   "moduleID": 0,
 *   "methods": {
 *     "methodName1": {
 *       "methodID": 0,
 *       "type": "local"
 *     },
 *     "methodName2": {
 *       "methodID": 1,
 *       "type": "local"
 *     },
 *     etc...
 *   }
 * },
 * etc...
 */
static NSMutableDictionary *RCTLocalModuleIDs;
static NSMutableDictionary *RCTLocalMethodIDs;
static NSDictionary *RCTLocalModulesConfig()
{
  static NSMutableDictionary *localModules;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    
    RCTLocalModuleIDs = [[NSMutableDictionary alloc] init];
    RCTLocalMethodIDs = [[NSMutableDictionary alloc] init];
    
    NSMutableArray *JSMethods = [[NSMutableArray alloc] init];
    
    // Add globally used methods
    [JSMethods addObjectsFromArray:@[
                                     @"Bundler.runApplication",
                                     @"RCTEventEmitter.receiveEvent",
                                     @"RCTEventEmitter.receiveTouches",
                                     ]];
    
    //  NOTE: these methods are currently unused in the OSS project
    //  @"Dimensions.set",
    //  @"RCTDeviceEventEmitter.emit",
    //  @"RCTNativeAppEventEmitter.emit",
    //  @"ReactIOS.unmountComponentAtNodeAndRemoveContainer",
    
    // Register individual methods from modules
    for (Class cls in RCTBridgeModuleClasses().allValues) {
      if (RCTClassOverridesClassMethod(cls, @selector(JSMethods))) {
        [JSMethods addObjectsFromArray:[cls JSMethods]];
      }
    }
    
    localModules = [[NSMutableDictionary alloc] init];
    for (NSString *moduleDotMethod in JSMethods) {
      
      NSArray *parts = [moduleDotMethod componentsSeparatedByString:@"."];
      RCTCAssert(parts.count == 2, @"'%@' is not a valid JS method definition - expected 'Module.method' format.", moduleDotMethod);
      
      // Add module if it doesn't already exist
      NSString *moduleName = parts[0];
      NSDictionary *module = localModules[moduleName];
      if (!module) {
        module = @{
                   @"moduleID": @(localModules.count),
                   @"methods": [[NSMutableDictionary alloc] init]
                   };
        localModules[moduleName] = module;
      }
      
      // Add method if it doesn't already exist
      NSString *methodName = parts[1];
      NSMutableDictionary *methods = module[@"methods"];
      if (!methods[methodName]) {
        methods[methodName] = @{
                                @"methodID": @(methods.count),
                                @"type": @"local"
                                };
      }
      
      // Add module and method lookup
      RCTLocalModuleIDs[moduleDotMethod] = module[@"moduleID"];
      RCTLocalMethodIDs[moduleDotMethod] = methods[methodName][@"methodID"];
    }
  });
  
  return localModules;
}

@implementation RCTBridge
{
  NSMutableDictionary *_moduleInstances;
  id<RCTJavaScriptExecutor> _javaScriptExecutor;
}

static id<RCTJavaScriptExecutor> _latestJSExecutor;

- (instancetype)initWithJavaScriptExecutor:(id<RCTJavaScriptExecutor>)javaScriptExecutor
{
  if ((self = [super init])) {
    _javaScriptExecutor = javaScriptExecutor;
    _latestJSExecutor = _javaScriptExecutor;
    _eventDispatcher = [[RCTEventDispatcher alloc] initWithBridge:self];
    _shadowQueue = dispatch_queue_create("com.facebook.ReactKit.ShadowQueue", DISPATCH_QUEUE_SERIAL);
    
    // Instantiate modules
    _moduleInstances = [[NSMutableDictionary alloc] init];
    [RCTBridgeModuleClasses() enumerateKeysAndObjectsUsingBlock:^(NSString *moduleName, Class moduleClass, BOOL *stop) {
      if (_moduleInstances[moduleName] == nil) {
        if ([moduleClass instancesRespondToSelector:@selector(initWithBridge:)]) {
          _moduleInstances[moduleName] = [[moduleClass alloc] initWithBridge:self];
        } else {
          _moduleInstances[moduleName] = [[moduleClass alloc] init];
        }
      }
    }];
    
    // Inject module data into JS context
    NSString *configJSON = RCTJSONStringify(@{
                                              @"remoteModuleConfig": RCTRemoteModulesConfig(),
                                              @"localModulesConfig": RCTLocalModulesConfig()
                                              }, NULL);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [_javaScriptExecutor injectJSONText:configJSON asGlobalObjectNamed:@"__fbBatchedBridgeConfig" callback:^(id err) {
      dispatch_semaphore_signal(semaphore);
    }];
    
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
      RCTLogMustFix(@"JavaScriptExecutor took too long to inject JSON object");
    }
  }
  
  return self;
}

- (void)dealloc
{
  RCTAssert(!self.valid, @"must call -invalidate before -dealloc");
}

#pragma mark - RCTInvalidating

- (BOOL)isValid
{
  return _javaScriptExecutor != nil;
}

- (void)invalidate
{
  if (_latestJSExecutor == _javaScriptExecutor) {
    _latestJSExecutor = nil;
  }
  _javaScriptExecutor = nil;
  
  dispatch_sync(_shadowQueue, ^{
    // Make sure all dispatchers have been executed before continuing
    // TODO: is this still needed?
  });
  
  for (id target in _moduleInstances.objectEnumerator) {
    if ([target respondsToSelector:@selector(invalidate)]) {
      [(id<RCTInvalidating>)target invalidate];
    }
  }
  [_moduleInstances removeAllObjects];
}

/**
 * - TODO (#5906496): When we build a `MessageQueue.m`, handling all the requests could
 * cause both a queue of "responses". We would flush them here. However, we
 * currently just expect each objc block to handle its own response sending
 * using a `RCTResponseSenderBlock`.
 */

#pragma mark - RCTBridge methods

/**
 * Like JS::call, for objective-c.
 */
- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
  NSNumber *moduleID = RCTLocalModuleIDs[moduleDotMethod];
  RCTAssert(moduleID, @"Module '%@' not registered.",
            [[moduleDotMethod componentsSeparatedByString:@"."] firstObject]);
  
  NSNumber *methodID = RCTLocalMethodIDs[moduleDotMethod];
  RCTAssert(methodID, @"Method '%@' not registered.", moduleDotMethod);
  
  [self _invokeAndProcessModule:@"BatchedBridge"
                         method:@"callFunctionReturnFlushedQueue"
                      arguments:@[moduleID, methodID, args]];
}

- (void)enqueueApplicationScript:(NSString *)script url:(NSURL *)url onComplete:(RCTJavaScriptCompleteBlock)onComplete
{
  RCTAssert(onComplete != nil, @"onComplete block passed in should be non-nil");
  [_javaScriptExecutor executeApplicationScript:script sourceURL:url onComplete:^(NSError *scriptLoadError) {
    if (scriptLoadError) {
      onComplete(scriptLoadError);
      return;
    }
    
    [_javaScriptExecutor executeJSCall:@"BatchedBridge"
                                method:@"flushedQueue"
                             arguments:@[]
                              callback:^(id objcValue, NSError *error) {
                                [self _handleBuffer:objcValue];
                                onComplete(error);
                              }];
  }];
}

#pragma mark - Payload Generation

- (void)_invokeAndProcessModule:(NSString *)module method:(NSString *)method arguments:(NSArray *)args
{
  NSTimeInterval startJS = RCTTGetAbsoluteTime();
  
  RCTJavaScriptCallback processResponse = ^(id objcValue, NSError *error) {
    NSTimeInterval startNative = RCTTGetAbsoluteTime();
    [self _handleBuffer:objcValue];
    
    NSTimeInterval end = RCTTGetAbsoluteTime();
    NSTimeInterval timeJS = startNative - startJS;
    NSTimeInterval timeNative = end - startNative;
    
    // TODO: surface this performance information somewhere
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PERF" object:nil userInfo:@{@"JS": @(timeJS * 1000000), @"Native": @(timeNative * 1000000)}];
  };
  
  [_javaScriptExecutor executeJSCall:module
                              method:method
                           arguments:args
                            callback:processResponse];
}

/**
 * TODO (#5906496): Have responses piggy backed on a round trip with ObjC->JS requests.
 */
- (void)_sendResponseToJavaScriptCallbackID:(NSInteger)cbID args:(NSArray *)args
{
  [self _invokeAndProcessModule:@"BatchedBridge"
                         method:@"invokeCallbackAndReturnFlushedQueue"
                      arguments:@[@(cbID), args]];
}

#pragma mark - Payload Processing

- (void)_handleBuffer:(id)buffer
{
  if (buffer == nil || buffer == (id)kCFNull) {
    return;
  }
  
  if (![buffer isKindOfClass:[NSArray class]]) {
    RCTLogMustFix(@"Buffer must be an instance of NSArray, got %@", NSStringFromClass([buffer class]));
    return;
  }
  
  NSArray *requestsArray = (NSArray *)buffer;
  NSUInteger bufferRowCount = [requestsArray count];
  NSUInteger expectedFieldsCount = RCTBridgeFieldResponseReturnValues + 1;
  if (bufferRowCount != expectedFieldsCount) {
    RCTLogMustFix(@"Must pass all fields to buffer - expected %zd, saw %zd", expectedFieldsCount, bufferRowCount);
    return;
  }
  
  for (NSUInteger fieldIndex = RCTBridgeFieldRequestModuleIDs; fieldIndex <= RCTBridgeFieldParamss; fieldIndex++) {
    id field = [requestsArray objectAtIndex:fieldIndex];
    if (![field isKindOfClass:[NSArray class]]) {
      RCTLogMustFix(@"Field at index %zd in buffer must be an instance of NSArray, got %@", fieldIndex, NSStringFromClass([field class]));
      return;
    }
  }
  
  NSArray *moduleIDs = requestsArray[RCTBridgeFieldRequestModuleIDs];
  NSArray *methodIDs = requestsArray[RCTBridgeFieldMethodIDs];
  NSArray *paramsArrays = requestsArray[RCTBridgeFieldParamss];
  
  NSUInteger numRequests = [moduleIDs count];
  BOOL allSame = numRequests == [methodIDs count] && numRequests == [paramsArrays count];
  if (!allSame) {
    RCTLogMustFix(@"Invalid data message - all must be length: %zd", numRequests);
    return;
  }
  
  for (NSUInteger i = 0; i < numRequests; i++) {
    @autoreleasepool {
      [self _handleRequestNumber:i
                        moduleID:moduleIDs[i]
                        methodID:[methodIDs[i] integerValue]
                          params:paramsArrays[i]];
    }
  }
  
  // TODO: only used by RCTUIManager - can we eliminate this special case?
  dispatch_async(_shadowQueue, ^{
    for (id target in _moduleInstances.objectEnumerator) {
      if ([target respondsToSelector:@selector(batchDidComplete)]) {
        [target batchDidComplete];
      }
    }
  });
}

- (BOOL)_handleRequestNumber:(NSUInteger)i
                    moduleID:(NSNumber *)moduleID
                    methodID:(NSInteger)methodID
                      params:(NSArray *)params
{
  if (![params isKindOfClass:[NSArray class]]) {
    RCTLogMustFix(@"Invalid module/method/params tuple for request #%zd", i);
    return NO;
  }
  
  NSString *moduleName = RCTRemoteModulesByID[moduleID];
  if (!moduleName) {
    RCTLogMustFix(@"Unknown moduleID: %@", moduleID);
    return NO;
  }
  
  NSArray *methods = RCTExportedMethodsByModule()[moduleName];
  if (methodID >= methods.count) {
    RCTLogMustFix(@"Unknown methodID: %zd for module: %@", methodID, moduleName);
    return NO;
  }
  
  RCTModuleMethod *method = methods[methodID];
  NSUInteger methodArity = method.arity;
  if (params.count != methodArity) {
    RCTLogMustFix(@"Expected %tu arguments but got %tu invoking %@.%@",
                  methodArity,
                  params.count,
                  moduleName,
                  method.JSMethodName);
    return NO;
  }
  
  __weak RCTBridge *weakSelf = self;
  dispatch_async(_shadowQueue, ^{
    __strong RCTBridge *strongSelf = weakSelf;
    
    if (!strongSelf.isValid) {
      // strongSelf has been invalidated since the dispatch_async call and this
      // invocation should not continue.
      return;
    }
    
    // TODO: we should just store module instances by index, since that's how we look them up anyway
    id target = strongSelf->_moduleInstances[moduleName];
    RCTAssert(target != nil, @"No module found for name '%@'", moduleName);
    
    SEL selector = method.selector;
    NSMethodSignature *methodSignature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    [invocation setArgument:&target atIndex:0];
    [invocation setArgument:&selector atIndex:1];
    
    // Retain used blocks until after invocation completes.
    NS_VALID_UNTIL_END_OF_SCOPE NSMutableArray *blocks = [NSMutableArray array];
    
    [params enumerateObjectsUsingBlock:^(id param, NSUInteger idx, BOOL *stop) {
      if ([param isEqual:[NSNull null]]) {
        param = nil;
      } else if ([method.blockArgumentIndexes containsIndex:idx]) {
        id block = [strongSelf createResponseSenderBlock:[param integerValue]];
        [blocks addObject:block];
        param = block;
      }
      
      NSUInteger argIdx = idx + 2;
      
      // TODO: can we do this lookup in advance and cache the logic instead of
      // recalculating it every time for every parameter?
      BOOL shouldSet = YES;
      const char *argumentType = [methodSignature getArgumentTypeAtIndex:argIdx];
      switch (argumentType[0]) {
        case ':':
          if ([param isKindOfClass:[NSString class]]) {
            SEL selector = NSSelectorFromString(param);
            [invocation setArgument:&selector atIndex:argIdx];
            shouldSet = NO;
          }
          break;
          
        case '*':
          if ([param isKindOfClass:[NSString class]]) {
            const char *string = [param UTF8String];
            [invocation setArgument:&string atIndex:argIdx];
            shouldSet = NO;
          }
          break;
          
          // TODO: it seems like an error if the param doesn't respond
          // so we should probably surface that error rather than failing silently
#define CASE(_value, _type, _selector)                           \
case _value:                                             \
if ([param respondsToSelector:@selector(_selector)]) { \
_type value = [param _selector];                     \
[invocation setArgument:&value atIndex:argIdx];      \
shouldSet = NO;                                      \
}                                                      \
break;
          
          CASE('c', char, charValue)
          CASE('C', unsigned char, unsignedCharValue)
          CASE('s', short, shortValue)
          CASE('S', unsigned short, unsignedShortValue)
          CASE('i', int, intValue)
          CASE('I', unsigned int, unsignedIntValue)
          CASE('l', long, longValue)
          CASE('L', unsigned long, unsignedLongValue)
          CASE('q', long long, longLongValue)
          CASE('Q', unsigned long long, unsignedLongLongValue)
          CASE('f', float, floatValue)
          CASE('d', double, doubleValue)
          CASE('B', BOOL, boolValue)
          
        default:
          break;
      }
      
      if (shouldSet) {
        [invocation setArgument:&param atIndex:argIdx];
      }
    }];
    
    @try {
      [invocation invoke];
    }
    @catch (NSException *exception) {
      RCTLogMustFix(@"Exception thrown while invoking %@ on target %@ with params %@: %@", method.JSMethodName, target, params, exception);
    }
  });
  
  return YES;
}

/**
 * Returns a callback that reports values back to the JS thread.
 * TODO (#5906496): These responses should go into their own queue `MessageQueue.m` that
 * mirrors the JS queue and protocol. For now, we speak the "language" of the JS
 * queue by packing it into an array that matches the wire protocol.
 */
- (RCTResponseSenderBlock)createResponseSenderBlock:(NSInteger)cbID
{
  if (!cbID) {
    return nil;
  }
  
  return ^(NSArray *args) {
    [self _sendResponseToJavaScriptCallbackID:cbID args:args];
  };
}

+ (NSInvocation *)invocationForAdditionalArguments:(NSUInteger)argCount
{
  static NSMutableDictionary *invocations;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    invocations = [NSMutableDictionary dictionary];
  });
  
  id key = @(argCount);
  NSInvocation *invocation = invocations[key];
  if (invocation == nil) {
    NSString *objCTypes = [@"v@:" stringByPaddingToLength:3 + argCount withString:@"@" startingAtIndex:0];
    NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:objCTypes.UTF8String];
    invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
    invocations[key] = invocation;
  }
  
  return invocation;
}

- (void)registerRootView:(RCTRootView *)rootView
{
  // TODO: only used by RCTUIManager - can we eliminate this special case?
  for (id target in _moduleInstances.objectEnumerator) {
    if ([target respondsToSelector:@selector(registerRootView:)]) {
      [target registerRootView:rootView];
    }
  }
}

+ (BOOL)hasValidJSExecutor
{
  return (_latestJSExecutor != nil && [_latestJSExecutor isValid]);
}

+ (void)log:(NSArray *)objects level:(NSString *)level
{
  if (!_latestJSExecutor || ![_latestJSExecutor isValid]) {
    RCTLogError(@"%@", RCTLogFormatString(@"ERROR: No valid JS executor to log %@.", objects));
    return;
  }
  NSMutableArray *args = [NSMutableArray arrayWithObject:level];
  
  // TODO (#5906496): Find out and document why we skip the first object
  for (id ob in [objects subarrayWithRange:(NSRange){1, [objects count] - 1}]) {
    if ([NSJSONSerialization isValidJSONObject:@[ob]]) {
      [args addObject:ob];
    } else {
      [args addObject:[ob description]];
    }
  }
  // Note the js executor could get invalidated while we're trying to call this...need to watch out for that.
  [_latestJSExecutor executeJSCall:@"RCTLog"
                            method:@"logIfNoNativeHook"
                         arguments:args
                          callback:^(id objcValue, NSError *error) {}];
}

@end
