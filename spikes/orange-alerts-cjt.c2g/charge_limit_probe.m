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
  dispatch_semaphore_t s = dispatch_semaphore_create(0);
  [c getMCLLimitWithHandler:^(unsigned char l, NSError *err){ printf("handler MCL %u err %s\n", l, err?err.description.UTF8String:"nil"); dispatch_semaphore_signal(s);} ];
  dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
}}
