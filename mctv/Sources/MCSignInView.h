#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MCSignInView : UIView
- (void)showCode:(NSString *)code url:(NSURL *)url;
- (void)showProblem:(nullable NSString *)text;  // nil clears it
@end

NS_ASSUME_NONNULL_END
