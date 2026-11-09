#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Microsoft sign-in for Minecraft. The TV has no browser, so this uses a device
// code. The TV shows a code, you enter it at microsoft.com/link on a phone, and
// the TV picks up the result. The token chain after that is Amethyst's
// (amethyst/Natives/authenticator/MicrosoftAuthenticator.m), with the Minecraft
// launcher's own client ID.
//
// The account is stored the way Amethyst stores it, so its launcher and account
// library work unchanged. home/accounts/<name>.json holds the name, UUID and
// Xbox user hash ("xuid"). The access and refresh tokens go in the Keychain
// under that hash. home/mctv-account.txt names the signed-in account.
@interface MCAccount : NSObject

// The signed-in account's player name, if there is one.
+ (nullable NSString *)signedInName;

// Runs the device code flow on a background queue. `code` is called (on the main
// queue) with each code to show, again whenever one expires. `done` gets the
// player name, or a message saying what went wrong.
+ (void)signInShowing:(void (^)(NSString *code, NSURL *url))code
                 done:(void (^)(NSString *_Nullable name, NSString *_Nullable error))done;

// Gets fresh tokens when the saved ones are close to running out. `done` (main
// queue) says whether the account can be used, and why not or what happened.
+ (void)refreshIfNeeded:(void (^)(BOOL usable, NSString *_Nullable note))done;

@end

// What Amethyst's libAmethystAccountJNI looks up by name for the access token.
@interface MicrosoftAuthenticator : NSObject
+ (nullable NSDictionary *)tokenDataOfProfile:(NSString *)xuid;
@end

NS_ASSUME_NONNULL_END
