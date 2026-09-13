#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, converting any Objective-C exception into a returned error.
///
/// AVAudioEngine reports misuse by raising NSException, not by throwing a Swift
/// error, and Swift cannot catch NSException. `try?` does not help: the process
/// aborts. Installing a tap is the call that raises — its format argument must
/// match the input node's format *at that instant*, and a device change between
/// reading the format and installing the tap makes that false.
BOOL AGRunCatchingException(void (NS_NOESCAPE ^block)(void),
                            NSString * _Nullable * _Nullable reason);

NS_ASSUME_NONNULL_END
