#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    float view_w;
    float view_h;
    float drawable_w;
    float drawable_h;
    float safe_top;
    float safe_bottom;
    float safe_left;
    float safe_right;
    float keyboard_overlap;
} WordCraftIosMetrics;

extern void wordcraft_ios_main(void);
extern void wordcraft_ios_register_file_picker(void (*picker)(const char *));
extern void wordcraft_ios_register_file_exporter(void (*exporter)(const char *));
extern void wordcraft_ios_register_ime_sync(void (*sync_fn)(bool, float, float, float, float));
extern void wordcraft_ios_register_metrics(bool (*metrics_fn)(WordCraftIosMetrics *out));
extern void wordcraft_ios_ime_preedit(const char *text_ptr, int32_t cursor_start, int32_t cursor_end);
extern void wordcraft_ios_ime_commit(const char *text_ptr);
extern void wordcraft_ios_ime_key(int32_t key_code);
extern void wordcraft_ios_ime_shortcut(int32_t hid_code, int32_t mod_flags);
extern void wordcraft_ios_paste_text(const char *text_ptr);
extern void wordcraft_ios_register_clipboard(char *(*get_fn)(void), void (*free_fn)(char *), void (*set_fn)(const char *));
extern void wordcraft_ios_register_url_opener(void (*opener)(const char *));
extern void wordcraft_ios_scroll(float x, float y, float dx, float dy);
extern void wordcraft_ios_pointer_hover(float x, float y);
extern void wordcraft_ios_secondary_click(float x, float y);
extern void wordcraft_ios_long_press(float x, float y);
extern void wordcraft_ios_pinch_zoom(float x, float y, float scale_delta);
extern bool wordcraft_ios_should_touch_scroll(float x, float y);
extern void wordcraft_ios_touch_scroll_begin(void);
extern void wordcraft_ios_request_repaint(void);
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

// ============================================================================
// Apple HIG iPadOS Gesture & Pointer Coordinator
// - Touchscreen: 1-finger canvas scroll (yielding to handles/tables/UI/double-tap-drag),
//   2-finger scroll, 2-finger pinch zoom, long-press context menu, 3-finger undo/redo.
// - Trackpad/Mouse (Indirect Pointer): Hover, left-drag selection, secondary-click context
//   menu (delaysTouchesBegan so selection stays intact), 2-finger scroll, pinch zoom.
// ============================================================================

@interface WordCraftScrollHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) double vx;
@property (nonatomic, assign) double vy;
@property (nonatomic, assign) CGPoint lastLoc;
@property (nonatomic, assign) CGFloat lastPinchScale;
@property (nonatomic, weak) UIPanGestureRecognizer *panTouch1;
@property (nonatomic, weak) UIPanGestureRecognizer *panTouch2;
@property (nonatomic, weak) UIPanGestureRecognizer *panTrackpad;
@property (nonatomic, weak) UIPinchGestureRecognizer *pinchRecognizer;
@property (nonatomic, weak) UILongPressGestureRecognizer *longPressRecognizer;
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
    double decay = pow(0.955, dt * 60.0);
    self.vx *= decay;
    self.vy *= decay;
    if (hypot(self.vx, self.vy) < 12.0) {
        [self stopInertia];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    BOOL isDirectTouchPan = (pan == self.panTouch1 || pan == self.panTouch2);
    if (pan.state == UIGestureRecognizerStateBegan) {
        [self stopInertia];
        if (isDirectTouchPan) {
            wordcraft_ios_touch_scroll_begin();
        }
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

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        [self stopInertia];
        wordcraft_ios_touch_scroll_begin();
        self.lastPinchScale = (pinch.scale > 0.01) ? pinch.scale : 1.0;
    } else if (pinch.state == UIGestureRecognizerStateChanged) {
        CGFloat scale = pinch.scale;
        if (scale > 0.01 && self.lastPinchScale > 0.01) {
            CGFloat delta = scale / self.lastPinchScale;
            self.lastPinchScale = scale;
            if (fabs(delta - 1.0) > 0.001) {
                CGPoint loc = [pinch locationInView:pinch.view];
                wordcraft_ios_pinch_zoom((float)loc.x, (float)loc.y, (float)delta);
            }
        }
    } else {
        self.lastPinchScale = 1.0;
    }
}

- (void)handleHover:(UIHoverGestureRecognizer *)hover API_AVAILABLE(ios(13.0)) {
    if (hover.state == UIGestureRecognizerStateBegan || hover.state == UIGestureRecognizerStateChanged) {
        CGPoint loc = [hover locationInView:hover.view];
        wordcraft_ios_pointer_hover((float)loc.x, (float)loc.y);
    }
}

- (void)handleSecondaryClick:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateEnded) {
        [self stopInertia];
        CGPoint loc = [tap locationInView:tap.view];
        wordcraft_ios_secondary_click((float)loc.x, (float)loc.y);
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state == UIGestureRecognizerStateBegan) {
        [self stopInertia];
        CGPoint loc = [lp locationInView:lp.view];
        wordcraft_ios_long_press((float)loc.x, (float)loc.y);
    }
}

- (void)handleSwipeUndo:(UISwipeGestureRecognizer *)swipe {
    if (swipe.state == UIGestureRecognizerStateEnded) {
        [self stopInertia];
        wordcraft_ios_touch_scroll_begin();
        wordcraft_ios_ime_shortcut(29, 8); // Cmd+Z (Undo)
    }
}

- (void)handleSwipeRedo:(UISwipeGestureRecognizer *)swipe {
    if (swipe.state == UIGestureRecognizerStateEnded) {
        [self stopInertia];
        wordcraft_ios_touch_scroll_begin();
        wordcraft_ios_ime_shortcut(29, 9); // Cmd+Shift+Z (Redo)
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.panTouch1) {
        CGPoint loc = [gestureRecognizer locationInView:gestureRecognizer.view];
        return wordcraft_ios_should_touch_scroll((float)loc.x, (float)loc.y) ? YES : NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // Allow 2-finger pan + pinch to work together smoothly (like Apple Pages/Photos)
    if ((gestureRecognizer == self.panTouch2 && otherGestureRecognizer == self.pinchRecognizer) ||
        (gestureRecognizer == self.pinchRecognizer && otherGestureRecognizer == self.panTouch2)) {
        return YES;
    }
    // Never let 1-finger touch scroll conflict with pinch, long-press, or 2-finger pan
    if (gestureRecognizer == self.panTouch1 || otherGestureRecognizer == self.panTouch1) {
        return NO;
    }
    if (gestureRecognizer == self.longPressRecognizer || otherGestureRecognizer == self.longPressRecognizer) {
        return NO;
    }
    return YES;
}
@end

static WordCraftScrollHandler *gScrollHandler = nil;
static BOOL gInstalledScroll = NO;

static void wordcraft_install_scroll_recognizer(UIView *hostView) {
    if (gInstalledScroll || hostView == nil) return;
    gScrollHandler = [[WordCraftScrollHandler alloc] init];
    gScrollHandler.lastPinchScale = 1.0;

    // 1. Touchscreen 1-finger canvas scroll (Apple HIG / Pages style):
    //    Only begins inside unobstructed document canvas (yields to handles, tables, ink,
    //    scrollbars, dialogs, popups, and double-tap word drag).
    UIPanGestureRecognizer *panTouch1 = [[UIPanGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePan:)];
    panTouch1.minimumNumberOfTouches = 1;
    panTouch1.maximumNumberOfTouches = 1;
    panTouch1.allowedTouchTypes = @[@(UITouchTypeDirect)];
    panTouch1.cancelsTouchesInView = YES;
    panTouch1.delaysTouchesBegan = NO;
    panTouch1.delaysTouchesEnded = NO;
    panTouch1.delegate = gScrollHandler;
    gScrollHandler.panTouch1 = panTouch1;
    [hostView addGestureRecognizer:panTouch1];

    // 2. Touchscreen 2-finger scroll (always available, even over selected objects)
    UIPanGestureRecognizer *panTouch2 = [[UIPanGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePan:)];
    panTouch2.minimumNumberOfTouches = 2;
    panTouch2.maximumNumberOfTouches = 2;
    panTouch2.allowedTouchTypes = @[@(UITouchTypeDirect)];
    panTouch2.cancelsTouchesInView = YES;
    panTouch2.delaysTouchesBegan = NO;
    panTouch2.delaysTouchesEnded = NO;
    panTouch2.delegate = gScrollHandler;
    gScrollHandler.panTouch2 = panTouch2;
    [hostView addGestureRecognizer:panTouch2];

    // 3. Magic Keyboard Trackpad / Mouse: 2-finger indirect scroll
    if (@available(iOS 13.4, *)) {
        UIPanGestureRecognizer *panTrackpad = [[UIPanGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePan:)];
        panTrackpad.allowedTouchTypes = @[];
        panTrackpad.allowedScrollTypesMask = UIScrollTypeMaskAll;
        panTrackpad.cancelsTouchesInView = NO;
        panTrackpad.delaysTouchesBegan = NO;
        panTrackpad.delaysTouchesEnded = NO;
        panTrackpad.delegate = gScrollHandler;
        gScrollHandler.panTrackpad = panTrackpad;
        [hostView addGestureRecognizer:panTrackpad];
    }

    // 4. Pinch-to-Zoom (works for both 2-finger touch pinch & Magic Keyboard trackpad pinch)
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handlePinch:)];
    pinch.cancelsTouchesInView = YES;
    pinch.delaysTouchesBegan = NO;
    pinch.delegate = gScrollHandler;
    gScrollHandler.pinchRecognizer = pinch;
    [hostView addGestureRecognizer:pinch];

    // 5. Magic Keyboard Trackpad / Mouse / Apple Pencil Hover
    if (@available(iOS 13.0, *)) {
        UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handleHover:)];
        hover.delegate = gScrollHandler;
        [hostView addGestureRecognizer:hover];
    }

    // 6. Magic Keyboard Trackpad / Mouse Secondary Click (Right-Click / 2-Finger Click)
    if (@available(iOS 13.4, *)) {
        UITapGestureRecognizer *secondaryClick = [[UITapGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handleSecondaryClick:)];
        secondaryClick.allowedTouchTypes = @[@(UITouchTypeIndirectPointer)];
        secondaryClick.buttonMaskRequired = UIEventButtonMaskSecondary;
        secondaryClick.delaysTouchesBegan = YES;
        secondaryClick.cancelsTouchesInView = YES;
        secondaryClick.delegate = gScrollHandler;
        [hostView addGestureRecognizer:secondaryClick];
    }

    // 7. Touchscreen Long-Press (0.5s) -> Context Menu
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handleLongPress:)];
    longPress.allowedTouchTypes = @[@(UITouchTypeDirect)];
    longPress.minimumPressDuration = 0.5;
    longPress.allowableMovement = 10.0;
    longPress.cancelsTouchesInView = YES;
    longPress.delaysTouchesBegan = NO;
    longPress.delegate = gScrollHandler;
    gScrollHandler.longPressRecognizer = longPress;
    [hostView addGestureRecognizer:longPress];

    // 8. iPadOS Standard 3-Finger Swipe Left/Right -> Undo / Redo
    UISwipeGestureRecognizer *swipeUndo = [[UISwipeGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handleSwipeUndo:)];
    swipeUndo.numberOfTouchesRequired = 3;
    swipeUndo.direction = UISwipeGestureRecognizerDirectionLeft;
    swipeUndo.allowedTouchTypes = @[@(UITouchTypeDirect)];
    swipeUndo.cancelsTouchesInView = YES;
    swipeUndo.delegate = gScrollHandler;
    [hostView addGestureRecognizer:swipeUndo];

    UISwipeGestureRecognizer *swipeRedo = [[UISwipeGestureRecognizer alloc] initWithTarget:gScrollHandler action:@selector(handleSwipeRedo:)];
    swipeRedo.numberOfTouchesRequired = 3;
    swipeRedo.direction = UISwipeGestureRecognizerDirectionRight;
    swipeRedo.allowedTouchTypes = @[@(UITouchTypeDirect)];
    swipeRedo.cancelsTouchesInView = YES;
    swipeRedo.delegate = gScrollHandler;
    [hostView addGestureRecognizer:swipeRedo];

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

static UIWindow *wordcraft_key_window(void) {
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
    return foundWindow;
}

static UIViewController *wordcraft_top_view_controller(void) {
    UIViewController *root = wordcraft_key_window().rootViewController;
    while (root.presentedViewController != nil) {
        root = root.presentedViewController;
    }
    return root;
}

static CAMetalLayer *wordcraft_find_metal_layer(UIView *hostView) {
    if (hostView == nil) return nil;
    if ([hostView.layer isKindOfClass:[CAMetalLayer class]]) {
        return (CAMetalLayer *)hostView.layer;
    }
    for (CALayer *sub in hostView.layer.sublayers) {
        if ([sub isKindOfClass:[CAMetalLayer class]]) {
            return (CAMetalLayer *)sub;
        }
    }
    return nil;
}

static WordCraftIosMetrics gLastMetrics;
static BOOL gHasLastMetrics = NO;
static float gKeyboardOverlap = 0.0f;

@interface WordCraftKeyboardObserver : NSObject
@end

@implementation WordCraftKeyboardObserver
- (void)onKeyboardWillChangeFrame:(NSNotification *)note {
    CGRect endScreen = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIWindow *win = wordcraft_key_window();
    UIView *hostView = win.rootViewController.view;
    if (hostView != nil && !CGRectIsEmpty(endScreen)) {
        CGRect endInView = [hostView convertRect:endScreen fromView:nil];
        CGRect overlap = CGRectIntersection(hostView.bounds, endInView);
        CGFloat h = CGRectIsNull(overlap) ? 0.0 : overlap.size.height;
        // Ignore transient hardware-keyboard QuickType shortcut bars (< 120pt) so they don't push
        // a thick empty strip below the status bar; only lift the viewport for real on-screen keyboards.
        if (h < 120.0 || h > hostView.bounds.size.height * 0.75) {
            h = 0.0;
        }
        gKeyboardOverlap = (float)h;
    } else {
        gKeyboardOverlap = 0.0f;
    }
    wordcraft_ios_request_repaint();
}

- (void)onKeyboardWillHide:(NSNotification *)note {
    gKeyboardOverlap = 0.0f;
    wordcraft_ios_request_repaint();
}
@end

static WordCraftKeyboardObserver *gKeyboardObserver = nil;

static void wordcraft_install_keyboard_observer(void) {
    if (gKeyboardObserver != nil) return;
    gKeyboardObserver = [[WordCraftKeyboardObserver alloc] init];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:gKeyboardObserver
           selector:@selector(onKeyboardWillChangeFrame:)
               name:UIKeyboardWillChangeFrameNotification
             object:nil];
    [nc addObserver:gKeyboardObserver
           selector:@selector(onKeyboardWillHide:)
               name:UIKeyboardWillHideNotification
             object:nil];
    [nc addObserver:gKeyboardObserver
           selector:@selector(onKeyboardWillHide:)
               name:UIKeyboardDidHideNotification
             object:nil];
}

static bool wordcraft_ios_query_metrics(WordCraftIosMetrics *out) {
    if (out == NULL) {
        return false;
    }
    if (![NSThread isMainThread]) {
        if (gHasLastMetrics) {
            *out = gLastMetrics;
            return true;
        }
        return false;
    }
    UIWindow *win = wordcraft_key_window();
    UIView *hostView = win.rootViewController.view;
    if (win == nil || hostView == nil) {
        if (gHasLastMetrics) {
            *out = gLastMetrics;
            return true;
        }
        return false;
    }
    CGSize bounds = hostView.bounds.size;
    if (bounds.width <= 1.0 || bounds.height <= 1.0) {
        if (gHasLastMetrics) {
            *out = gLastMetrics;
            return true;
        }
        return false;
    }
    UIEdgeInsets insets = win.safeAreaInsets;
    double drawableW = bounds.width - insets.left - insets.right;
    double drawableH = bounds.height - insets.top - insets.bottom;
    CAMetalLayer *metalLayer = wordcraft_find_metal_layer(hostView);
    if (metalLayer != nil && metalLayer.drawableSize.width > 1.0 && metalLayer.drawableSize.height > 1.0) {
        CGFloat scale = metalLayer.contentsScale;
        if (scale <= 0.0) scale = hostView.contentScaleFactor;
        if (scale <= 0.0) scale = win.screen.scale;
        if (scale <= 0.0) scale = 1.0;
        drawableW = metalLayer.drawableSize.width / scale;
        drawableH = metalLayer.drawableSize.height / scale;
    }
    if (drawableW <= 1.0) drawableW = bounds.width;
    if (drawableH <= 1.0) drawableH = bounds.height;

    WordCraftIosMetrics m;
    m.view_w = (float)bounds.width;
    m.view_h = (float)bounds.height;
    m.drawable_w = (float)drawableW;
    m.drawable_h = (float)drawableH;
    m.safe_top = (float)insets.top;
    m.safe_bottom = (float)insets.bottom;
    m.safe_left = (float)insets.left;
    m.safe_right = (float)insets.right;
    m.keyboard_overlap = gKeyboardOverlap;

    gLastMetrics = m;
    gHasLastMetrics = YES;
    *out = m;
    return true;
}

void wordcraft_ios_sync_ime(bool active, float x, float y, float w, float h) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gImeActive = active ? YES : NO;
        UIViewController *rootVC = wordcraft_key_window().rootViewController;
        if (rootVC == nil || rootVC.view == nil) {
            return;
        }
        wordcraft_install_winit_responder_hook(rootVC.view);
        wordcraft_install_scroll_recognizer(rootVC.view);
        wordcraft_install_keyboard_observer();

        if (gImeView == nil) {
            gImeView = [[WordCraftImeView alloc] initWithFrame:CGRectMake(x, y, 2, 20)];
            [rootVC.view addSubview:gImeView];
        } else if (gImeView.superview != rootVC.view) {
            [gImeView removeFromSuperview];
            [rootVC.view addSubview:gImeView];
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

static void wordcraft_ios_open_url(const char *url_cstr) {
    if (url_cstr == NULL) return;
    NSString *raw = [NSString stringWithUTF8String:url_cstr];
    if (raw == nil) return;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;

    NSURL *url = [NSURL URLWithString:trimmed];
    if (url == nil) {
        NSString *encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        if (encoded != nil) {
            url = [NSURL URLWithString:encoded];
        }
    }
    if (url == nil) return;
    NSString *scheme = [url.scheme lowercaseString];
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"mailto"])) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    });
}

int main(int argc, char * argv[]) {
    @autoreleasepool {
        setenv("WORDCRAFT_LANGUAGE", "zh-CN", 0);
        wordcraft_ios_register_file_picker(wordcraft_ios_open_file_picker);
        wordcraft_ios_register_file_exporter(wordcraft_ios_export_file);
        wordcraft_ios_register_ime_sync(wordcraft_ios_sync_ime);
        wordcraft_ios_register_metrics(wordcraft_ios_query_metrics);
        wordcraft_ios_register_clipboard(wordcraft_ios_clipboard_get, wordcraft_ios_clipboard_free, wordcraft_ios_clipboard_set);
        wordcraft_ios_register_url_opener(wordcraft_ios_open_url);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = wordcraft_key_window().rootViewController;
            if (vc && vc.view) {
                wordcraft_install_scroll_recognizer(vc.view);
                wordcraft_install_keyboard_observer();
            }
        });
        wordcraft_ios_main();
        return 0;
    }
}
