#import "MCAccount.h"
#import <Security/Security.h>
#import "JVM.h"

// The Minecraft launcher's client ID and scope, as Amethyst uses them.
static NSString *const kClientID = @"00000000402b5328";
static NSString *const kScope = @"service::user.auth.xboxlive.com::MBI_SSL";
// Minecraft's access token lasts a day. Refresh when less than this is left.
static const NSTimeInterval kRefreshBefore = 12 * 3600;

static NSString *HomeDir(void) { return [MCDataDir() stringByAppendingPathComponent:@"home"]; }
static NSString *CurrentFile(void) { return [HomeDir() stringByAppendingPathComponent:@"mctv-account.txt"]; }
static NSString *AccountFile(NSString *name) {
    return [[HomeDir() stringByAppendingPathComponent:@"accounts"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
}

#pragma mark - HTTP

// A blocking request with a JSON or form body. Returns the parsed JSON (or an
// empty dictionary), and the HTTP status in *status (0 when there's no network).
static NSDictionary *Request(NSString *url, id _Nullable body, BOOL form, NSDictionary *_Nullable headers, NSInteger *status) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 30;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (body) {
        req.HTTPMethod = @"POST";
        if (form) {
            NSURLComponents *c = [NSURLComponents new];
            NSMutableArray *items = [NSMutableArray array];
            for (NSString *k in body) [items addObject:[NSURLQueryItem queryItemWithName:k value:body[k]]];
            c.queryItems = items;
            // A + in a value must not turn into a space.
            req.HTTPBody = [[c.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"] dataUsingEncoding:NSUTF8StringEncoding];
            [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        } else {
            req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
            [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
    }
    for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
    __block NSData *data;
    __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d;
        code = e ? 0 : ((NSHTTPURLResponse *)r).statusCode;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    *status = code;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : @{};
}

#pragma mark - Keychain (as Amethyst's MicrosoftAuthenticator)

static NSMutableDictionary *KeychainQuery(NSString *xuid) {
    return [@{(id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: @"AccountToken",
              (id)kSecAttrAccount: xuid} mutableCopy];
}

// scripts/mc-sim.sh builds the simulator app unsigned, and an unsigned app
// can't use the Keychain (errSecMissingEntitlement). The simulator keeps the
// tokens in a file beside the account instead. Signed builds never do.
static NSString *TokenFile(NSString *xuid) {
    return [[HomeDir() stringByAppendingPathComponent:@"accounts"] stringByAppendingPathComponent:[xuid stringByAppendingPathExtension:@"tokens"]];
}

static BOOL SaveTokens(NSString *xuid, NSString *access, NSString *refresh) {
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@{@"accessToken": access, @"refreshToken": refresh}
                                         requiringSecureCoding:YES error:nil];
    NSMutableDictionary *q = KeychainQuery(xuid);
    SecItemDelete((__bridge CFDictionaryRef)q);
    q[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    q[(id)kSecValueData] = data;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
#if TARGET_OS_SIMULATOR
    if (status == errSecMissingEntitlement) {
        [NSFileManager.defaultManager createDirectoryAtPath:TokenFile(xuid).stringByDeletingLastPathComponent
                                withIntermediateDirectories:YES attributes:nil error:nil];
        return [data writeToFile:TokenFile(xuid) atomically:YES];
    }
#endif
    if (status != errSecSuccess) MCLog(@"Sign-in: the Keychain said %d", (int)status);
    return status == errSecSuccess;
}

static NSDictionary *LoadTokens(NSString *xuid) {
    NSMutableDictionary *q = KeychainQuery(xuid);
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    q[(id)kSecReturnData] = (id)kCFBooleanTrue;
    CFTypeRef result = NULL;
    NSData *data = nil;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) == errSecSuccess) data = (__bridge_transfer NSData *)result;
#if TARGET_OS_SIMULATOR
    if (!data) data = [NSData dataWithContentsOfFile:TokenFile(xuid)];
#endif
    if (!data) return nil;
    return [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, nil]
                                               fromData:data error:nil];
}

@implementation MicrosoftAuthenticator
+ (NSDictionary *)tokenDataOfProfile:(NSString *)xuid { return LoadTokens(xuid); }
@end

#pragma mark - The token chain

// Turns a Microsoft access token into a saved Minecraft account, through Xbox
// Live, XSTS, Minecraft's login and the profile. Returns nil and sets *nameOut,
// or returns what went wrong.
static NSString *FinishSignIn(NSString *msaAccess, NSString *msaRefresh, NSString **nameOut) {
    NSInteger st;
    NSDictionary *xbl = Request(@"https://user.auth.xboxlive.com/user/authenticate", @{
        @"Properties": @{@"AuthMethod": @"RPS", @"SiteName": @"user.auth.xboxlive.com", @"RpsTicket": msaAccess},
        @"RelyingParty": @"http://auth.xboxlive.com", @"TokenType": @"JWT"}, NO, nil, &st);
    if (st != 200) return st ? [NSString stringWithFormat:@"Xbox Live said no (HTTP %ld).", (long)st] : @"No internet connection.";
    NSString *uhs = xbl[@"DisplayClaims"][@"xui"][0][@"uhs"];
    NSDictionary *xsts = Request(@"https://xsts.auth.xboxlive.com/xsts/authorize", @{
        @"Properties": @{@"SandboxId": @"RETAIL", @"UserTokens": @[xbl[@"Token"] ?: @""]},
        @"RelyingParty": @"rp://api.minecraftservices.com/", @"TokenType": @"JWT"}, NO, nil, &st);
    if (st != 200) {
        switch ([xsts[@"XErr"] longLongValue]) {
            case 2148916233: return @"This Microsoft account has no Xbox profile yet. Sign in once at xbox.com to make one, then try again.";
            case 2148916235: return @"Xbox Live isn't available in this account's country.";
            case 2148916236: case 2148916237: return @"This account needs adult verification at xbox.com first.";
            case 2148916238: return @"This is a child account. An adult needs to add it to a Microsoft family first.";
            default: return [NSString stringWithFormat:@"Xbox Live refused the sign-in (HTTP %ld, XErr %@).", (long)st, xsts[@"XErr"] ?: @"none"];
        }
    }
    NSDictionary *mc = Request(@"https://api.minecraftservices.com/authentication/login_with_xbox",
        @{@"identityToken": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", uhs, xsts[@"Token"]]}, NO, nil, &st);
    NSString *mcToken = mc[@"access_token"];
    if (st != 200 || !mcToken) return [NSString stringWithFormat:@"Minecraft's login said no (HTTP %ld).", (long)st];
    NSDictionary *profile = Request(@"https://api.minecraftservices.com/minecraft/profile", nil, NO,
        @{@"Authorization": [@"Bearer " stringByAppendingString:mcToken]}, &st);
    if (st == 404) return @"This Microsoft account doesn't own Minecraft: Java Edition.";
    NSString *uuid = profile[@"id"], *name = profile[@"name"];
    if (st != 200 || uuid.length != 32 || !name.length) return [NSString stringWithFormat:@"Couldn't read the Minecraft profile (HTTP %ld).", (long)st];

    if (!SaveTokens(uhs, mcToken, msaRefresh)) return @"Couldn't save the sign-in to the Keychain.";
    NSString *dashed = [NSString stringWithFormat:@"%@-%@-%@-%@-%@", [uuid substringWithRange:NSMakeRange(0, 8)],
        [uuid substringWithRange:NSMakeRange(8, 4)], [uuid substringWithRange:NSMakeRange(12, 4)],
        [uuid substringWithRange:NSMakeRange(16, 4)], [uuid substringWithRange:NSMakeRange(20, 12)]];
    // Amethyst's account file. The launcher reads the token from the Keychain
    // because "xuid" is set, so accessToken here is only a placeholder.
    NSDictionary *account = @{@"username": name, @"profileId": dashed, @"xuid": uhs, @"clientToken": @"0",
                              @"accessToken": @"0", @"expiresAt": @((long)NSDate.date.timeIntervalSince1970 + 86400)};
    NSString *path = AccountFile(name);
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *json = [NSJSONSerialization dataWithJSONObject:account options:NSJSONWritingPrettyPrinted error:nil];
    if (![json writeToFile:path atomically:YES] || ![name writeToFile:CurrentFile() atomically:YES encoding:NSUTF8StringEncoding error:nil])
        return @"Couldn't save the account file.";
    *nameOut = name;
    return nil;
}

@implementation MCAccount

+ (NSDictionary *)savedAccount {
    NSString *name = [[NSString stringWithContentsOfFile:CurrentFile() encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return nil;
    NSData *data = [NSData dataWithContentsOfFile:AccountFile(name)];
    NSDictionary *account = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![account isKindOfClass:NSDictionary.class] || ![account[@"xuid"] length] || !LoadTokens(account[@"xuid"])) return nil;
    return account;
}

+ (NSString *)signedInName { return [self savedAccount][@"username"]; }

+ (void)signInShowing:(void (^)(NSString *, NSURL *))showCode done:(void (^)(NSString *, NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^finish)(NSString *, NSString *) = ^(NSString *name, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(name, error); });
        };
        for (;;) {  // a new code whenever one runs out
            NSInteger st;
            NSDictionary *dc = Request(@"https://login.live.com/oauth20_connect.srf",
                @{@"client_id": kClientID, @"scope": kScope, @"response_type": @"device_code"}, YES, nil, &st);
            NSString *code = dc[@"user_code"], *device = dc[@"device_code"];
            if (st != 200 || !code || !device) {
                finish(nil, st ? [NSString stringWithFormat:@"Microsoft didn't give out a code (HTTP %ld).", (long)st]
                               : @"No internet connection.");
                return;
            }
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.microsoft.com/link?otc=%@", code]];
            dispatch_async(dispatch_get_main_queue(), ^{ showCode(code, url); });
            NSTimeInterval interval = MAX([dc[@"interval"] doubleValue], 5);
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:[dc[@"expires_in"] doubleValue] ?: 900];
            while ([deadline timeIntervalSinceNow] > 0) {
                [NSThread sleepForTimeInterval:interval];
                NSDictionary *tok = Request(@"https://login.live.com/oauth20_token.srf",
                    @{@"client_id": kClientID, @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code",
                      @"device_code": device}, YES, nil, &st);
                if (st == 200 && tok[@"access_token"]) {
                    NSString *name = nil;
                    NSString *error = FinishSignIn(tok[@"access_token"], tok[@"refresh_token"] ?: @"", &name);
                    finish(name, error);
                    return;
                }
                NSString *err = tok[@"error"];
                if ([err isEqualToString:@"slow_down"]) interval += 5;
                else if (st && ![err isEqualToString:@"authorization_pending"]) break;  // expired or declined, so get a new code
            }
        }
    });
}

+ (void)refreshIfNeeded:(void (^)(BOOL, NSString *))done {
    NSDictionary *account = [self savedAccount];
    if (!account) { done(NO, nil); return; }
    if ([account[@"expiresAt"] doubleValue] - NSDate.date.timeIntervalSince1970 > kRefreshBefore) { done(YES, nil); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^finish)(BOOL, NSString *) = ^(BOOL usable, NSString *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(usable, note); });
        };
        NSString *refresh = LoadTokens(account[@"xuid"])[@"refreshToken"];
        NSInteger st;
        NSDictionary *tok = Request(@"https://login.live.com/oauth20_token.srf",
            @{@"client_id": kClientID, @"grant_type": @"refresh_token", @"refresh_token": refresh ?: @"", @"scope": kScope},
            YES, nil, &st);
        if (!st) { finish(YES, @"Sign-in: no internet, so the saved login is used as it is"); return; }
        if (st != 200 || !tok[@"access_token"]) { finish(NO, @"Sign-in: the saved login has run out, so sign in again"); return; }
        NSString *name = nil;
        NSString *error = FinishSignIn(tok[@"access_token"], tok[@"refresh_token"] ?: refresh, &name);
        // A failure further along (Xbox or Minecraft down) leaves the old login in place.
        finish(YES, error ? [@"Sign-in: couldn't renew the login. " stringByAppendingString:error]
                          : [NSString stringWithFormat:@"Sign-in: renewed the login for %@", name]);
    });
}

@end
