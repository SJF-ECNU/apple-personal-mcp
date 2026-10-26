#!/bin/bash
# Synthetic fixtures from Apple's public, deprecated archiver; never reads chat.db.
set -euo pipefail
cd "$(dirname "$0")/.."
APM_FIXTURE_TMP=$(mktemp -d)
trap 'rm -rf "$APM_FIXTURE_TMP"' EXIT
cat > "$APM_FIXTURE_TMP/generate.m" <<'OBJC'
#import <Foundation/Foundation.h>
int main(int argc, const char * argv[]) { @autoreleasepool {
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *pattern = @"中文 DNS AttributeNS 👩🏽‍💻\n";
    NSMutableString *longText = [NSMutableString string];
    for (int i = 0; i < 4000; i++) [longText appendString:pattern];
    NSDictionary *fixtures = @{@"metadata-words": @"DNS AttributeNS __k text 👩🏽‍💻\n", @"emoji": @"👩🏽‍💻🙂\uFFFC", @"long": longText};
    for (NSString *name in fixtures) {
        NSMutableAttributedString *value = [[NSMutableAttributedString alloc] initWithString:fixtures[name]];
        [value addAttribute:@"__kIMMessagePartAttributeName" value:@0 range:NSMakeRange(0, value.length)];
        NSData *data = [NSArchiver archivedDataWithRootObject:value];
        [data writeToFile:[root stringByAppendingPathComponent:[name stringByAppendingString:@".typedstream"]] atomically:YES];
    }
} return 0; }
OBJC
mkdir -p Tests/PersonalCoreTests/Fixtures
xcrun clang -Wno-deprecated-declarations -framework Foundation "$APM_FIXTURE_TMP/generate.m" -o "$APM_FIXTURE_TMP/generate"
"$APM_FIXTURE_TMP/generate" "$PWD/Tests/PersonalCoreTests/Fixtures"
