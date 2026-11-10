#pragma once
#import <UIKit/UIKit.h>
#import "Game.h"

@interface MCBootScreen : UIView
- (void)addLine:(NSString *)text kind:(MCLogKind)kind;  // main thread
- (void)consumeGameLog:(NSString *)chunk;               // java.log, main thread, any chunk size
- (void)fadeOut;
@end
