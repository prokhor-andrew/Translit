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
            case 'w': return {kVK_DownArrow,  kCGEventFlagMaskCommand,   true};
            case 'W': return {kVK_UpArrow,    kCGEventFlagMaskCommand,   true};
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
    DeleteMotion,      // _lastChangeArg     = motion char
    ReplaceChar,       // _lastChangeArg     = replacement unichar
    PasteAfter,
    PasteBefore,
    InsertSession,     // _lastInsertEntry   = entry key, _lastInsertText = text
    DeleteTextObject,  // _lastChangeArg     = delim, _lastChangeTOSel = i/a
    YankTextObject,    // _lastChangeArg     = delim, _lastChangeTOSel = i/a
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
    VimMode          _mode;
    unichar          _pendingOp;
    unichar          _pendingTextObjType;
    unichar          _findChar;
    BOOL             _findForward;

    // . repeat — atomic ops
    ChangeType       _lastChangeType;
    unichar          _lastChangeArg;
    unichar          _lastChangeTOSel;  // text-object selector for repeat

    // . repeat — insert sessions (Phase 8)
    unichar          _insertEntryKey;   // entry key of current/last INSERT session
    NSMutableString *_insertBuffer;     // accumulates text in current INSERT session
    NSString        *_lastInsertText;   // text from last INSERT session
    unichar          _lastInsertEntry;  // entry key of last INSERT session
    BOOL             _replayingInsert;  // blocks re-recording during . replay
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
        _lastChangeTOSel   = 0;
        _insertEntryKey    = 'i';
        _insertBuffer      = nil;
        _lastInsertText    = nil;
        _lastInsertEntry   = 'i';
        _replayingInsert   = NO;
    }
    return self;
}

// ---------------------------------------------------------------------------
// IMKServerInput — text input
// ---------------------------------------------------------------------------

- (BOOL)inputText:(NSString *)string client:(id<IMKTextInput>)sender {
    // INSERT: pass through; also record text for . repeat (unless replaying)
    if (_mode == VimMode::Insert) {
        if (!_replayingInsert && _insertBuffer)
            [_insertBuffer appendString:string];
        return NO;
    }
    if (_mode == VimMode::Search) return NO;
    if (string.length == 0) return YES;
    unichar c = [string characterAtIndex:0];

    // ---- Visual modes ----
    if (_mode == VimMode::VisualChar || _mode == VimMode::VisualLine)
        return [self handleVisualChar:c client:sender];

    // ---- Normal: operator-pending ----
    if (_pendingOp != 0) {
        unichar op = _pendingOp;

        if (_pendingTextObjType != 0) {
            unichar sel = _pendingTextObjType;
            _pendingOp         = 0;
            _pendingTextObjType = 0;
            [self applyOp:op textObject:c selector:sel inClient:sender];
            return YES;
        }

        if (c == 'i' || c == 'a') {
            _pendingTextObjType = c;
            return YES;
        }

        _pendingOp = 0;

        if (op == 'f' || op == 'F') {
            _findChar    = c;
            _findForward = (op == 'f');
            [self findChar:c forward:_findForward inClient:sender];
        } else if (op == 'r') {
            [self replaceCharWith:string inClient:sender];
            [self recordChange:ChangeType::ReplaceChar arg:c toSel:0];
        } else {
            auto motion = Motion::forChar(c);
            if (op == 'd') {
                if      (c == 'd') { [self deleteCurrentLine];        [self recordChange:ChangeType::DeleteLine     arg:0 toSel:0]; }
                else if (c == 'j') { [self deleteCurrentAndNextLine]; [self recordChange:ChangeType::DeleteTwoLines arg:0 toSel:0]; }
                else if (motion.valid) { [self deleteWithMotion:motion]; [self recordChange:ChangeType::DeleteMotion arg:c toSel:0]; }
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

        case 'i': _insertEntryKey = 'i'; [self enterInsert]; break;
        case 'a': _insertEntryKey = 'a'; [self sendKey:kVK_RightArrow flags:0];                          [self enterInsert]; break;
        case 'A': _insertEntryKey = 'A'; [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand];    [self enterInsert]; break;
        case 'I': _insertEntryKey = 'I'; [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskCommand];    [self enterInsert]; break;
        case 'o': [self newLineBelow]; break;
        case 'O': [self newLineAbove]; break;

        case 'v': [self enterVisualChar]; break;
        case 'V': [self enterVisualLine];  break;

        case 'x': [self sendKey:kVK_ForwardDelete flags:0]; [self recordChange:ChangeType::DeleteChar  arg:0 toSel:0]; break;
        case 'E': [self deleteToEndOfLine];   [self recordChange:ChangeType::DeleteToEOL arg:0 toSel:0]; break;
        case 'B': [self deleteToStartOfLine]; [self recordChange:ChangeType::DeleteToSOL arg:0 toSel:0]; break;

        case 'd': _pendingOp = 'd'; break;
        case 'c': _pendingOp = 'c'; break;

        case 'f': _pendingOp = 'f'; break;
        case 'F': _pendingOp = 'F'; break;
        case ';': if (_findChar) [self findChar:_findChar forward:_findForward  inClient:sender]; break;
        case ',': if (_findChar) [self findChar:_findChar forward:!_findForward inClient:sender]; break;
        case 'r': _pendingOp = 'r'; break;

        case 'u': [self sendKey:kVK_ANSI_Z flags:kCGEventFlagMaskCommand];                        break;
        case 'U': [self sendKey:kVK_ANSI_Z flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift]; break;

        case 'p': [self pasteAfter];  [self recordChange:ChangeType::PasteAfter  arg:0 toSel:0]; break;
        case 'P': [self sendKey:kVK_ANSI_V flags:kCGEventFlagMaskCommand];
                  [self recordChange:ChangeType::PasteBefore arg:0 toSel:0]; break;

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
    if (_pendingTextObjType != 0) {
        unichar sel = _pendingTextObjType;
        _pendingTextObjType = 0;
        [self selectTextObject:c selector:sel inClient:sender];
        return YES;
    }

    switch (c) {
        case 'h': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskShift]; break;
        case 'j': [self sendKey:kVK_DownArrow  flags:kCGEventFlagMaskShift]; break;
        case 'k': [self sendKey:kVK_UpArrow    flags:kCGEventFlagMaskShift]; break;
        case 'l': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift]; break;
        case 'e': [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift | kCGEventFlagMaskAlternate]; break;
        case 'b': [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskShift | kCGEventFlagMaskAlternate]; break;
        case 'w': [self sendKey:kVK_DownArrow  flags:kCGEventFlagMaskShift | kCGEventFlagMaskCommand];   break;
        case 'W': [self sendKey:kVK_UpArrow    flags:kCGEventFlagMaskShift | kCGEventFlagMaskCommand];   break;
        case 'd': [self deleteVisualSelection]; break;
        case 'c': [self yankVisualSelection];   break;
        case 'i': _pendingTextObjType = 'i'; break;
        case 'a': _pendingTextObjType = 'a'; break;
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
    // Search: pass through, return to Normal on confirm/cancel.
    if (_mode == VimMode::Search) {
        if (aSelector == @selector(insertNewline:) ||
            aSelector == @selector(insertNewlineIgnoringFieldEditor:) ||
            aSelector == @selector(cancelOperation:))
            [self enterNormal];
        return NO;
    }

    // INSERT: track special keys for . recording.
    if (_mode == VimMode::Insert) {
        if (!_replayingInsert && _insertBuffer) {
            if (aSelector == @selector(insertNewline:) ||
                aSelector == @selector(insertNewlineIgnoringFieldEditor:))
                [_insertBuffer appendString:@"\n"];
            else if (aSelector == @selector(insertTab:))
                [_insertBuffer appendString:@"\t"];
            else if (aSelector == @selector(deleteBackward:) && _insertBuffer.length > 0)
                [_insertBuffer deleteCharactersInRange:NSMakeRange(_insertBuffer.length - 1, 1)];
        }
        if (aSelector == @selector(cancelOperation:)) {
            [self enterNormal]; // Escape exits INSERT
            return YES;
        }
        return NO;
    }

    if (aSelector == @selector(cancelOperation:)) {
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
    // Save INSERT session for . repeat (but not during replay or empty sessions).
    if (_mode == VimMode::Insert && !_replayingInsert) {
        if (_insertBuffer.length > 0) {
            _lastInsertText  = [_insertBuffer copy];
            _lastInsertEntry = _insertEntryKey;
            _lastChangeType  = ChangeType::InsertSession;
            _lastChangeArg   = 0;
        }
        _insertBuffer = nil;
    }
    // Replay complete: reset flag so next real INSERT is recorded normally.
    if (_replayingInsert) _replayingInsert = NO;

    _mode              = VimMode::Normal;
    _pendingOp         = 0;
    _pendingTextObjType = 0;
    os_log_info(OS_LOG_DEFAULT, "VimKeys: NORMAL");
}

- (void)enterInsert {
    _mode = VimMode::Insert;
    if (!_replayingInsert) _insertBuffer = [NSMutableString string];
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
// Repeat last change (Phase 6 + 8)
// ---------------------------------------------------------------------------

- (void)recordChange:(ChangeType)type arg:(unichar)arg toSel:(unichar)sel {
    _lastChangeType  = type;
    _lastChangeArg   = arg;
    _lastChangeTOSel = sel;
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

        // Phase 8: replay insert session
        case ChangeType::InsertSession:
            [self replayInsertSession];
            break;

        // Phase 8: replay text-object operation
        case ChangeType::DeleteTextObject:
            [self applyOp:'d' textObject:_lastChangeArg selector:_lastChangeTOSel inClient:sender];
            break;
        case ChangeType::YankTextObject:
            [self applyOp:'c' textObject:_lastChangeArg selector:_lastChangeTOSel inClient:sender];
            break;
    }
}

// ---------------------------------------------------------------------------
// Insert session replay (Phase 8)
// ---------------------------------------------------------------------------

// Synthesise the original entry key + recorded text + Escape.
// _replayingInsert prevents recording the replayed session.
- (void)replayInsertSession {
    if (!_lastInsertText) return;
    _replayingInsert = YES;

    // Synthesise the entry key — our normal-mode inputText: handler will
    // execute the correct cursor positioning and call enterInsert.
    [self synthesizeChar:_lastInsertEntry];

    // Synthesise each recorded character (handles \n, \t too).
    [self synthesizeText:_lastInsertText];

    // Synthesise Escape — didCommandBySelector:cancelOperation: calls enterNormal,
    // which detects _replayingInsert and resets it without saving a new session.
    [self sendKey:kVK_Escape flags:0];
}

// Synthesise a single unicode character as a keyboard event.
// Key code 0 is a placeholder; CGEventKeyboardSetUnicodeString overrides the
// produced character regardless of key code.
- (void)synthesizeChar:(unichar)ch {
    if (ch == '\n' || ch == '\r') { [self sendKey:kVK_Return flags:0]; return; }
    if (ch == '\t')               { [self sendKey:kVK_Tab    flags:0]; return; }
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, 0, false);
    CGEventKeyboardSetUnicodeString(down, 1, &ch);
    CGEventKeyboardSetUnicodeString(up,   1, &ch);
    CGEventPost(kCGSessionEventTap, down);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

- (void)synthesizeText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++)
        [self synthesizeChar:[text characterAtIndex:i]];
}

// ---------------------------------------------------------------------------
// Text object range finders (Phase 7)
// ---------------------------------------------------------------------------

- (NSRange)textObjectRange:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange cursor = [sender selectedRange];
    if (cursor.location == NSNotFound) return NSMakeRange(NSNotFound, 0);
    NSUInteger pos = cursor.location;
    id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;
    switch (delim) {
        case 'w':          return [self wordRange:pos selector:sel tc:tc];
        case '"':          return [self quotedRange:'"'  at:pos selector:sel tc:tc];
        case '\'':         return [self quotedRange:'\'' at:pos selector:sel tc:tc];
        case '(': case ')': return [self bracketRange:'(' close:')' at:pos selector:sel tc:tc];
        case '[': case ']': return [self bracketRange:'[' close:']' at:pos selector:sel tc:tc];
        case '{': case '}': return [self bracketRange:'{' close:'}' at:pos selector:sel tc:tc];
        default:           return NSMakeRange(NSNotFound, 0);
    }
}

- (NSRange)wordRange:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 512), bufStart = pos - before;
    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 512) actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);
    NSUInteger cur = before, ws = cur, we = cur;
    while (ws > 0 && ![self isWordBoundary:[buf characterAtIndex:ws - 1]]) ws--;
    while (we < buf.length && ![self isWordBoundary:[buf characterAtIndex:we]]) we++;
    if (we == ws) return NSMakeRange(NSNotFound, 0);
    if (sel == 'i') return NSMakeRange(bufStart + ws, we - ws);
    NSUInteger oe = we;
    while (oe < buf.length && [buf characterAtIndex:oe] == ' ') oe++;
    if (oe > we) return NSMakeRange(bufStart + ws, oe - ws);
    NSUInteger os2 = ws;
    while (os2 > 0 && [buf characterAtIndex:os2 - 1] == ' ') os2--;
    return NSMakeRange(bufStart + os2, we - os2);
}
- (BOOL)isWordBoundary:(unichar)ch { return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'; }

- (NSRange)quotedRange:(unichar)delim at:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 512), bufStart = pos - before;
    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 512) actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);
    NSUInteger cur = before, ls = cur, le = cur;
    while (ls > 0 && [buf characterAtIndex:ls - 1] != '\n') ls--;
    while (le < buf.length && [buf characterAtIndex:le] != '\n') le++;
    NSMutableArray<NSNumber *> *pos2 = [NSMutableArray array];
    for (NSUInteger i = ls; i < le; i++) if ([buf characterAtIndex:i] == delim) [pos2 addObject:@(i)];
    for (NSUInteger i = 0; i + 1 < pos2.count; i += 2) {
        NSUInteger l = pos2[i].unsignedIntegerValue, r = pos2[i+1].unsignedIntegerValue;
        if (l <= cur && cur <= r) {
            return (sel == 'i') ? NSMakeRange(bufStart + l + 1, r - l - 1) : NSMakeRange(bufStart + l, r - l + 1);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)bracketRange:(unichar)open close:(unichar)close at:(NSUInteger)pos selector:(unichar)sel tc:(id<NSTextInputClient>)tc {
    NSUInteger before = MIN(pos, 2048), bufStart = pos - before;
    NSAttributedString *as = [tc attributedSubstringForProposedRange:NSMakeRange(bufStart, before + 2048) actualRange:nil];
    NSString *buf = as.string;
    if (!buf) return NSMakeRange(NSNotFound, 0);
    NSUInteger cur = before;
    NSInteger depth = 0; NSUInteger openIdx = NSNotFound;
    for (NSInteger i = (NSInteger)cur; i >= 0; i--) {
        unichar ch = [buf characterAtIndex:(NSUInteger)i];
        if (ch == close) depth++;
        else if (ch == open) { if (depth == 0) { openIdx = (NSUInteger)i; break; } depth--; }
    }
    if (openIdx == NSNotFound) return NSMakeRange(NSNotFound, 0);
    depth = 0; NSUInteger closeIdx = NSNotFound;
    for (NSUInteger i = openIdx + 1; i < buf.length; i++) {
        unichar ch = [buf characterAtIndex:i];
        if (ch == open) depth++;
        else if (ch == close) { if (depth == 0) { closeIdx = i; break; } depth--; }
    }
    if (closeIdx == NSNotFound) return NSMakeRange(NSNotFound, 0);
    return (sel == 'i') ? NSMakeRange(bufStart + openIdx + 1, closeIdx - openIdx - 1)
                        : NSMakeRange(bufStart + openIdx,     closeIdx - openIdx + 1);
}

// ---------------------------------------------------------------------------
// Text object application (Phase 7 + 8)
// ---------------------------------------------------------------------------

- (void)applyOp:(unichar)op textObject:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange range = [self textObjectRange:delim selector:sel inClient:sender];
    if (range.location == NSNotFound) return;
    if (op == 'd') {
        [sender insertText:@"" replacementRange:range];
        [self recordChange:ChangeType::DeleteTextObject arg:delim toSel:sel];
    } else if (op == 'c') {
        id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;
        NSAttributedString *as = [tc attributedSubstringForProposedRange:range actualRange:nil];
        if (as.string) { NSPasteboard *pb = NSPasteboard.generalPasteboard; [pb clearContents]; [pb setString:as.string forType:NSPasteboardTypeString]; }
        [sender insertText:@"" replacementRange:NSMakeRange(range.location, 0)];
        [self recordChange:ChangeType::YankTextObject arg:delim toSel:sel];
    }
}

- (void)selectTextObject:(unichar)delim selector:(unichar)sel inClient:(id<IMKTextInput>)sender {
    NSRange range = [self textObjectRange:delim selector:sel inClient:sender];
    if (range.location == NSNotFound) return;
    [sender insertText:@"" replacementRange:NSMakeRange(range.location, 0)];
    NSUInteger steps = MIN(range.length, 500);
    for (NSUInteger i = 0; i < steps; i++) [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskShift];
}

// ---------------------------------------------------------------------------
// Find on line
// ---------------------------------------------------------------------------

- (void)findChar:(unichar)target forward:(BOOL)forward inClient:(id<IMKTextInput>)sender {
    NSRange sel = [sender selectedRange];
    if (sel.location == NSNotFound) return;
    id<NSTextInputClient> tc = (id<NSTextInputClient>)sender;
    NSString *line; NSUInteger found = NSNotFound;
    if (forward) {
        line = [[tc attributedSubstringForProposedRange:NSMakeRange(sel.location + 1, 512) actualRange:nil] string];
        if (!line) return;
        for (NSUInteger i = 0; i < line.length; i++) {
            unichar ch = [line characterAtIndex:i];
            if (ch == '\n' || ch == '\r') break;
            if (ch == target) { found = sel.location + 1 + i; break; }
        }
    } else {
        NSUInteger len = MIN(sel.location, 512), start = sel.location - len;
        line = [[tc attributedSubstringForProposedRange:NSMakeRange(start, len) actualRange:nil] string];
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

- (void)deleteVisualSelection { [self sendKey:kVK_Delete flags:0]; [self enterNormal]; }
- (void)yankVisualSelection   { [self sendKey:kVK_ANSI_C flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_LeftArrow flags:0]; [self enterNormal]; }

// ---------------------------------------------------------------------------
// Operator + motion helpers
// ---------------------------------------------------------------------------

- (void)deleteWithMotion:(Motion)motion { [self sendKey:motion.keyCode flags:motion.selectFlags()]; [self sendKey:kVK_Delete flags:0]; }
- (void)yankWithMotion:(Motion)motion   { [self sendKey:motion.keyCode flags:motion.selectFlags()]; [self sendKey:kVK_ANSI_C flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_LeftArrow flags:0]; }
- (void)deleteCurrentLine        { [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift]; [self sendKey:kVK_Delete flags:0]; }
- (void)deleteCurrentAndNextLine { [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift]; [self sendKey:kVK_DownArrow flags:kCGEventFlagMaskShift]; [self sendKey:kVK_Delete flags:0]; }
- (void)yankCurrentLine          { [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift]; [self sendKey:kVK_ANSI_C flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_LeftArrow flags:0]; }

// ---------------------------------------------------------------------------
// Line / insert helpers
// ---------------------------------------------------------------------------

- (void)newLineBelow { _insertEntryKey = 'o'; [self sendKey:kVK_RightArrow flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_Return flags:0]; [self enterInsert]; }
- (void)newLineAbove { _insertEntryKey = 'O'; [self sendKey:kVK_LeftArrow  flags:kCGEventFlagMaskCommand]; [self sendKey:kVK_Return flags:0]; [self sendKey:kVK_UpArrow flags:0]; [self enterInsert]; }
- (void)deleteToEndOfLine   { [self sendKey:kVK_RightArrow    flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift]; [self sendKey:kVK_ForwardDelete flags:0]; }
- (void)deleteToStartOfLine { [self sendKey:kVK_LeftArrow flags:kCGEventFlagMaskCommand | kCGEventFlagMaskShift];    [self sendKey:kVK_Delete        flags:0]; }
- (void)pasteAfter          { [self sendKey:kVK_RightArrow flags:0]; [self sendKey:kVK_ANSI_V flags:kCGEventFlagMaskCommand]; }

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
