#import "MCBootScreen.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - cubes

@interface MCCubesView : UIView
@end

@implementation MCCubesView

static const CGFloat kEdge = 52;
static const CGFloat kGap = 14;
static const int kCells = 8;

+ (CGSize)size {
    CGFloat w = 2 * kEdge * 0.8660254;
    return CGSizeMake(3 * w + 2 * kGap, 2 * kEdge);
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
    }
    return self;
}

static unsigned CellHash(int a, int b, int c) {
    unsigned h = (unsigned)a * 73856093u ^ (unsigned)b * 19349663u ^ (unsigned)c * 83492791u;
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    return h ^ (h >> 15);
}

static void Fill(CGContextRef ctx, const float rgb[3], CGFloat k, CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3) {
    CGContextSetRGBFillColor(ctx, rgb[0] * k, rgb[1] * k, rgb[2] * k, 1);
    CGContextMoveToPoint(ctx, p0.x, p0.y);
    CGContextAddLineToPoint(ctx, p1.x, p1.y);
    CGContextAddLineToPoint(ctx, p2.x, p2.y);
    CGContextAddLineToPoint(ctx, p3.x, p3.y);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
}

- (void)drawCube:(CGContextRef)ctx top:(CGPoint)a seed:(int)seed {
    static const float grass[4][3] = {{0.38, 0.64, 0.23}, {0.33, 0.57, 0.20}, {0.45, 0.72, 0.28}, {0.29, 0.52, 0.17}};
    static const float dirt[4][3] = {{0.55, 0.38, 0.24}, {0.48, 0.32, 0.20}, {0.62, 0.44, 0.28}, {0.42, 0.28, 0.17}};
    CGPoint X = {kEdge * 0.8660254, kEdge * 0.5}, Y = {-kEdge * 0.8660254, kEdge * 0.5}, D = {0, kEdge};
    // face: origin, along-u, along-v, brightness
    CGPoint origins[3] = {a, {a.x + Y.x, a.y + Y.y}, {a.x + X.x + Y.x, a.y + X.y + Y.y}};
    CGPoint us[3] = {X, X, {-Y.x, -Y.y}};
    CGPoint vs[3] = {Y, D, D};
    CGFloat shade[3] = {1.0, 0.82, 0.64};
    for (int f = 0; f < 3; f++) {
        CGPoint o = origins[f], u = us[f], v = vs[f];
        for (int i = 0; i < kCells; i++) {
            for (int j = 0; j < kCells; j++) {
                unsigned h = CellHash(i, j, f * 16 + seed);
                const float *rgb;
                if (f == 0) rgb = grass[h % 4];
                else if (j == 0 || (j == 1 && h % 3) || (j == 2 && h % 5 == 0)) rgb = grass[h % 4];
                else rgb = dirt[h % 4];
                CGFloat i0 = (CGFloat)i / kCells, i1 = (CGFloat)(i + 1) / kCells;
                CGFloat j0 = (CGFloat)j / kCells, j1 = (CGFloat)(j + 1) / kCells;
                Fill(ctx, rgb, shade[f],
                     CGPointMake(o.x + u.x * i0 + v.x * j0, o.y + u.y * i0 + v.y * j0),
                     CGPointMake(o.x + u.x * i1 + v.x * j0, o.y + u.y * i1 + v.y * j0),
                     CGPointMake(o.x + u.x * i1 + v.x * j1, o.y + u.y * i1 + v.y * j1),
                     CGPointMake(o.x + u.x * i0 + v.x * j1, o.y + u.y * i0 + v.y * j1));
            }
        }
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(ctx, NO);  // crisp pixels, no seams between cells
    CGFloat w = 2 * kEdge * 0.8660254;
    for (int k = 0; k < 3; k++)
        [self drawCube:ctx top:CGPointMake(k * (w + kGap) + w / 2, 0) seed:k];
}
@end

#pragma mark - console

@implementation MCBootScreen {
    MCCubesView *_cubes;
    UILabel *_text;
    NSMutableArray<NSAttributedString *> *_lines;
    NSMutableString *_javaBuf;
    CFTimeInterval _t0;
    UIFont *_font;
    CGFloat _charWidth;
    BOOL _crashReport;
    BOOL _hidden;
}

static UIColor *RGB(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0
                            blue:(hex & 255) / 255.0 alpha:1];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        self.userInteractionEnabled = NO;
        _t0 = CACurrentMediaTime();
        _lines = [NSMutableArray new];
        _javaBuf = [NSMutableString new];
        _font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
        _charWidth = [@"M" sizeWithAttributes:@{NSFontAttributeName: _font}].width;
        _cubes = [MCCubesView new];
        [self addSubview:_cubes];
        _text = [UILabel new];
        _text.numberOfLines = 0;
        [self addSubview:_text];
    }
    return self;
}

- (CGRect)textArea {
    CGRect area = CGRectInset(self.bounds, 80, 50);
    CGFloat top = CGRectGetMinY(area) + [MCCubesView size].height + 24;
    return CGRectMake(area.origin.x, top, area.size.width, CGRectGetMaxY(area) - top);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect area = CGRectInset(self.bounds, 80, 50);
    CGSize cs = [MCCubesView size];
    _cubes.frame = CGRectMake(area.origin.x, area.origin.y, cs.width, cs.height);
    [_cubes setNeedsDisplay];
    _text.frame = [self textArea];
    [self render];
}

- (NSUInteger)columns {
    return MAX(40, (NSUInteger)floor([self textArea].size.width / _charWidth));
}

- (void)render {
    NSUInteger maxLines = MAX(1, (NSUInteger)floor([self textArea].size.height / _font.lineHeight));
    NSUInteger start = _lines.count > maxLines ? _lines.count - maxLines : 0;
    NSMutableAttributedString *all = [NSMutableAttributedString new];
    for (NSUInteger i = start; i < _lines.count; i++) {
        if (all.length) [all appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        [all appendAttributedString:_lines[i]];
    }
    _text.attributedText = all;
    CGRect f = _text.frame;
    f.size.height = MIN([self textArea].size.height, [_text sizeThatFits:f.size].height);
    _text.frame = f;
}

- (void)addLine:(NSString *)text kind:(MCLogKind)kind {
    if (kind == MCLogQuiet || !text.length) return;
    NSDictionary *plain = @{NSFontAttributeName: _font, NSForegroundColorAttributeName: RGB(0xD8D8D8)};
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    void (^put)(NSString *, UIColor *) = ^(NSString *s, UIColor *c) {
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{
            NSFontAttributeName: self->_font, NSForegroundColorAttributeName: c}]];
    };
    NSString *tag = nil;
    UIColor *tagColor = nil;
    switch (kind) {
        case MCLogOK: tag = @"  OK  "; tagColor = RGB(0x4EE04E); break;
        case MCLogWarn: tag = @" WARN "; tagColor = RGB(0xF2C94C); break;
        case MCLogFail: tag = @"FAILED"; tagColor = RGB(0xFF5555); break;
        default: break;
    }
    if (tag) {
        put(@"[", plain[NSForegroundColorAttributeName]);
        put(tag, tagColor);
        put(@"] ", plain[NSForegroundColorAttributeName]);
    } else {
        double t = CACurrentMediaTime() - _t0;
        put([NSString stringWithFormat:@"[%5ld.%06ld] ", (long)t, (long)((t - floor(t)) * 1e6)], RGB(0x7A7A7A));
    }
    NSUInteger room = self.columns > line.length ? self.columns - line.length : 10;
    NSString *body = [[text componentsSeparatedByString:@"\n"].firstObject
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (body.length > room) body = [body substringToIndex:room];
    put(body, kind == MCLogDim ? RGB(0x8A8A8A) : kind == MCLogFail ? RGB(0xFFB0B0) : RGB(0xD8D8D8));
    [_lines addObject:line];
    while (_lines.count > 300) [_lines removeObjectAtIndex:0];
    [self render];
    if (kind == MCLogFail && _hidden) {
        _hidden = NO;
        [UIView animateWithDuration:0.4 animations:^{ self.alpha = 1; }];
    }
}

- (void)fadeOut {
    _hidden = YES;
    [UIView animateWithDuration:0.5 animations:^{ self.alpha = 0; }];
}

#pragma mark - Java's output

// Known harmless messages. Realms and auth complaints when the login is
// missing or old, the oshi/JNA system probe, libraries left out on purpose, and on
// 26.x Controlify trying its desktop SDL and Fabric grumbling about its SDL
// bindings' version strings.
static NSArray<NSString *> *Noise(void) {
    static NSArray *noise;
    if (!noise) noise = @[@"Realms", @"realms", @"player/attributes", @"user properties", @"SignedJWT",
                          @"SystemB", @"oshi.", @"com.sun.jna", @"Failed to bind SDL from input stream",
                          @"controlify-native-", @"SemVer is recommended", @"SteamDeck", @"Steam Deck"];
    return noise;
}

static NSString *Between(NSString *s, NSString *a, NSString *b) {
    NSRange r1 = [s rangeOfString:a];
    if (r1.location == NSNotFound) return nil;
    NSUInteger from = NSMaxRange(r1);
    NSRange r2 = [s rangeOfString:b options:0 range:NSMakeRange(from, s.length - from)];
    return r2.location == NSNotFound ? nil : [s substringWithRange:NSMakeRange(from, r2.location - from)];
}

static NSString *FirstLine(NSString *s) {
    return [[s componentsSeparatedByString:@"\n"].firstObject
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)consumeJavaLog:(NSString *)chunk {
    [_javaBuf appendString:chunk];
    while (YES) {
        NSRange ev = [_javaBuf rangeOfString:@"<log4j:Event"];
        // Plain lines before the next event (or every complete line if there is none).
        NSUInteger rawEnd = ev.location;
        if (rawEnd == NSNotFound) {
            NSRange nl = [_javaBuf rangeOfString:@"\n" options:NSBackwardsSearch];
            rawEnd = nl.location == NSNotFound ? 0 : NSMaxRange(nl);
        }
        if (rawEnd > 0) {
            for (NSString *line in [[_javaBuf substringToIndex:rawEnd] componentsSeparatedByString:@"\n"])
                [self rawLine:line];
            [_javaBuf deleteCharactersInRange:NSMakeRange(0, rawEnd)];
            continue;
        }
        if (ev.location == NSNotFound) break;
        NSRange end = [_javaBuf rangeOfString:@"</log4j:Event>"];
        if (end.location == NSNotFound) break;  // the rest hasn't been written yet
        NSUInteger len = NSMaxRange(end);
        [self event:[_javaBuf substringToIndex:len]];
        [_javaBuf deleteCharactersInRange:NSMakeRange(0, len)];
    }
}

- (void)rawLine:(NSString *)raw {
    NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!line.length || [raw containsString:@" [mctv] "]) return;  // our own lines, already shown
    for (NSString *p in @[@"at ", @"Caused by", @"...", @"Ignored non-exists file", @"[MobileGlues] Setting:",
                          @"Platform.isMac", @"PatchJNAAgent", @"The Open Source License", @"GNU LGPL", @"]]>",
                          @"WARNING: sun.misc.Unsafe", @"WARNING: Please consider reporting",
                          @"OpenJDK 64-Bit Server VM warning: Option UseCompressedClassPointers"])
        if ([line hasPrefix:p]) return;
    // Controlify's copy of SDL defines the same Objective-C classes as the app's.
    // Each copy uses its own, so the runtime's duplicate class warnings are noise.
    if ([line containsString:@"is implemented in both"]) return;
    // MoltenVK warns once per pipeline about what Metal lacks (java.log keeps them).
    if ([line hasPrefix:@"[mvk-info]"] || [line hasPrefix:@"[mvk-warn]"]) return;
    if ([line containsString:@"CoreBluetooth BLE hardware is unsupported"]) return;  // SDL's HIDAPI, tvOS has no BLE for it
    if ([line containsString:@"A fatal error has been detected"]) {
        [self addLine:@"Java crashed. The details are in java.log" kind:MCLogFail];
    } else if ([line containsString:@"---- Minecraft Crash Report ----"]) {
        _crashReport = YES;
    } else if (_crashReport && [line hasPrefix:@"Description: "]) {
        _crashReport = NO;
        [self addLine:[@"Minecraft crashed: " stringByAppendingString:[line substringFromIndex:13]] kind:MCLogFail];
    } else if ([line hasPrefix:@"[JIT26] Got JIT mapping"]) {
        [self addLine:@"JIT code cache ready" kind:MCLogOK];
    } else if ([line hasPrefix:@"[JIT26] "]) {
        [self addLine:[line substringFromIndex:8] kind:[line hasPrefix:@"[JIT26] mapping"] ? MCLogDim : MCLogPlain];
    } else if ([line hasPrefix:@"Launching Minecraft "] || [line hasPrefix:@"OpenGL ES Version:"]) {
        [self addLine:line kind:MCLogPlain];
    } else if (!_crashReport) {
        [self addLine:line kind:MCLogDim];
    }
}

- (void)event:(NSString *)ev {
    NSString *level = Between(ev, @"level=\"", @"\"") ?: @"INFO";
    NSString *logger = Between(ev, @"logger=\"", @"\"") ?: @"";
    NSString *msg = Between(ev, @"<log4j:Message><![CDATA[", @"]]></log4j:Message>") ?: @"";
    NSString *thr = Between(ev, @"<log4j:Throwable><![CDATA[", @"]]></log4j:Throwable>");
    NSString *all = thr ? [msg stringByAppendingString:thr] : msg;
    for (NSString *n in Noise())
        if ([all containsString:n]) return;
    NSString *first = FirstLine(msg);

    if ([first hasPrefix:@"Loading "] && [first hasSuffix:@" mods:"]) {
        NSMutableArray *names = [NSMutableArray new];
        for (NSString *l in [msg componentsSeparatedByString:@"\n"]) {
            if (![l hasPrefix:@"\t- "]) continue;
            NSString *name = [[l substringFromIndex:3] componentsSeparatedByString:@" "].firstObject;
            if (![@[@"java", @"minecraft", @"fabricloader"] containsObject:name]) [names addObject:name];
        }
        NSString *count = [first substringWithRange:NSMakeRange(8, first.length - 8 - 1)];
        [self addLine:[NSString stringWithFormat:@"Loaded %@ (%@)", count, [names componentsJoinedByString:@", "]]
                 kind:MCLogOK];
        return;
    }
    NSDictionary<NSString *, NSString *> *milestones = @{
        @"Loading Minecraft ": @"", @"Backend library: ": @"", @"Sound engine started": @"",
        @"Connecting to ": @"", @"Setting user: ": @"Player ",
        @"Using graphics device: ": @"GPU: ",  // 26.x
    };
    for (NSString *prefix in milestones) {
        if ([first hasPrefix:prefix]) {
            NSString *text = milestones[prefix].length ? [milestones[prefix] stringByAppendingString:[first substringFromIndex:prefix.length]] : first;
            [self addLine:text kind:MCLogOK];
            return;
        }
    }
    NSString *who = [logger hasPrefix:@"net.minecraft"] ? @"minecraft"
        : [[logger componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"./"]] lastObject];
    NSString *text = who.length ? [NSString stringWithFormat:@"%@: %@", who, first] : first;
    if (thr && ![level isEqualToString:@"INFO"]) text = [NSString stringWithFormat:@"%@ (%@)", text, FirstLine(thr)];
    MCLogKind kind = [level isEqualToString:@"ERROR"] || [level isEqualToString:@"FATAL"] ? MCLogWarn
                   : [level isEqualToString:@"WARN"] ? MCLogDim : MCLogPlain;
    [self addLine:text kind:kind];
}
@end
