#include "pch.hpp"

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

struct Motion {
    CGKeyCode    keyCode;
    CGEventFlags baseFlags;
    bool         valid;

    CGEventFlags selectFlags() const { return baseFlags | kCGEventFlagMaskShift; }

    static Motion forChar(unichar c) {
        switch (c) {
            case 'h': return {kVK_LeftArrow,  0,                         true};
            case 'l': return {kVK_RightArrow, 0,                         true};
            case 'e': return {kVK_RightArrow, kCGEventFlagMaskAlternate, true};
            case 'b': return {kVK_LeftArrow,  kCGEventFlagMaskAlternate, true};
            case 'w': return {kVK_DownArrow,  kCGEventFlagMaskCommand,   true}; // EOF
            case 'W': return {kVK_UpArrow,    kCGEventFlagMaskCommand,   true}; // BOF
            default:  return {0, 0, false};
        }
    }
};

// ---------------------------------------------------------------------------
// ChangeType — for . repeat
// ---------------------------------------------------------------------------

enum class ChangeType : uint8_t {
    None,
    DeleteChar,
    DeleteToEOL,
    DeleteToSOL,
    DeleteLine,
    DeleteTwoLines,
    DeleteMotion,   // _lastChangeArg = motion char
    ReplaceChar,    // _lastChangeArg = replacement unichar
    PasteAfter,
    PasteBefore,
};

// ---------------------------------------------------------------------------
// Mode
// ---------------------------------------------------------------------------

enum class VimMode : uint8_t {
    Insert,
    Normal,
    VisualChar,
    VisualLine,
    Search,
};

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

@interface VimInputController : IMKInputController
@end

@interface VimInputController() {
    VimMode    _mode;
    unichar    _pendingOp;          // operator: d c f F r  (0 = none)
    unichar    _pendingTextObjType; // text-object selector: i a  (0 = none)
    unichar    _findChar;
    BOOL       _findForward;
    ChangeType _lastChangeType;
    unichar    _lastChangeArg;
}
@end

@implementation VimInputController

- (instancetype)initWithServer:(IMKServer *)server
                      delegate:(id)delegate
                        client:(id<IMKTextInput>)inputClient {
    self = [super initWithServer:server delegate:delegate client:inputClient];
    if (self) {
        _mode              = VimMode::Insert;
        _pendingOp         = 0;
        _pendingTextObjType = 0;
        _findChar          = 0;
        _findForward       = YES;
        _lastChangeType    = ChangeType::None;
        _lastChangeArg     = 0;
    }
    return self;
}

// ---------------------------------------------------------------------------
// IMKServerInput — text input
// ---------------------------------------------------------------------------

- (BOOL)inputText:(NSString *)string client:(id<IMKTextInput>)sender {
    if (_mode == VimMode::Insert || _mode == VimMode::Search) return NO;
    if (string.length == 0) return YES;
    unichar c = [string characterAtIndex:0];

    // ---- Visual modes ----
    if (_mode == VimMode::VisualChar || _mode == VimMode::VisualLine) {
        return [self handleVisualChar:c client:sender];
    }

    // ---- Normal: operator-pending ----
    if (_pendingOp != 0) {
        unichar op = _pendingOp;

        // Level 2: already have i/a, waiting for the delimiter
        if (_pendingTextObjType != 0) {
            unichar sel = _pendingTextObjType;
            _pendingOp         = 0;
            _pendingTextObjType = 0;
            [self applyOp:op textObject:c selector:sel inClient:sender];
            return YES;
        }

        // Level 1: i/a starts a text object (don't reset _pendingOp yet)
        if (c == 'i' || c == 'a') {
            _pendingTextObjType = c;
            return YES;
        }

        // Regular motion / operator doubling
        _pendingOp = 0;

        if (op == 'f' || op == 'F') {
            _findChar    = c;
            _findForward = (op == 'f');
            [self findChar:c forward:_findForward inClient:sender];

        } else if (op == 'r') {
            [self replaceCharWith:string inClient:sender];
            [self recordChange:ChangeType::ReplaceChar arg:c];

        } else {
            auto motion = Motion::forChar(c);
            if (op == 'd') {
                if      (c == 'd') { [self deleteCurrentLine];        [self recordChange:ChangeType::DeleteLine     arg:0]; }
                else if (c == 'j') { [self deleteCurrentAndNextLine]; [self recordChange:ChangeType::DeleteTwoLines arg:0]; }
                else if (motion.valid) { [self deleteWithMotion:motion]; [self recordChange:ChangeType::DeleteMotion arg:c]; }
            } else if (op == 'c') {
                if      (c == 'c') [self yankCurrentLine];
                else if (motion.valid) [self yankWithMotion:motion];
            }
        }
        return YES;
    }

    // ---- Normal: commands ----
    switch (c) {
        case 'h': [self sendKey:kVK_LeftArrow  flags:0]; break;
        case 'j': [self sendKey:kVK_DownArrow  flags:0]; break;
        case 'k': [self sendKey:kVK_UpArrow    flags:0]; break;
        case 'l': [self sendKey:kVK_RightArrow flags:0]; break;
        case 'e': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskAlternate]; break;
        case 'b': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskAlternate]; break;
        case 'w': [self sendKey:kVK_DownArrow  flags:kCGEventFlagMaskCommand];   break;
        case 'W': [self sendKey:kVK_UpArrow    flags:kCGEventFlagMaskCommand];   break;

        case 'i': [self enterInsert]; break;
        case 'a': [self sendKey:kVK_RightArrow flags:0];                          [self enterInsert]; break;
        case 'A': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand];    [self enterInsert]; break;
        case 'I': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskCommand];    [self enterInsert]; break;
        case 'o': [self newLineBelow]; break;
        case 'O': [self newLineAbove]; break;

        case 'v': [self enterVisualChar]; break;
        case 'V': [self enterVisualLine];  break;

        case 'x': [self sendKey:kVK_ForwardDelete flags:0];
                  [self recordChange:ChangeType::DeleteChar arg:0]; break;
        case 'E': [self deleteToEndOfLine];   [self recordChange:ChangeType::DeleteToEOL arg:0]; break;
        case 'B': [self deleteToStartOfLine]; [self recordChange:ChangeType::DeleteToSOL arg:0]; break;

        case 'd': _pendingOp = 'd'; break;
        case 'c': _pendingOp = 'c'; break;

        case 'f': _pendingOp = 'f'; break;
        case 'F': _pendingOp = 'F'; break;
        case ';': if (_findChar) [self findChar:_findChar forward:_findForward  inClient:sender]; break;
        case ',': if (_findChar) [self findChar:_findChar forward:!_findForward inClient:sender]; break;
        case 'r': _pendingOp = 'r'; break;

        case 'u': [self sendKey:kVK_ANSI_Z flags:kCGEventFlagMaskCommand];                        break;
        case 'U': [self sendKey:kVK_ANSI_Z flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift]; break;

        case 'p': [self pasteAfter];  [self recordChange:ChangeType::PasteAfter  arg:0]; break;
        case 'P': [self sendKey:kVK_ANSI_V flags:kCGEventFlagMaskCommand];
                  [self recordChange:ChangeType::PasteBefore arg:0]; break;

        case '/': [self enterSearch]; break;
        case '?': [self enterSearch]; break;
        case 'n': [self sendKey:kVK_ANSI_G flags:kCGEventFlagMaskCommand];                        break;
        case 'N': [self sendKey:kVK_ANSI_G flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift]; break;

        case '.': [self repeatLastChange:sender]; break;

        default: break;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// Visual mode input
// ---------------------------------------------------------------------------

- (BOOL)handleVisualChar:(unichar)c client:(id<IMKTextInput>)sender {
    // Level 2: have i/a, waiting for delimiter
    if (_pendingTextObjType != 0) {
        unichar sel = _pendingTextObjType;
        _pendingTextObjType = 0;
        [self selectTextObject:c selector:sel inClient:sender];
        return YES;
    }

    switch (c) {
        // Motion — extend selection
        case 'h': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskShift]; break;
        case 'j': [self sendKey:kVK_DownArrow  flags:kCGEventFlagMaskShift]; break;
        case 'k': [self sendKey:kVK_UpArrow    flags:kCGEventFlagMaskShift]; break;
        case 'l': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift]; break;
        case 'e': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift | kCGEventFlagMaskAlternate]; break;
        case 'b': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskShift | kCGEventFlagMaskAlternate]; break;
        case 'w': [self sendKey:kVK_DownArrow  flags:kCGEventFlagMaskShift | kCGEventFlagMaskCommand];   break;
        case 'W': [self sendKey:kVK_UpArrow    flags:kCGEventFlagMaskShift | kCGEventFlagMaskCommand];   break;

        // Operators
        case 'd': [self deleteVisualSelection]; break;
        case 'c': [self yankVisualSelection];   break;

        // Text objects — enter level-1 pending
        case 'i': _pendingTextObjType = 'i'; break;
        case 'a': _pendingTextObjType = 'a'; break;

        // Find
        case 'f': _pendingOp = 'f'; break;
        case 'F': _pendingOp = 'F'; break;
        case ';': if (_findChar) [self findChar:_findChar forward:_findForward  inClient:sender]; break;
        case ',': if (_findChar) [self findChar:_findChar forward:!_findForward inClient:sender]; break;

        default: break;
    }
    return YES;
}

// ---------------------------------------------------------------------------
// IMKServerInput — command selectors
// ---------------------------------------------------------------------------

- (BOOL)didCommandBySelector:(SEL)aSelector client:(id<IMKTextInput>)sender {
    if (_mode == VimMode::Search) {
        if (aSelector == @selector(insertNewline:) ||
            aSelector == @selector(insertNewlineIgnoringFieldEditor:) ||
            aSelector == @selector(cancelOperation:)) {
            [self enterNormal];
        }
        return NO;
    }

    if (aSelector == @selector(cancelOperation:)) {
        if (_mode == VimMode::Insert) {
            [self enterNormal];
            return YES;
        }
        if (_mode == VimMode::VisualChar || _mode == VimMode::VisualLine) {
            [self sendKey:kVK_LeftArrow flags:0];
            [self enterNormal];
            return YES;
        }
        if (_pendingOp != 0 || _pendingTextObjType != 0) {
            _pendingOp         = 0;
            _pendingTextObjType = 0;
            return YES;
        }
        return NO;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Mode transitions
// ---------------------------------------------------------------------------

- (void)enterNormal {
    _mode              = VimMode::Normal;
    _pendingOp         = 0;
    _pendingTextObjType = 0;
    os_log_info(OS_LOG_DEFAULT, "VimKeys: NORMAL");
}
- (void)enterInsert {
    _mode = VimMode::Insert;
    os_log_info(OS_LOG_DEFAULT, "VimKeys: INSERT");
}
- (void)enterVisualChar {
    _mode = VimMode::VisualChar;
    os_log_info(OS_LOG_DEFAULT, "VimKeys: VISUAL CHAR");
}
- (void)enterVisualLine {
    _mode = VimMode::VisualLine;
    [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift];
    os_log_info(OS_LOG_DEFAULT, "VimKeys: VISUAL LINE");
}
- (void)enterSearch {
    _mode = VimMode::Search;
    [self sendKey:kVK_ANSI_F flags:kCGEventFlagMaskCommand];
    os_log_info(OS_LOG_DEFAULT, "VimKeys: SEARCH");
}

// ---------------------------------------------------------------------------
// Text object range finders (Phase 7)
// ---------------------------------------------------------------------------

// Dispatch: return the inner (sel=='i') or outer (sel=='a') NSRange for a
// text object identified by `delim` at the current cursor position.
// Returns {NSNotFound,0} when the object cannot be found.
- (NSRange)textObjectRange:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange cursor = [sender selectedRange];
    if (cursor.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
    NSUInteger pos = cursor.location;
    id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;

    switch (delim) {
        case 'w':                            return [self wordRange:pos selector:sel tc:tc];
        case '"':                            return [self quotedRange:'"'  at:pos selector:sel tc:tc];
        case '\'':                           return [self quotedRange:'\'' at:pos selector:sel tc:tc];
        case '(': case ')':                  return [self bracketRange:'(' close:')' at:pos selector:sel tc:tc];
        case '[': case ']':                  return [self bracketRange:'[' close:']' at:pos selector:sel tc:tc];
        case '{': case '}':                  return [self bracketRange:'{' close:'}' at:pos selector:sel tc:tc];
        default:                             return NSMakeRange(NSNotFound, 0);
    }
}

// WORD text object — iw/aw map to iW/aW per user's nvim config.
// A WORD is a maximal run of non-whitespace characters.
- (NSRange)wordRange:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 512);
    NSUInteger bufStart = pos - before;

    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 512)
                                                         actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);

    NSUInteger cur = before; // cursor offset within buf

    // Walk backward to WORD start
    NSUInteger ws = cur;
    while (ws > 0 && ![self isWordBoundary:[buf characterAtIndex:ws - 1]]) ws--;
    // Walk forward to WORD end
    NSUInteger we = cur;
    while (we < buf.length && ![self isWordBoundary:[buf characterAtIndex:we]]) we++;

    if (we == ws) return NSMakeRange(NSNotFound, 0); // cursor is on whitespace

    NSRange inner = NSMakeRange(bufStart + ws, we - ws);
    if (sel == 'i') return inner;

    // Outer: include trailing whitespace (prefer trailing over leading per vim)
    NSUInteger oe = we;
    while (oe < buf.length && [buf characterAtIndex:oe] == ' ') oe++;
    if (oe > we) return NSMakeRange(bufStart + ws, oe - ws);

    // No trailing, include leading
    NSUInteger os2 = ws;
    while (os2 > 0 && [buf characterAtIndex:os2 - 1] == ' ') os2--;
    return NSMakeRange(bufStart + os2, we - os2);
}

- (BOOL)isWordBoundary:(unichar)ch {
    return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
}

// Quoted string text object — finds balanced pair of `delim` on current line.
- (NSRange)quotedRange:(unichar)delim at:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 512);
    NSUInteger bufStart = pos - before;
    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 512)
                                                         actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);
    NSUInteger cur = before;

    // Narrow to current line
    NSUInteger lineStart = cur;
    while (lineStart > 0 && [buf characterAtIndex:lineStart - 1] != '\n') lineStart--;
    NSUInteger lineEnd = cur;
    while (lineEnd < buf.length && [buf characterAtIndex:lineEnd] != '\n') lineEnd++;

    // Collect delimiter positions on this line
    NSMutableArray<NSNumber *> *positions = [NSMutableArray array];
    for (NSUInteger i = lineStart; i < lineEnd; i++) {
        if ([buf characterAtIndex:i] == delim) [positions addObject:@(i)];
    }

    // Find the pair that contains the cursor
    for (NSUInteger i = 0; i + 1 < positions.count; i += 2) {
        NSUInteger left  = positions[i].unsignedIntegerValue;
        NSUInteger right = positions[i + 1].unsignedIntegerValue;
        if (left <= cur && cur <= right) {
            if (sel == 'i') return NSMakeRange(bufStart + left + 1, right - left - 1);
            else            return NSMakeRange(bufStart + left,      right - left + 1);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

// Balanced bracket text object — handles nesting, works across lines.
- (NSRange)bracketRange:(unichar)open close:(unichar)close
                    at:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 2048);
    NSUInteger bufStart = pos - before;
    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 2048)
                                                         actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);
    NSUInteger cur = before;

    // Find matching open bracket (scan backward)
    NSInteger depth = 0;
    NSUInteger openIdx = NSNotFound;
    for (NSInteger i = (NSInteger)cur; i >= 0; i--) {
        unichar ch = [buf characterAtIndex:(NSUInteger)i];
        if (ch == close)      depth++;
        else if (ch == open) {
            if (depth == 0) { openIdx = (NSUInteger)i; break; }
            depth--;
        }
    }
    if (openIdx == NSNotFound) return NSMakeRange(NSNotFound, 0);

    // Find matching close bracket (scan forward from open)
    depth = 0;
    NSUInteger closeIdx = NSNotFound;
    for (NSUInteger i = openIdx + 1; i < buf.length; i++) {
        unichar ch = [buf characterAtIndex:i];
        if (ch == open)      depth++;
        else if (ch == close) {
            if (depth == 0) { closeIdx = i; break; }
            depth--;
        }
    }
    if (closeIdx == NSNotFound) return NSMakeRange(NSNotFound, 0);

    if (sel == 'i') return NSMakeRange(bufStart + openIdx + 1, closeIdx - openIdx - 1);
    else            return NSMakeRange(bufStart + openIdx,     closeIdx - openIdx + 1);
}

// ---------------------------------------------------------------------------
// Text object application (Phase 7)
// ---------------------------------------------------------------------------

// Apply operator op ('d' delete, 'c' yank) to the text object at cursor.
- (void)applyOp:(unichar)op textObject:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange range = [self textObjectRange:delim selector:sel inClient:sender];
    if (range.location == NSNotFound) return;

    if (op == 'd') {
        // Delete: replace the range with empty string.
        [sender insertText:@"" replacementRange:range];

    } else if (op == 'c') {
        // Yank: copy range content to system clipboard, cursor to range start.
        id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;
        NSAttributedString *as = [tc attributedSubstringForProposedRange:range actualRange:nil];
        if (as.string) {
            NSPasteboard *pb = NSPasteboard.generalPasteboard;
            [pb clearContents];
            [pb setString:as.string forType:NSPasteboardTypeString];
        }
        [sender insertText:@"" replacementRange:NSMakeRange(range.location, 0)];
    }
}

// In visual mode: reselect using the text object range.
// Places cursor at range start, then synthesises Shift+→ × length to extend.
- (void)selectTextObject:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange range = [self textObjectRange:delim selector:sel inClient:sender];
    if (range.location == NSNotFound) return;

    // Collapse cursor to start of text object (synchronous)
    [sender insertText:@"" replacementRange:NSMakeRange(range.location, 0)];

    // Extend selection rightward by range.length (capped for safety)
    NSUInteger steps = MIN(range.length, 500);
    for (NSUInteger i = 0; i < steps; i++) {
        [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift];
    }
}

// ---------------------------------------------------------------------------
// Repeat last change
// ---------------------------------------------------------------------------

- (void)recordChange:(ChangeType)type arg:(unichar)arg {
    _lastChangeType = type;
    _lastChangeArg  = arg;
}

- (void)repeatLastChange:(id<IMKTextInput>)sender {
    switch (_lastChangeType) {
        case ChangeType::None:           break;
        case ChangeType::DeleteChar:     [self sendKey:kVK_ForwardDelete flags:0]; break;
        case ChangeType::DeleteToEOL:    [self deleteToEndOfLine];   break;
        case ChangeType::DeleteToSOL:    [self deleteToStartOfLine]; break;
        case ChangeType::DeleteLine:     [self deleteCurrentLine];         break;
        case ChangeType::DeleteTwoLines: [self deleteCurrentAndNextLine];  break;
        case ChangeType::DeleteMotion: {
            auto m = Motion::forChar(_lastChangeArg);
            if (m.valid) [self deleteWithMotion:m];
            break;
        }
        case ChangeType::ReplaceChar: {
            NSString *s = [NSString stringWithCharacters:&_lastChangeArg length:1];
            [self replaceCharWith:s inClient:sender];
            break;
        }
        case ChangeType::PasteAfter:   [self pasteAfter]; break;
        case ChangeType::PasteBefore:  [self sendKey:kVK_ANSI_V flags:kCGEventFlagMaskCommand]; break;
    }
}

// ---------------------------------------------------------------------------
// Find on line
// ---------------------------------------------------------------------------

- (void)findChar:(unichar)target forward:(BOOL)forward inClient:(id<IMKTextInput>)sender {
    NSRange sel = [sender selectedRange];
    if (sel.location == NSNotFound) return;
    id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;
    NSAttributedString *as;
    NSString *line;
    NSUInteger found = NSNotFound;

    if (forward) {
        as = [tc attributedSubstringForProposedRange:NSMakeRange(sel.location + 1, 512) actualRange:nil];
        line = as.string;
        if (!line) return;
        for (NSUInteger i = 0; i < line.length; i++) {
            unichar ch = [line characterAtIndex:i];
            if (ch == '\n' || ch == '\r') break;
            if (ch == target) { found = sel.location + 1 + i; break; }
        }
    } else {
        NSUInteger len = (sel.location < 512) ? sel.location : 512;
        NSUInteger start = sel.location - len;
        as = [tc attributedSubstringForProposedRange:NSMakeRange(start, len) actualRange:nil];
        line = as.string;
        if (!line) return;
        for (NSUInteger i = 0; i < line.length; i++) {
            unichar ch = [line characterAtIndex:i];
            if (ch == '\n' || ch == '\r') found = NSNotFound;
            else if (ch == target) found = start + i;
        }
    }
    if (found != NSNotFound) [sender insertText:@"" replacementRange:NSMakeRange(found, 0)];
}

// ---------------------------------------------------------------------------
// Replace char
// ---------------------------------------------------------------------------

- (void)replaceCharWith:(NSString *)replacement inClient:(id<IMKTextInput>)sender {
    NSRange sel = [sender selectedRange];
    if (sel.location == NSNotFound) return;
    [sender insertText:replacement replacementRange:NSMakeRange(sel.location, 1)];
    [self sendKey:kVK_LeftArrow flags:0];
}

// ---------------------------------------------------------------------------
// Visual selection operators
// ---------------------------------------------------------------------------

- (void)deleteVisualSelection {
    [self sendKey:kVK_Delete flags:0];
    [self enterNormal];
}

- (void)yankVisualSelection {
    [self sendKey:kVK_ANSI_C    flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_LeftArrow flags:0];
    [self enterNormal];
}

// ---------------------------------------------------------------------------
// Operator + motion helpers
// ---------------------------------------------------------------------------

- (void)deleteWithMotion:(Motion)motion {
    [self sendKey:motion.keyCode flags:motion.selectFlags()];
    [self sendKey:kVK_Delete     flags:0];
}
- (void)yankWithMotion:(Motion)motion {
    [self sendKey:motion.keyCode flags:motion.selectFlags()];
    [self sendKey:kVK_ANSI_C     flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_LeftArrow  flags:0];
}
- (void)deleteCurrentLine {
    [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift];
    [self sendKey:kVK_Delete    flags:0];
}
- (void)deleteCurrentAndNextLine {
    [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift];
    [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift];
    [self sendKey:kVK_Delete    flags:0];
}
- (void)yankCurrentLine {
    [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift];
    [self sendKey:kVK_ANSI_C     flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_LeftArrow  flags:0];
}

// ---------------------------------------------------------------------------
// Line / insert helpers
// ---------------------------------------------------------------------------

- (void)newLineBelow {
    [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_Return     flags:0];
    [self enterInsert];
}
- (void)newLineAbove {
    [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskCommand];
    [self sendKey:kVK_Return     flags:0];
    [self sendKey:kVK_UpArrow    flags:0];
    [self enterInsert];
}
- (void)deleteToEndOfLine {
    [self sendKey:kVK_RightArrow    flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift];
    [self sendKey:kVK_ForwardDelete flags:0];
}
- (void)deleteToStartOfLine {
    [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift];
    [self sendKey:kVK_Delete    flags:0];
}
- (void)pasteAfter {
    [self sendKey:kVK_RightArrow flags:0];
    [self sendKey:kVK_ANSI_V     flags:kCGEventFlagMaskCommand];
}

// ---------------------------------------------------------------------------
// Key synthesis
// ---------------------------------------------------------------------------

- (void)sendKey:(CGKeyCode)keyCode flags:(CGEventFlags)flags {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    if (flags) { CGEventSetFlags(down, flags); CGEventSetFlags(up, flags); }
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

@end
