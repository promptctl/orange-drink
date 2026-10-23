#import <Foundation/Foundation.h>
#import <dlfcn.h>
@interface PowerUISmartChargeClient : NSObject
- (unsigned char)getMCLLimitWithError:(NSError **)e;
- (id)availableChargeLimitsWithError:(NSError **)e;
- (BOOL)isOBCEngaged:(BOOL *)engaged chargeLimit:(unsigned char *)limit chargingOverrideAllowed:(BOOL *)allowed withError:(NSError **)e;
- (void)getMCLLimitWithHandler:(void (^)(unsigned char, NSError *))h;
@end
int main(void){ @autoreleasepool {
  dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
  PowerUISmartChargeClient *c = [[NSClassFromString(@"PowerUISmartChargeClient") alloc] init];
  NSError *e = nil;
  unsigned char mcl = [c getMCLLimitWithError:&e];
  printf("MCL %u err %s\n", mcl, e ? e.description.UTF8String : "nil");
  e = nil; id av = [c availableChargeLimitsWithError:&e];
  printf("available %s err %s\n", [[av description] UTF8String], e ? e.description.UTF8String : "nil");
  BOOL eng=0, allowed=0; unsigned char lim=0; e=nil;
  BOOL ok = [c isOBCEngaged:&eng chargeLimit:&lim chargingOverrideAllowed:&allowed withError:&e];
  printf("ok %d engaged %d limit %u allowed %d err %s\n", ok, eng, lim, allowed, e ? e.description.UTF8String : "nil");
  // Spin the run loop rather than block: a handler delivered on the main queue still runs.
  __block BOOL answered = NO;
  [c getMCLLimitWithHandler:^(unsigned char l, NSError *err){ printf("handler MCL %u err %s\n", l, err?err.description.UTF8String:"nil"); answered = YES; }];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
  while (!answered && [deadline timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
  if (!answered) printf("handler: no answer in 5 s\n");
}}
