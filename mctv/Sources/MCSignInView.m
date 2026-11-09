#import "MCSignInView.h"
#import <CoreImage/CoreImage.h>

@implementation MCSignInView {
    UILabel *_title, *_steps, *_code, *_problem;
    UIImageView *_qr;
    UIView *_qrBox;  // the white border a QR code needs around it
}

static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedSystemFontOfSize:size weight:weight];
    l.textColor = color;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        UIColor *text = [UIColor colorWithWhite:0.85 alpha:1];
        _title = Label(40, UIFontWeightSemibold, UIColor.whiteColor);
        _title.text = @"Sign in to play Minecraft";
        _steps = Label(26, UIFontWeightRegular, text);
        _steps.text = @"On your phone, scan the code, or go to microsoft.com/link\n"
                      @"and enter the code below. Use the Microsoft account that owns Minecraft.";
        _code = Label(84, UIFontWeightBold, UIColor.whiteColor);
        _code.text = @"...";
        _problem = Label(24, UIFontWeightRegular, [UIColor colorWithRed:1 green:0.55 blue:0.45 alpha:1]);
        _qrBox = [UIView new];
        _qrBox.backgroundColor = UIColor.whiteColor;
        _qrBox.hidden = YES;
        _qr = [UIImageView new];
        _qr.contentMode = UIViewContentModeScaleAspectFit;
        _qr.layer.magnificationFilter = kCAFilterNearest;
        [_qrBox addSubview:_qr];
        for (UIView *v in @[_title, _steps, _code, _problem, _qrBox]) [self addSubview:v];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, side = MIN(360, h * 0.34);
    CGFloat y = h * 0.12;
    _title.frame = CGRectMake(0, y, w, 56);
    y += 80;
    _steps.frame = CGRectMake(w * 0.1, y, w * 0.8, 80);
    y += 110;
    _qrBox.frame = CGRectMake((w - side) / 2, y, side, side);
    _qr.frame = CGRectInset(_qrBox.bounds, side * 0.07, side * 0.07);
    y += side + 30;
    _code.frame = CGRectMake(0, y, w, 100);
    y += 120;
    _problem.frame = CGRectMake(w * 0.1, y, w * 0.8, 90);
}

- (void)showCode:(NSString *)code url:(NSURL *)url {
    _code.text = code;
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[url.absoluteString dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *big = [f.outputImage imageByApplyingTransform:CGAffineTransformMakeScale(10, 10)];
    CGImageRef cg = [[CIContext context] createCGImage:big fromRect:big.extent];
    _qr.image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    _qrBox.hidden = NO;
}

- (void)showProblem:(NSString *)text {
    _problem.text = text;
}

@end
