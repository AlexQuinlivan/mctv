#import <GameController/GameController.h>

// Rumble on the game controller through Core Haptics. The game's levels come
// in through MCRumbleSet (bridge.h), from the mctv mod's hook in Controlify.
// MCInput calls this whenever the controller in use changes (nil for none).
void MCRumbleUseController(GCController *pad);
