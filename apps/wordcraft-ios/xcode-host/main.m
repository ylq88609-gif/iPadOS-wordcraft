#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

extern void wordcraft_ios_main(void);
extern void wordcraft_ios_register_file_picker(void (*picker)(const char *));
extern void wordcraft_ios_register_file_exporter(void (*exporter)(const char *));
extern void wordcraft_ios_register_ime_sync(void (*sync_fn)(bool, float, float, float, float));
extern void wordcraft_ios_ime_preedit(const char *text_ptr, int32_t cursor_start, int32_t cursor_end);
extern void wordcraft_ios_ime_commit(const char *text_ptr);
extern void wordcraft_ios_ime_key(int32_t key_code);
extern void wordcraft_ios_ime_shortcut(int32_t hid_code, int32_t mod_flags);
extern void wordcraft_ios_paste_text(const char *text_ptr);
extern void wordcraft_ios_register_clipboard(char *(*get_fn)(void), void (*free_fn)(char *), void (*set_fn)(const char *));
extern void wordcraft_ios_scroll(float x, float y, float dx, float dy);
extern void wordcraft_ios_deliver_file(const char *name_ptr, const uint8_t *data_ptr, size_t data_len);
extern void wordcraft_ios_cancel_dialog(void);
extern void wordcraft_ios_report_picker_error(const char *msg_ptr);

static const unsigned long long kMaxFontFileBytes = 50ULL * 1024ULL * 1024ULL;
static const unsigned long long kMaxDocFileBytes  = 128ULL * 1024ULL * 1024ULL;

// ============================================================================
// iPadOS UITextInput Bridge (Magic Keyboard + On-Screen CJK/International IME)
// ============================================================================

@interface WordCraftTextPosition : UITextPosition
@property (nonatomic, assign) NSUInteger index;
+ (instancetype)positionWithIndex:(NSUInteger)index;
@end

@implementation WordCraftTextPosition
+ (instancetype)positionWithIndex:(NSUInteger)index {
    WordCraftTextPosition *pos = [[WordCraftTextPosition alloc] init];
    pos.index = index;
    return pos;
}
@end

@interface WordCraftTextRange : UITextRange
@property (nonatomic, assign) NSUInteger startIndex;
@property (nonatomic, assign) NSUInteger endIndex;
+ (instancetype)rangeWithStart:(NSUInteger)start end:(NSUInteger)end;
@end

@implementation WordCraftTextRange
+ (instancetype)rangeWithStart:(NSUInteger)start end:(NSUInteger)end {
    WordCraftTextRange *r = [[WordCraftTextRange alloc] init];
    r.startIndex = start;
    r.endIndex = end;
    return r;
}
- (UITextPosition *)start {
    return [WordCraftTextPosition positionWithIndex:_startIndex];
}
- (UITextPosition *)end {
    return [WordCraftTextPosition positionWithIndex:_endIndex];
}
- (BOOL)isEmpty {
    return _startIndex >= _endIndex;
}
@end

@interface WordCraftImeView : UIView <UITextInput, UITextInputTraits>
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, assign) NSRange markedRange;
@property (nonatomic, assign) NSRange selectedRange;
@property (nonatomic, assign) CGRect cursorRect;
@property (nonatomic, weak) id<UITextInputDelegate> inputDelegate;
@property (nonatomic, strong) id<UITextInputTokenizer> tokenizer;
@property (nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *markedTextStyle;
@end

@implementation WordCraftImeView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _buffer = [NSMutableString string];
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(0, 0);
        _cursorRect = CGRectMake(120, 220, 2, 20);
        _tokenizer = [[UITextInputStringTokenizer alloc] initWithTextInput:self];
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.alpha = 0.01;
    }
    return self;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// UITextInputTraits
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDefault; }

// UIKeyInput
- (BOOL)hasText {
    return YES;
}

- (void)trimBufferIfNeeded {
    if (_markedRange.location == NSNotFound && _buffer.length > 256) {
        NSUInteger excess = _buffer.length - 128;
        [_buffer deleteCharactersInRange:NSMakeRange(0, excess)];
        _selectedRange.location = (_selectedRange.location > excess) ? (_selectedRange.location - excess) : 0;
        _selectedRange.length = 0;
    }
}

- (void)insertText:(NSString *)text {
    if (text == nil || text.length == 0) {
        return;
    }
    [self.inputDelegate textWillChange:self];
    if (_markedRange.location != NSNotFound) {
        NSRange valid = NSIntersectionRange(_markedRange, NSMakeRange(0, _buffer.length));
        if (valid.length > 0) {
            [_buffer deleteCharactersInRange:valid];
        }
        _selectedRange = NSMakeRange(valid.location, 0);
        _markedRange = NSMakeRange(NSNotFound, 0);
    }

    if ([text isEqualToString:@"\n"] || [text isEqualToString:@"\r"]) {
        [_buffer setString:@""];
        _selectedRange = NSMakeRange(0, 0);
        [self.inputDelegate textDidChange:self];
        wordcraft_ios_ime_key(2); // Enter
        return;
    }

    if ([text isEqualToString:@"\t"]) {
        [self.inputDelegate textDidChange:self];
        wordcraft_ios_ime_key(3); // Tab
        return;
    }

    NSUInteger pos = MIN(_selectedRange.location, _buffer.length);
    [_buffer insertString:text atIndex:pos];
    _selectedRange = NSMakeRange(pos + text.length, 0);
    [self trimBufferIfNeeded];
    [self.inputDelegate textDidChange:self];

    wordcraft_ios_ime_commit([text UTF8String]);
}

- (void)deleteBackward {
    [self.inputDelegate textWillChange:self];
    if (_markedRange.location != NSNotFound && _markedRange.length > 0) {
        NSRange valid = NSIntersectionRange(_markedRange, NSMakeRange(0, _buffer.length));
        if (valid.length > 0) {
            NSRange lastChar = [_buffer rangeOfComposedCharacterSequenceAtIndex:NSMaxRange(valid) - 1];
            [_buffer deleteCharactersInRange:lastChar];
            NSUInteger newLen = valid.length - lastChar.length;
            if (newLen > 0) {
                _markedRange = NSMakeRange(valid.location, newLen);
                _selectedRange = NSMakeRange(valid.location + newLen, 0);
                NSString *marked = [_buffer substringWithRange:_markedRange];
                [self.inputDelegate textDidChange:self];
                wordcraft_ios_ime_preedit([marked UTF8String], (int32_t)marked.length, (int32_t)marked.length);
                return;
            }
        }
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(MIN(_selectedRange.location, _buffer.length), 0);
        [self.inputDelegate textDidChange:self];
        wordcraft_ios_ime_preedit("", 0, 0);
        return;
    }

    if (_selectedRange.location > 0 && _buffer.length > 0) {
        NSUInteger idx = MIN(_selectedRange.location, _buffer.length) - 1;
        NSRange lastChar = [_buffer rangeOfComposedCharacterSequenceAtIndex:idx];
        [_buffer deleteCharactersInRange:lastChar];
        _selectedRange = NSMakeRange(lastChar.location, 0);
    }
    [self.inputDelegate textDidChange:self];
    wordcraft_ios_ime_key(1); // Backspace
}

// UITextInput Marked Text (CJK IME Composition)
- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {
    [self.inputDelegate textWillChange:self];
    NSString *safeText = markedText ?: @"";
    NSUInteger replaceStart = 0;
    if (_markedRange.location != NSNotFound) {
        NSRange valid = NSIntersectionRange(_markedRange, NSMakeRange(0, _buffer.length));
        replaceStart = valid.location;
        if (valid.length > 0) {
            [_buffer deleteCharactersInRange:valid];
        }
    } else {
        NSRange validSel = NSIntersectionRange(_selectedRange, NSMakeRange(0, _buffer.length));
        replaceStart = validSel.location;
        if (validSel.length > 0) {
            [_buffer deleteCharactersInRange:validSel];
        }
    }

    if (safeText.length > 0) {
        [_buffer insertString:safeText atIndex:replaceStart];
        _markedRange = NSMakeRange(replaceStart, safeText.length);
        NSUInteger selStart = MIN(selectedRange.location, safeText.length);
        NSUInteger selEnd = MIN(selStart + selectedRange.length, safeText.length);
        _selectedRange = NSMakeRange(replaceStart + selStart, selEnd - selStart);
        [self.inputDelegate textDidChange:self];

        NSString *prefixStart = [safeText substringToIndex:selStart];
        NSString *prefixEnd = [safeText substringToIndex:selEnd];
        int32_t cStart = (int32_t)([prefixStart lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4);
        int32_t cEnd   = (int32_t)([prefixEnd lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / 4);
        wordcraft_ios_ime_preedit([safeText UTF8String], cStart, cEnd);
    } else {
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(replaceStart, 0);
        [self.inputDelegate textDidChange:self];
        wordcraft_ios_ime_preedit("", 0, 0);
    }
}

- (void)unmarkText {
    if (_markedRange.location != NSNotFound && _markedRange.length > 0) {
        NSRange valid = NSIntersectionRange(_markedRange, NSMakeRange(0, _buffer.length));
        NSString *marked = valid.length > 0 ? [_buffer substringWithRange:valid] : @"";
        _markedRange = NSMakeRange(NSNotFound, 0);
        _selectedRange = NSMakeRange(NSMaxRange(valid), 0);
        if (marked.length > 0) {
            wordcraft_ios_ime_commit([marked UTF8String]);
        } else {
            wordcraft_ios_ime_preedit("", 0, 0);
        }
    } else {
        _markedRange = NSMakeRange(NSNotFound, 0);
    }
}

- (UITextRange *)markedTextRange {
    if (_markedRange.location == NSNotFound || _markedRange.length == 0) {
        return nil;
    }
    return [WordCraftTextRange rangeWithStart:_markedRange.location end:NSMaxRange(_markedRange)];
}

- (UITextRange *)selectedTextRange {
    NSUInteger start = MIN(_selectedRange.location, _buffer.length);
    NSUInteger end = MIN(start + _selectedRange.length, _buffer.length);
    return [WordCraftTextRange rangeWithStart:start end:end];
}

- (void)setSelectedTextRange:(UITextRange *)selectedTextRange {
    if ([selectedTextRange isKindOfClass:[WordCraftTextRange class]]) {
        WordCraftTextRange *r = (WordCraftTextRange *)selectedTextRange;
        NSUInteger s = MIN(r.startIndex, _buffer.length);
        NSUInteger e = MIN(MAX(r.endIndex, s), _buffer.length);
        _selectedRange = NSMakeRange(s, e - s);
    }
}

- (NSString *)textInRange:(UITextRange *)range {
    if (![range isKindOfClass:[WordCraftTextRange class]]) return nil;
    WordCraftTextRange *r = (WordCraftTextRange *)range;
    NSUInteger s = MIN(r.startIndex, _buffer.length);
    NSUInteger e = MIN(MAX(r.endIndex, s), _buffer.length);
    return [_buffer substringWithRange:NSMakeRange(s, e - s)];
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (![range isKindOfClass:[WordCraftTextRange class]]) return;
    WordCraftTextRange *r = (WordCraftTextRange *)range;
    NSUInteger s = MIN(r.startIndex, _buffer.length);
    NSUInteger e = MIN(MAX(r.endIndex, s), _buffer.length);
    NSString *safe = text ?: @"";
    [self.inputDelegate textWillChange:self];
    [_buffer replaceCharactersInRange:NSMakeRange(s, e - s) withString:safe];
    _selectedRange = NSMakeRange(s + safe.length, 0);
    [self.inputDelegate textDidChange:self];
    if (safe.length > 0) {
        wordcraft_ios_ime_commit([safe UTF8String]);
    }
}

- (UITextPosition *)beginningOfDocument {
    return [WordCraftTextPosition positionWithIndex:0];
}

- (UITextPosition *)endOfDocument {
    return [WordCraftTextPosition positionWithIndex:_buffer.length];
}

- (UITextRange *)textRangeFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    NSUInteger s = [(WordCraftTextPosition *)fromPosition index];
    NSUInteger e = [(WordCraftTextPosition *)toPosition index];
    if (s > e) { NSUInteger tmp = s; s = e; e = tmp; }
    return [WordCraftTextRange rangeWithStart:MIN(s, _buffer.length) end:MIN(e, _buffer.length)];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    NSInteger idx = (NSInteger)[(WordCraftTextPosition *)position index] + offset;
    if (idx < 0 || idx > (NSInteger)_buffer.length) return nil;
    return [WordCraftTextPosition positionWithIndex:(NSUInteger)idx];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset {
    NSInteger delta = (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) ? -offset : offset;
    return [self positionFromPosition:position offset:delta];
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSUInteger a = [(WordCraftTextPosition *)position index];
    NSUInteger b = [(WordCraftTextPosition *)other index];
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)from toPosition:(UITextPosition *)toPosition {
    return (NSInteger)[(WordCraftTextPosition *)toPosition index] - (NSInteger)[(WordCraftTextPosition *)from index];
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    WordCraftTextRange *r = (WordCraftTextRange *)range;
    BOOL atStart = (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp);
    return [WordCraftTextPosition positionWithIndex:(atStart ? r.startIndex : r.endIndex)];
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction {
    NSUInteger idx = [(WordCraftTextPosition *)position index];
    if (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) {
        return [WordCraftTextRange rangeWithStart:0 end:MIN(idx, _buffer.length)];
    }
    return [WordCraftTextRange rangeWithStart:MIN(idx, _buffer.length) end:_buffer.length];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position inDirection:(UITextStorageDirection)direction {
    return NSWritingDirectionLeftToRight;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(UITextRange *)range {}

- (CGRect)firstRectForRange:(UITextRange *)range {
    return CGRectMake(0, 0, _cursorRect.size.width > 1 ? _cursorRect.size.width : 2, _cursorRect.size.height > 1 ? _cursorRect.size.height : 20);
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    return CGRectMake(0, 0, 2, _cursorRect.size.height > 1 ? _cursorRect.size.height : 20);
}

- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    return @[];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    return [self endOfDocument];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    return [self endOfDocument];
}

- (UITextRange *)characterRangeAtPoint:(CGPoint)point {
    return [self selectedTextRange];
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (@available(iOS 13.0, *)) {
        NSMutableArray<UIKeyCommand *> *cmds = [NSMutableArray array];
        NSArray *specs = @[
            @[@"z", @(UIKeyModifierCommand), @"撤销"],
            @[@"z", @(UIKeyModifierCommand | UIKeyModifierShift), @"重做"],
            @[@"c", @(UIKeyModifierCommand), @"复制"],
            @[@"x", @(UIKeyModifierCommand), @"剪切"],
            @[@"v", @(UIKeyModifierCommand), @"粘贴"],
            @[@"a", @(UIKeyModifierCommand), @"全选"],
            @[@"b", @(UIKeyModifierCommand), @"加粗"],
            @[@"i", @(UIKeyModifierCommand), @"斜体"],
            @[@"u", @(UIKeyModifierCommand), @"下划线"],
            @[@"s", @(UIKeyModifierCommand), @"保存"],
            @[@"s", @(UIKeyModifierCommand | UIKeyModifierShift), @"另存为"],
            @[@"o", @(UIKeyModifierCommand), @"打开"],
            @[@"n", @(UIKeyModifierCommand), @"新建"],
            @[@"p", @(UIKeyModifierCommand), @"打印"],
            @[@"f", @(UIKeyModifierCommand), @"查找"],
            @[@"h", @(UIKeyModifierCommand), @"替换"],
            @[@"l", @(UIKeyModifierCommand), @"左对齐"],
            @[@"e", @(UIKeyModifierCommand), @"居中对齐"],
            @[@"r", @(UIKeyModifierCommand), @"右对齐"],
        ];
        for (NSArray *spec in specs) {
            UIKeyCommand *cmd = [UIKeyCommand commandWithTitle:spec[2]
                                                         image:nil
                                                        action:@selector(handleKeyCommand:)
                                                         input:spec[0]
                                                 modifierFlags:[spec[1] integerValue]
                                                  propertyList:nil];
            cmd.wantsPriorityOverSystemBehavior = YES;
            [cmds addObject:cmd];
        }
        return cmds;
    }
    return [super keyCommands];
}

- (void)handleKeyCommand:(UIKeyCommand *)cmd {
    NSString *input = [cmd.input lowercaseString];
    if (input.length == 0) return;
    int32_t modFlags = 0;
    if (cmd.modifierFlags & UIKeyModifierShift)     modFlags |= 1;
    if (cmd.modifierFlags & UIKeyModifierControl)   modFlags |= 2;
    if (cmd.modifierFlags & UIKeyModifierAlternate) modFlags |= 4;
    if (cmd.modifierFlags & UIKeyModifierCommand)   modFlags |= 8;

    if ([input isEqualToString:@"v"] && (modFlags & 8)) {
        NSString *clip = [UIPasteboard generalPasteboard].string;
        if (clip != nil && clip.length > 0) {
            wordcraft_ios_paste_text([clip UTF8String]);
        }
        return;
    }
    unichar ch = [input characterAtIndex:0];
    if (ch >= 'a' && ch <= 'z') {
        int32_t hid = 4 + (int32_t)(ch - 'a');
        wordcraft_ios_ime_shortcut(hid, modFlags);
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (@available(iOS 13.4, *)) {
        for (UIPress *press in presses) {
            UIKey *key = press.key;
            if (key == nil) continue;
            UIKeyModifierFlags flags = key.modifierFlags;
            int32_t modFlags = 0;
            if (flags & UIKeyModifierShift)     modFlags |= 1;
            if (flags & UIKeyModifierControl)   modFlags |= 2;
            if (flags & UIKeyModifierAlternate) modFlags |= 4;
            if (flags & UIKeyModifierCommand)   modFlags |= 8;

            // Keep Ctrl+Space free for iPadOS system IME switching
            if (key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar && (modFlags & 2)) {
                [super pressesBegan:presses withEvent:event];
                return;
            }

            // Navigation & editing keys (with or without Shift/Alt/Cmd)
            CFIndex kc = key.keyCode;
            if (kc == UIKeyboardHIDUsageKeyboardLeftArrow ||
                kc == UIKeyboardHIDUsageKeyboardRightArrow ||
                kc == UIKeyboardHIDUsageKeyboardUpArrow ||
                kc == UIKeyboardHIDUsageKeyboardDownArrow ||
                kc == UIKeyboardHIDUsageKeyboardHome ||
                kc == UIKeyboardHIDUsageKeyboardEnd ||
                kc == UIKeyboardHIDUsageKeyboardPageUp ||
                kc == UIKeyboardHIDUsageKeyboardPageDown ||
                kc == UIKeyboardHIDUsageKeyboardDeleteForward ||
                kc == UIKeyboardHIDUsageKeyboardEscape) {
                wordcraft_ios_ime_shortcut((int32_t)kc, modFlags);
                return;
            }

            // Any Command / Control / Alt shortcut
            if (modFlags & (2 | 4 | 8)) {
                if (kc == UIKeyboardHIDUsageKeyboardV && (modFlags & 8)) {
                    NSString *clip = [UIPasteboard generalPasteboard].string;
                    if (clip != nil && clip.length > 0) {
                        wordcraft_ios_paste_text([clip UTF8String]);
                    }
                    return;
                }
                wordcraft_ios_ime_shortcut((int32_t)kc, modFlags);
                return;
            }
        }
    }
    [super pressesBegan:presses withEvent:event];
}

@end

@interface WordCraftScrollHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) double vx;
@property (nonatomic, assign) double vy;
@property (nonatomic, assign) CGPoint lastLoc;
@end

@implementation WordCraftScrollHandler
- (void)stopInertia {
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    self.vx = 0;
    self.vy = 0;
}
- (void)onDisplayLink:(CADisplayLink *)link {
    double dt = link.targetTimestamp - link.timestamp;
    if (dt <= 0.0 || dt > 0.05) dt = 1.0 / 60.0;
    double dx = self.vx * dt;
    double dy = self.vy * dt;
    if (fabs(dx) > 0.05 || fabs(dy) > 0.05) {
        wordcraft_ios_scroll((float)self.lastLoc.x, (float)self.lastLoc.y, (float)dx, (float)dy);
    }
    double decay = pow(0.94, dt * 60.0);
    self.vx *= decay;
    self.vy *= decay;
    if (hypot(self.vx, self.vy) < 15.0) {
        [self stopInertia];
    }
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        [self stopInertia];
        self.lastLoc = [pan locationInView:pan.view];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint delta = [pan translationInView:pan.view];
        [pan setTranslation:CGPointZero inView:pan.view];
        self.lastLoc = [pan locationInView:pan.view];
        if (fabs(delta.x) > 0.05 || fabs(delta.y) > 0.05) {
            wordcraft_ios_scroll((float)self.lastLoc.x, (float)self.lastLoc.y, (float)delta.x, (float)delta.y);
        }
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        CGPoint vel = [pan velocityInView:pan.view];
        self.lastLoc = [pan locationInView:pan.view];
        if (hypot(vel.x, vel.y) > 40.0) {
            [self stopInertia];
            self.vx = vel.x;
            self.vy = vel.y;
            self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
            [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        }
    } else if (pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        [self stopInertia];
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}
@end

static WordCraftScrollHandler *gScrollHandler = nil;
static BOOL gInstalledScroll = NO;

static void wordcraft_install_scroll_recognizer(UIView *hostView) {
    if (gInstalledScroll || hostView == nil) return;
    gScrollHandler = [[WordCraftScrollHandler alloc] init];

    // 1. Touchscreen: 2-finger swipe scrolls, leaving 1-finger drag free for shape resizing & text selection
    UIPanGestureRecognizer *panTouch = [[UIPanGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePan:)];
    panTouch.minimumNumberOfTouches = 2;
    panTouch.maximumNumberOfTouches = 2;
    panTouch.allowedTouchTypes = @[@(UITouchTypeDirect)];
    panTouch.cancelsTouchesInView = NO;
    panTouch.delaysTouchesBegan = NO;
    panTouch.delaysTouchesEnded = NO;
    panTouch.delegate = gScrollHandler;
    [hostView addGestureRecognizer:panTouch];

    // 2. Magic Keyboard Trackpad: 2-finger indirect scroll
    if (@available(iOS 13.4, *)) {
        UIPanGestureRecognizer *panTrackpad = [[UIPanGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePan:)];
        panTrackpad.allowedTouchTypes = @[];
        panTrackpad.allowedScrollTypesMask = UIScrollTypeMaskAll;
        panTrackpad.cancelsTouchesInView = NO;
        panTrackpad.delaysTouchesBegan = NO;
        panTrackpad.delaysTouchesEnded = NO;
        panTrackpad.delegate = gScrollHandler;
        [hostView addGestureRecognizer:panTrackpad];
    }

    gInstalledScroll = YES;
}

static WordCraftImeView *gImeView = nil;
static BOOL gImeActive = NO;
static BOOL gSwizzledWinit = NO;
static IMP gOrigWinitBecomeFirstResponder = NULL;

static BOOL gInBecome = NO;
static BOOL wordcraft_winit_become_first_responder(id self, SEL _cmd) {
    if (gInBecome || self == gImeView || ![self isKindOfClass:[UIView class]] || [self isKindOfClass:[UIWindow class]]) {
        return gOrigWinitBecomeFirstResponder ? ((BOOL (*)(id, SEL))gOrigWinitBecomeFirstResponder)(self, _cmd) : NO;
    }
    if (gImeActive && gImeView != nil) {
        gInBecome = YES;
        if (![gImeView isFirstResponder]) {
            [gImeView becomeFirstResponder];
        }
        gInBecome = NO;
        return NO;
    }
    return gOrigWinitBecomeFirstResponder ? ((BOOL (*)(id, SEL))gOrigWinitBecomeFirstResponder)(self, _cmd) : NO;
}

static void wordcraft_install_winit_responder_hook(UIView *hostView) {
    if (gSwizzledWinit || hostView == nil || [hostView isKindOfClass:[WordCraftImeView class]]) {
        return;
    }
    Class cls = [hostView class];
    Method m = class_getInstanceMethod(cls, @selector(becomeFirstResponder));
    if (m != NULL) {
        gOrigWinitBecomeFirstResponder = method_setImplementation(m, (IMP)wordcraft_winit_become_first_responder);
        gSwizzledWinit = YES;
    }
}

static UIViewController *wordcraft_top_view_controller(void) {
    UIWindow *foundWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive)) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    foundWindow = window;
                    break;
                }
            }
            if (foundWindow == nil && windowScene.windows.count > 0) {
                foundWindow = windowScene.windows.firstObject;
            }
            if (foundWindow != nil) {
                break;
            }
        }
    }
    UIViewController *root = foundWindow.rootViewController;
    while (root.presentedViewController != nil) {
        root = root.presentedViewController;
    }
    return root;
}

void wordcraft_ios_sync_ime(bool active, float x, float y, float w, float h) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gImeActive = active ? YES : NO;
        UIViewController *topVC = wordcraft_top_view_controller();
        if (topVC == nil || topVC.view == nil) {
            return;
        }
        wordcraft_install_winit_responder_hook(topVC.view);
        wordcraft_install_scroll_recognizer(topVC.view);

        if (gImeView == nil) {
            gImeView = [[WordCraftImeView alloc] initWithFrame:CGRectMake(x, y, 2, 20)];
            [topVC.view addSubview:gImeView];
        } else if (gImeView.superview != topVC.view) {
            [gImeView removeFromSuperview];
            [topVC.view addSubview:gImeView];
        }
        CGRect rect = CGRectMake(x, y, w > 1 ? w : 2, h > 1 ? h : 20);
        gImeView.frame = CGRectMake(rect.origin.x, rect.origin.y, 2, rect.size.height);
        gImeView.cursorRect = rect;

        if (active) {
            if (![gImeView isFirstResponder]) {
                [gImeView becomeFirstResponder];
            }
        } else {
            if ([gImeView isFirstResponder]) {
                [gImeView resignFirstResponder];
            }
        }
    });
}

// ============================================================================
// iPadOS UIDocumentPickerViewController Bridge (Open + Save/Export to Files)
// ============================================================================

@interface WordCraftDocumentPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *purpose;
@property (nonatomic, assign) BOOL isExport;
@end

static WordCraftDocumentPickerDelegate *gActivePickerDelegate = nil;

@implementation WordCraftDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.isExport) {
        gActivePickerDelegate = nil;
        return;
    }

    NSString *purpose = [self.purpose copy];
    BOOL isFont = [purpose isEqualToString:@"font"];
    unsigned long long maxBytes = isFont ? kMaxFontFileBytes : kMaxDocFileBytes;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSURL *url in urls) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            NSError *coordError = nil;

            [coordinator coordinateReadingItemAtURL:url
                                            options:NSFileCoordinatorReadingWithoutChanges
                                              error:&coordError
                                         byAccessor:^(NSURL * _Nonnull newURL) {
                NSString *filename = [newURL lastPathComponent];
                if (filename == nil || filename.length == 0) {
                    filename = isFont ? @"imported-font.ttf" : @"document.docx";
                }

                NSError *attrError = nil;
                NSDictionary<NSFileAttributeKey, id> *attrs =
                    [[NSFileManager defaultManager] attributesOfItemAtPath:newURL.path error:&attrError];
                if (attrs != nil) {
                    unsigned long long fileSize = [attrs fileSize];
                    if (fileSize > maxBytes) {
                        NSString *msg = [NSString stringWithFormat:@"文件 \"%@\" 大小 (%.1f MB) 超过 %llu MB 安全上限，已拒绝导入。",
                                         filename,
                                         (double)fileSize / (1024.0 * 1024.0),
                                         maxBytes / (1024ULL * 1024ULL)];
                        wordcraft_ios_report_picker_error([msg UTF8String]);
                        return;
                    }
                }

                NSError *readError = nil;
                NSData *data = [NSData dataWithContentsOfURL:newURL
                                                     options:NSDataReadingMappedIfSafe
                                                       error:&readError];
                if (data == nil) {
                    NSString *reason = readError.localizedDescription ?: @"无法读取文件内容";
                    NSString *msg = [NSString stringWithFormat:@"读取文件 \"%@\" 失败：%@", filename, reason];
                    wordcraft_ios_report_picker_error([msg UTF8String]);
                    return;
                }

                if ((unsigned long long)data.length > maxBytes) {
                    NSString *msg = [NSString stringWithFormat:@"文件 \"%@\" 超过 %llu MB 大小限制。",
                                     filename,
                                     maxBytes / (1024ULL * 1024ULL)];
                    wordcraft_ios_report_picker_error([msg UTF8String]);
                    return;
                }

                wordcraft_ios_deliver_file([filename UTF8String], (const uint8_t *)data.bytes, (size_t)data.length);
            }];

            if (coordError != nil) {
                NSString *msg = [NSString stringWithFormat:@"访问文件失败：%@",
                                 coordError.localizedDescription ?: @"权限或 iCloud 同步错误"];
                wordcraft_ios_report_picker_error([msg UTF8String]);
            }

            if (scoped) {
                [url stopAccessingSecurityScopedResource];
            }
        }
    });

    gActivePickerDelegate = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (!self.isExport) {
        wordcraft_ios_cancel_dialog();
    }
    gActivePickerDelegate = nil;
}

@end

static NSArray<UTType *> *wordcraft_content_types_for_purpose(NSString *purpose) {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if ([purpose isEqualToString:@"font"]) {
        if (UTTypeFont != nil) {
            [types addObject:UTTypeFont];
        }
        NSArray<NSString *> *exts = @[@"ttf", @"otf", @"ttc", @"otc", @"woff", @"woff2"];
        for (NSString *ext in exts) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            if (t != nil && ![types containsObject:t]) {
                [types addObject:t];
            }
        }
        if (types.count == 0 && UTTypeData != nil) {
            [types addObject:UTTypeData];
        }
    } else if ([purpose isEqualToString:@"picture"]) {
        if (UTTypeImage != nil) {
            [types addObject:UTTypeImage];
        } else if (UTTypeData != nil) {
            [types addObject:UTTypeData];
        }
    } else {
        NSArray<NSString *> *exts = @[@"docx", @"doc", @"dotx", @"rtf", @"odt", @"txt", @"md", @"html"];
        for (NSString *ext in exts) {
            UTType *t = [UTType typeWithFilenameExtension:ext];
            if (t != nil && ![types containsObject:t]) {
                [types addObject:t];
            }
        }
        if (UTTypeData != nil && ![types containsObject:UTTypeData]) {
            [types addObject:UTTypeData];
        }
    }
    return types;
}

void wordcraft_ios_open_file_picker(const char *purpose_cstr) {
    NSString *purpose = purpose_cstr != NULL ? [NSString stringWithUTF8String:purpose_cstr] : @"font";
    if (purpose == nil) {
        purpose = @"font";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = wordcraft_top_view_controller();
        if (topVC == nil) {
            wordcraft_ios_report_picker_error("无法打开 iOS 文件选择器：未找到当前活动窗口视图控制器。");
            return;
        }
        NSArray<UTType *> *contentTypes = wordcraft_content_types_for_purpose(purpose);
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes asCopy:YES];
        picker.allowsMultipleSelection = [purpose isEqualToString:@"font"];
        picker.shouldShowFileExtensions = YES;

        WordCraftDocumentPickerDelegate *delegate = [[WordCraftDocumentPickerDelegate alloc] init];
        delegate.purpose = purpose;
        delegate.isExport = NO;
        gActivePickerDelegate = delegate;
        picker.delegate = delegate;

        [topVC presentViewController:picker animated:YES completion:nil];
    });
}

void wordcraft_ios_export_file(const char *path_cstr) {
    if (path_cstr == NULL) {
        return;
    }
    NSString *path = [NSString stringWithUTF8String:path_cstr];
    if (path == nil || path.length == 0) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topVC = wordcraft_top_view_controller();
        if (topVC == nil) {
            return;
        }
        NSURL *fileURL = [NSURL fileURLWithPath:path];
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForExportingURLs:@[fileURL] asCopy:YES];
        picker.shouldShowFileExtensions = YES;

        WordCraftDocumentPickerDelegate *delegate = [[WordCraftDocumentPickerDelegate alloc] init];
        delegate.purpose = @"export";
        delegate.isExport = YES;
        gActivePickerDelegate = delegate;
        picker.delegate = delegate;

        [topVC presentViewController:picker animated:YES completion:nil];
    });
}

static char *wordcraft_ios_clipboard_get(void) {
    NSString *str = [UIPasteboard generalPasteboard].string;
    if (str == nil) return NULL;
    return strdup([str UTF8String]);
}

static void wordcraft_ios_clipboard_free(char *ptr) {
    if (ptr != NULL) free(ptr);
}

static void wordcraft_ios_clipboard_set(const char *text_ptr) {
    if (text_ptr == NULL) return;
    NSString *str = [NSString stringWithUTF8String:text_ptr];
    if (str != nil) {
        [UIPasteboard generalPasteboard].string = str;
    }
}

int main(int argc, char * argv[]) {
    @autoreleasepool {
        setenv("WORDCRAFT_LANGUAGE", "zh-CN", 0);
        wordcraft_ios_register_file_picker(wordcraft_ios_open_file_picker);
        wordcraft_ios_register_file_exporter(wordcraft_ios_export_file);
        wordcraft_ios_register_ime_sync(wordcraft_ios_sync_ime);
        wordcraft_ios_register_clipboard(wordcraft_ios_clipboard_get, wordcraft_ios_clipboard_free, wordcraft_ios_clipboard_set);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = wordcraft_top_view_controller();
            if (vc && vc.view) { wordcraft_install_scroll_recognizer(vc.view); }
        });
        wordcraft_ios_main();
        return 0;
    }
}
