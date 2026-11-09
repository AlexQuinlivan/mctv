// Top Shelf extension. It shows full-screen art behind the home screen's app
// row when the Minecraft icon has focus, like the old Apple TV Edition.
#import <TVServices/TVServices.h>

@interface MCTopShelf : TVTopShelfContentProvider
@end

@implementation MCTopShelf

- (void)loadTopShelfContentWithCompletionHandler:(void (^)(id<TVTopShelfContent> _Nullable))completionHandler {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSURL *hero1x = [bundle URLForResource:@"hero" withExtension:@"jpg"];
    NSURL *hero2x = [bundle URLForResource:@"hero@2x" withExtension:@"jpg"];
    if (!hero1x && !hero2x) {
        completionHandler(nil);  // fall back to the static Top Shelf image
        return;
    }
    TVTopShelfCarouselItem *item = [[TVTopShelfCarouselItem alloc] initWithIdentifier:@"minecraft"];
    item.title = @"Minecraft";
    item.contextTitle = @"Java Edition";
    item.summary = @"Play on your home server, or start a world of your own.";
    [item setImageURL:hero1x ?: hero2x forTraits:TVTopShelfItemImageTraitScreenScale1x];
    [item setImageURL:hero2x ?: hero1x forTraits:TVTopShelfItemImageTraitScreenScale2x];
    NSURL *open = [NSURL URLWithString:@"mctv://play"];
    item.playAction = [[TVTopShelfAction alloc] initWithURL:open];
    item.displayAction = [[TVTopShelfAction alloc] initWithURL:open];
    completionHandler([[TVTopShelfCarouselContent alloc] initWithStyle:TVTopShelfCarouselContentStyleActions
                                                                  items:@[item]]);
}

@end
