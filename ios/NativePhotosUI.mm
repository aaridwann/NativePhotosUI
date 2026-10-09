#import "NativePhotosUI.h"
#import <RNPhotosUISpec/RNPhotosUISpec.h>

#if __has_include("NativePhotosUI-Swift.h")
#import "NativePhotosUI-Swift.h"
#endif

@interface RNPhotosUIModule () <NativePhotosUISpec>
@end

@implementation RNPhotosUIModule {
  RNPhotosUIModuleSwift *_swiftImpl;
}

RCT_EXPORT_MODULE(NativePhotosUI)

- (instancetype)init {
  if (self = [super init]) {
    _swiftImpl = [[RNPhotosUIModuleSwift alloc] init];
  }
  return self;
}

+ (BOOL)requiresMainQueueSetup {
  return [RNPhotosUIModuleSwift requiresMainQueueSetup];
}

#pragma mark - NativePhotosUISpec Protocol Methods

- (void)getPermissionStatus:(NSString *)accessLevel
    resolve:(RCTPromiseResolveBlock)resolve
    reject:(RCTPromiseRejectBlock)reject {
  [_swiftImpl getPermissionStatus:accessLevel resolve:resolve reject:reject];
}

- (void)requestPermission:(NSString *)accessLevel
    resolve:(RCTPromiseResolveBlock)resolve
    reject:(RCTPromiseRejectBlock)reject {
  [_swiftImpl requestPermission:accessLevel resolve:resolve reject:reject];
}

- (void)presentPicker:(JS::NativePhotosUI::PickerOptions &)options
      resolve:(RCTPromiseResolveBlock)resolve
      reject:(RCTPromiseRejectBlock)reject {
  
  NSMutableDictionary *dictOptions = [NSMutableDictionary dictionary];
  
  if (options.selectionLimit().has_value()) {
    dictOptions[@"selectionLimit"] = @(options.selectionLimit().value());
  }
  
  if (options.filter() != nil) {
    dictOptions[@"filter"] = options.filter();
  }
  
  if (options.preferredAssetRepresentationMode() != nil) {
    dictOptions[@"preferredAssetRepresentationMode"] = options.preferredAssetRepresentationMode();
  }

  [_swiftImpl presentPicker:dictOptions resolve:resolve reject:reject];
}

#pragma mark - TurboModule C++ Registration

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativePhotosUISpecJSI>(params);
}

@end
