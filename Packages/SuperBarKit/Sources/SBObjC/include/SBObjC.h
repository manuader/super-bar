#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and converts any Objective-C exception (e.g. a malformed
/// NSPredicate format or an invalid regular expression) into an NSError.
/// Returns YES on success.
BOOL SBTryCatch(void (NS_NOESCAPE ^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
