#import "include/AudioGuard.h"

BOOL AGRunCatchingException(void (NS_NOESCAPE ^block)(void),
                            NSString * _Nullable * _Nullable reason) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (reason) {
            *reason = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
        }
        return NO;
    }
}
