#include "pch.hpp"
#include "AppDelegate.hpp"

auto main(int argc, const char * argv[]) -> int {
    @autoreleasepool {
        auto bundle = NSBundle.mainBundle;
        NSString * connectionName = [bundle objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        [[maybe_unused]]
        auto server = [[IMKServer alloc] initWithName:connectionName
                                     bundleIdentifier:bundle.bundleIdentifier];
        [NSApplication sharedApplication];
        NSApp.delegate = [[AppDelegate alloc] init];
        [NSApp run];
    }
    return 0;
}
