#pragma once
#import <UIKit/UIKit.h>
#import "JVM.h"

@interface MCBootScreen : UIView
- (void)addLine:(NSString *)text kind:(MCLogKind)kind;  // main thread
- (void)consumeJavaLog:(NSString *)chunk;               // main thread, any chunk size
- (void)fadeOut;
@end
