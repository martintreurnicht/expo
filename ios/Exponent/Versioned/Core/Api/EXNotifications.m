// Copyright 2016-present 650 Industries. All rights reserved.

#import "EXNotifications.h"
#import "EXModuleRegistryBinding.h"
#import "EXUnversioned.h"
#import "EXUtil.h"
#import "EXEnvironment.h"

#import <React/RCTUtils.h>
#import <React/RCTConvert.h>

#import <EXConstantsInterface/EXConstantsInterface.h>
#import <UserNotifications/UserNotifications.h>

@implementation RCTConvert (NSCalendarUnit)

RCT_ENUM_CONVERTER(NSCalendarUnit,
                   (@{
                      @"year": @(NSCalendarUnitYear),
                      @"month": @(NSCalendarUnitMonth),
                      @"week": @(NSCalendarUnitWeekOfYear),
                      @"day": @(NSCalendarUnitDay),
                      @"hour": @(NSCalendarUnitHour),
                      @"minute": @(NSCalendarUnitMinute)
                      }),
                   0,
                   integerValue);

@end

@interface EXNotifications ()

// unversioned EXRemoteNotificationManager instance
@property (nonatomic, weak) id <EXNotificationsScopedModuleDelegate> kernelNotificationsDelegate;
@property (nonatomic, strong) NSString * expId;

@end

@implementation EXNotifications

EX_EXPORT_SCOPED_MODULE(ExponentNotifications, RemoteNotificationManager);

@synthesize bridge = _bridge;

- (void)setBridge:(RCTBridge *)bridge
{
  _bridge = bridge;
}

- (instancetype)initWithExperienceId:(NSString *)experienceId kernelServiceDelegate:(id)kernelServiceInstance params:(NSDictionary *)params
{
  if (self = [super initWithExperienceId:experienceId kernelServiceDelegate:kernelServiceInstance params:params]) {
    _kernelNotificationsDelegate = kernelServiceInstance;
    _expId = experienceId;
  }
  return self;
}

RCT_REMAP_METHOD(getDevicePushTokenAsync,
                 getDevicePushTokenWithConfig: (__unused NSDictionary *)config
                 resolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  id<EXConstantsInterface> constants = [_bridge.scopedModules.moduleRegistry getModuleImplementingProtocol:@protocol(EXConstantsInterface)];
  
  if (![constants.appOwnership isEqualToString:@"standalone"]) {
    return reject(0, @"getDevicePushTokenAsync is only accessible within standalone applications", nil);
  }
  
  NSString *token = [_kernelNotificationsDelegate apnsTokenStringForScopedModule:self];
  if (!token) {
    return reject(0, @"APNS token has not been set", nil);
  }
  return resolve(@{ @"type": @"apns", @"data": token });
}

RCT_REMAP_METHOD(getExponentPushTokenAsync,
                 getExponentPushTokenAsyncWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.experienceId) {
    reject(@"E_NOTIFICATIONS_INTERNAL_ERROR", @"The notifications module is missing the current project's ID", nil);
    return;
  }

  [_kernelNotificationsDelegate getExpoPushTokenForScopedModule:self completionHandler:^(NSString *pushToken, NSError *error) {
    if (error) {
      reject(@"E_NOTIFICATIONS_TOKEN_REGISTRATION_FAILED", error.localizedDescription, error);
    } else {
      resolve(pushToken);
    }
  }];
}

RCT_EXPORT_METHOD(presentLocalNotification:(NSDictionary *)payload
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  UNMutableNotificationContent* content = [self _localNotificationFromPayload:payload];

  [EXUtil performSynchronouslyOnMainThread:^{
    UNNotificationRequest* request = [UNNotificationRequest
                                      requestWithIdentifier:content.userInfo[@"id"] content:content trigger:nil];
    [[EXUserNotificationCenter sharedInstance] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
      if (error != nil) {
        reject(@"E_NOTIF", [NSString stringWithFormat:@"Could not add a notification request: %@", error.localizedDescription], error);
      } else {
        resolve(content.userInfo[@"id"]);
      }
    }];
  }];

}

RCT_EXPORT_METHOD(addCategory: (NSString *)categoryId
                  actions: (NSArray *)actions
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  if (![EXEnvironment sharedEnvironment].isDetached) {
    categoryId = [self prefixWithExperience:categoryId];

    for (id action in actions) {
      action[0] = [self prefixWithExperience:action[0]];
    }
  }

  NSMutableArray<UNNotificationAction *> * actionsArray = [[NSMutableArray alloc] init];
  
  for(NSArray *action in actions) {
    int optionsInt = [(NSNumber *)action[2] intValue];
    UNNotificationActionOptions options = UNNotificationActionOptionForeground + optionsInt;

    /*
     action[0] actionId
     action[1] buttonTitle
     action[2] flags
     action[3] buttonTitle on keyboard
     action[4] default text in textInput
     */

    if (([action count] == 5)) {
      UNTextInputNotificationAction * newAction = [UNTextInputNotificationAction actionWithIdentifier:action[0]
                                                                                                title:action[1]
                                                                                              options:options
                                                                                 textInputButtonTitle:action[3] textInputPlaceholder:action[4]];
      [actionsArray addObject:newAction];
    } else {
      UNNotificationAction * newAction = [UNNotificationAction actionWithIdentifier:action[0] title:action[1] options:options];
      [actionsArray addObject:newAction];
    }
  }
  
  UNNotificationCategory * newCategory = [UNNotificationCategory categoryWithIdentifier:categoryId actions:actionsArray intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
  
  [[EXUserNotificationCenter sharedInstance] getNotificationCategoriesWithCompletionHandler:^(NSSet * categories) {
    NSMutableSet * newCategories = [categories mutableCopy];
    for( UNNotificationCategory * category in newCategories) {
      if ([category.identifier isEqualToString:categoryId]) {
        [newCategories removeObject:category];
        break;
      }
    }
    [newCategories addObject:newCategory];
    [[EXUserNotificationCenter sharedInstance] setNotificationCategories:newCategories];
    resolve(nil);
  }];
}

RCT_EXPORT_METHOD(scheduleLocalNotification:(NSDictionary *)payload
                  withOptions:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  bool repeats = NO;
  if (options[@"repeats"]) {
    repeats = ([options[@"repeats"] isEqualToString:@"Yes"])? YES : NO;
  }
  UNMutableNotificationContent* content = [self _localNotificationFromPayload:payload];
  
  NSDateComponents * date = [[NSDateComponents alloc] init];
  NSArray * units = @[@"day", @"month", @"year", @"weekday", @"quarter", @"leapMonth", @"nanosecond", @"era", @"weekdayOrdinal", @"weekOfMonth", @"weekOfYear", @"hour", @"second", @"minute", @"yearForWeekOfYear"];
  for( NSString * unit in units) {
    if (options[unit]) {
      [date setValue:(NSNumber *)options[unit] forKey:unit];
    }
  }
  UNCalendarNotificationTrigger* trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:date repeats:repeats];
  UNNotificationRequest* request = [UNNotificationRequest
                                    requestWithIdentifier:content.userInfo[@"id"] content:content trigger:trigger];
  [[EXUserNotificationCenter sharedInstance] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
    if (error != nil) {
      NSLog(@"%@", error.localizedDescription);
      reject(@"Could not make notification request", error.localizedDescription, error);
    } else {
      resolve(content.userInfo[@"id"]);
    }
  }];
}

RCT_EXPORT_METHOD(scheduleLocalNotificationWithTimeInterval:(NSDictionary *)payload
                  withOptions:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  bool repeats = NO;
  if (options[@"repeats"]) {
    repeats = ([options[@"repeats"] isEqualToString:@"Yes"])? YES : NO;
  }
  UNMutableNotificationContent* content = [self _localNotificationFromPayload:payload];
  
  [EXUtil performSynchronouslyOnMainThread:^{
    int timeInterval = [((NSNumber *)options[@"time-interval"]) intValue];
    UNTimeIntervalNotificationTrigger* trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:timeInterval
                                                                                                    repeats:repeats];
    UNNotificationRequest* request = [UNNotificationRequest
                                      requestWithIdentifier:content.userInfo[@"id"] content:content trigger:trigger];
    [[EXUserNotificationCenter sharedInstance] addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
      if (error != nil) {
        NSLog(@"%@", error.localizedDescription);
        reject(@"Could not make notification request", error.localizedDescription, error);
      } else {
        resolve(content.userInfo[@"id"]);
      }
    }];
  }];
}

RCT_EXPORT_METHOD(cancelScheduledNotification:(NSString *)uniqueId)
{
  if (![EXEnvironment sharedEnvironment].isDetached) {
    uniqueId = [self prefixWithExperience:uniqueId];
  }

  [EXUtil performSynchronouslyOnMainThread:^{
    [[EXUserNotificationCenter sharedInstance] removePendingNotificationRequestsWithIdentifiers:@[uniqueId]];
  }];
}

RCT_REMAP_METHOD(cancelAllScheduledNotifications,
                 cancelAllScheduledNotificationsWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject)
{
  [self cancelAllScheduledNotificationsAsyncWithResolver:resolve rejecter:reject];
}

RCT_REMAP_METHOD(cancelAllScheduledNotificationsAsync,
                 cancelAllScheduledNotificationsAsyncWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  [[EXUserNotificationCenter sharedInstance] getPendingNotificationRequestsWithCompletionHandler:
    ^(NSArray<UNNotificationRequest *> * _Nonnull __strong requests){
      for (UNNotificationRequest * request in requests) {
        if ([request.content.userInfo[@"experienceId"] isEqualToString:self.experienceId]) {
          [[EXUserNotificationCenter sharedInstance] removePendingNotificationRequestsWithIdentifiers:@[request.content.userInfo[@"id"]]];
        }
      }
    }];
  resolve(nil);
}

#pragma mark - Badges

// TODO: Make this read from the kernel instead of UIApplication for the main Exponent app

RCT_REMAP_METHOD(getBadgeNumberAsync,
                 getBadgeNumberAsyncWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  __block NSInteger badgeNumber;
  [EXUtil performSynchronouslyOnMainThread:^{
    badgeNumber = RCTSharedApplication().applicationIconBadgeNumber;
  }];
  resolve(@(badgeNumber));
}

RCT_EXPORT_METHOD(setBadgeNumberAsync:(nonnull NSNumber *)number
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(__unused RCTPromiseRejectBlock)reject)
{
  [EXUtil performSynchronouslyOnMainThread:^{
    RCTSharedApplication().applicationIconBadgeNumber = number.integerValue;
  }];
  resolve(nil);
}

#pragma mark - internal

- (UNMutableNotificationContent *)_localNotificationFromPayload:(NSDictionary *)payload
{
  UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
  NSString *uniqueId = [[NSUUID new] UUIDString];

  content.title = payload[@"title"];
  content.body = payload[@"body"];
  
  if ([payload[@"sound"] boolValue]) {
    content.sound = [UNNotificationSound defaultSound];
  }
  
  if (payload[@"count"]) {
     content.badge = (NSNumber *)payload[@"count"];
  }
  
  if (payload[@"categoryId"]) {
    if ([EXEnvironment sharedEnvironment].isDetached) {
      content.categoryIdentifier = payload[@"categoryId"];
    } else {
      content.categoryIdentifier = [self prefixWithExperience:payload[@"categoryId"]];
    }
  }
 
  content.userInfo = @{
                       @"body":payload[@"data"],
                       @"experienceId":self.experienceId,
                       @"id":uniqueId
                       };
  
  return content;
}

-(NSString *) prefixWithExperience:(NSString *) identifier {
  return [NSString stringWithFormat:@"%@%@%@", self.expId, @"@@@", identifier];
}

@end
