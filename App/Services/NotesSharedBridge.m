// The only file in iMCP that touches Apple's private NotesShared framework.
//
// NotesShared is not public API. Apple can change it in any macOS update, so this file:
//   - loads the frameworks lazily with dlopen, only when a private Notes tool is first used;
//   - resolves every class by name at runtime (nothing links against the frameworks);
//   - checks every selector with respondsToSelector: before calling it, and fails with a
//     "notes_private_changed" error that names the missing selector;
//   - catches every Objective-C exception, so none ever reaches Swift (Swift cannot catch them);
//   - never opens the Notes database itself. Writes go through Notes' own model objects and its
//     Core Data save, the path Notes.app uses, and every write is read back through a second,
//     independent Core Data context before it is reported as verified.
//
// The interface is one class method taking and returning JSON text:
//   +[IMCPNotesSharedBridge perform:]  {"action": "...", "args": {...}}
//   ->  {"ok": true, "result": {...}}  or  {"ok": false, "error": {"code": "...", "message": "..."}}
// Swift looks the class up by name, so the app target needs no bridging header.
//
// Store access under the App Sandbox needs the Notes folder grant the Notes service already asks
// for (a security-scoped bookmark, started here before the store is opened) and, for writes, the
// home-relative read-write exception for /Library/Group Containers/group.com.apple.notes/.
// ICNoteContext has no stop call, so once the store is open the scope stays started until iMCP quits.
#import <AppKit/AppKit.h>
#import <CoreData/CoreData.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Selectors are resolved at runtime, so the compiler never needs to know the private ones.
#define SEL_(name) NSSelectorFromString(@#name)

#pragma mark - Errors

static NSString *const kFail = @"IMCPNotesFail";

__attribute__((noreturn)) static void fail(NSString *code, NSString *message) {
    @throw [NSException exceptionWithName:kFail reason:message userInfo:@{ @"code" : code }];
}

static NSString *errText(NSError *e) {
    if (!e) return @"no NSError";
    return [NSString stringWithFormat:@"%@ %ld: %@", e.domain, (long)e.code, e.localizedDescription];
}

/// Fails with a message that names the selector Apple removed or renamed.
static void need(id obj, SEL sel) {
    if (!obj) fail(@"notes_private_changed", [NSString stringWithFormat:@"Expected an object for %@ but got nil", NSStringFromSelector(sel)]);
    if (![obj respondsToSelector:sel]) {
        fail(@"notes_private_changed",
            [NSString stringWithFormat:@"NotesShared no longer provides %@[%@ %@]. Apple probably changed it in this macOS update.",
                class_isMetaClass(object_getClass(obj)) ? @"+" : @"-", NSStringFromClass(class_isMetaClass(object_getClass(obj)) ? obj : [obj class]), NSStringFromSelector(sel)]);
    }
}

#define NEED(obj, sel) need((obj), SEL_(sel))

#pragma mark - Typed message sends
// Every call goes through an explicit function type, so the compiler never guesses a signature
// from some unrelated public declaration of the same selector name.

typedef id (*F0)(id, SEL);
typedef id (*F1)(id, SEL, id);
typedef id (*F2)(id, SEL, id, id);
typedef id (*F3)(id, SEL, id, id, id);
typedef id (*F1E)(id, SEL, id, NSError **);
typedef id (*F2E)(id, SEL, id, id, NSError **);
typedef BOOL (*B0)(id, SEL);
typedef BOOL (*B1E)(id, SEL, id, NSError **);
typedef BOOL (*B1OE)(id, SEL, id, NSUInteger, NSError **);
typedef BOOL (*BReplace)(id, SEL, NSRange, id, NSUInteger, NSError **);
typedef void (*V0)(id, SEL);
typedef void (*V1)(id, SEL, id);
typedef void (*VB)(id, SEL, BOOL);
typedef void (*VU)(id, SEL, NSUInteger);
typedef unsigned (*U0)(id, SEL);
typedef NSUInteger (*UL0)(id, SEL);
typedef id (*F2B)(id, SEL, id, id, BOOL);
typedef id (*F1B)(id, SEL, id, BOOL);
typedef NSUInteger (*UL2)(id, SEL, id, id);

static id send0(id o, SEL s) { need(o, s); return ((F0)objc_msgSend)(o, s); }
static id send1(id o, SEL s, id a) { need(o, s); return ((F1)objc_msgSend)(o, s, a); }
static BOOL sendB0(id o, SEL s) { need(o, s); return ((B0)objc_msgSend)(o, s); }

#pragma mark - Generic readers

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    NSString *cap = key.length ? [[[key substringToIndex:1] uppercaseString] stringByAppendingString:[key substringFromIndex:1]] : key;
    if (![obj respondsToSelector:NSSelectorFromString(key)] && ![obj respondsToSelector:NSSelectorFromString([@"is" stringByAppendingString:cap])]) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *ex) { return nil; }
}

static NSString *strVal(id obj, NSString *key) {
    id v = safeValue(obj, key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL boolVal(id obj, NSString *key) {
    id v = safeValue(obj, key);
    return [v respondsToSelector:SEL_(boolValue)] && [v boolValue];
}

static id nn(id v) { return v ?: [NSNull null]; }

/// A JSON true or false, never 1 or 0.
#define YN(x) ((x) ? @YES : @NO)

static NSString *iso(NSDate *d) {
    if (![d isKindOfClass:[NSDate class]]) return nil;
    NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
    return [f stringFromDate:d];
}

#pragma mark - Loading and store access

static id gContextClass;
static NSManagedObjectContext *gMOC;
static NSURL *gScopedURL;
static BOOL gStarted;

static Class cls(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) fail(@"notes_private_changed", [NSString stringWithFormat:@"NotesShared class %@ is missing. Apple probably changed it in this macOS update.", name]);
    return c;
}

static NSString *const kBookmarkKey = @"me.mattt.iMCP.notesContainerBookmark";

/// Starts the security scope the Notes service's folder grant carries. Without it the sandbox and
/// TCC both refuse the Notes group container.
static void startScope(void) {
    if (gScopedURL) return;
    NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:kBookmarkKey];
    if (!data) {
        if (getenv("APP_SANDBOX_CONTAINER_ID")) {
            fail(@"notes_access_needed", @"iMCP has no access to the Notes folder yet. Turn on the Notes service in iMCP Settings and choose the group.com.apple.notes folder when asked.");
        }
        return;
    }
    BOOL stale = NO;
    NSError *e = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:&e];
    if (!url) fail(@"notes_access_needed", [@"The saved Notes folder access could not be resolved. Turn the Notes service off and on in iMCP Settings to choose the folder again. " stringByAppendingString:errText(e)]);
    if (![url startAccessingSecurityScopedResource]) fail(@"notes_access_needed", @"macOS refused to open the saved Notes folder access. Turn the Notes service off and on in iMCP Settings to choose the folder again.");
    gScopedURL = url;
}

static NSManagedObjectContext *store(void) {
    if (gMOC) return gMOC;
    static dispatch_once_t once;
    static BOOL loaded;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_NOW);
        loaded = (h != NULL);
        for (NSString *f in @[ @"NotesSupport", @"NotesUI", @"NotesEditor", @"NotesHTML" ]) {
            dlopen([NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", f, f].UTF8String, RTLD_NOW);
        }
    });
    if (!loaded) fail(@"notes_private_unavailable", @"NotesShared could not be loaded on this Mac.");
    startScope();
    Class ctx = cls(@"ICNoteContext");
    if (!gStarted) {
        need(ctx, SEL_(startSharedContextWithOptions:));
        ((VU)objc_msgSend)(ctx, SEL_(startSharedContextWithOptions:), 0);
        gStarted = YES;
    }
    id shared = send0(ctx, SEL_(sharedContext));
    if (!shared) fail(@"store_unavailable", @"Notes' shared context could not be created.");
    gContextClass = shared;
    id moc = send0(shared, SEL_(managedObjectContext));
    if (![moc isKindOfClass:[NSManagedObjectContext class]]) fail(@"notes_private_changed", @"NotesShared no longer provides a managed object context.");
    NSManagedObjectContext *m = moc;
    if (m.persistentStoreCoordinator.persistentStores.count == 0) {
        fail(@"store_unavailable", @"The Notes database did not open. iMCP needs the Notes folder grant and, for private Notes features, the Group Containers read-write entitlement (see the README).");
    }
    gMOC = m;
    return gMOC;
}

/// Runs a block on the context's queue. Exceptions are caught inside and rethrown outside, so
/// they never cross Core Data's block machinery.
static id onContext(NSManagedObjectContext *moc, id (^block)(void)) {
    __block id result = nil;
    __block NSException *thrown = nil;
    [moc performBlockAndWait:^{
        @try { result = block(); } @catch (NSException *ex) { thrown = ex; }
    }];
    if (thrown) @throw thrown;
    return result;
}

/// A second context on the same coordinator, which sees only what was saved.
static NSManagedObjectContext *freshContext(void) {
    NSManagedObjectContext *f = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    f.persistentStoreCoordinator = store().persistentStoreCoordinator;
    return f;
}

static void saveContext(NSManagedObjectContext *moc) {
    NSError *e = nil;
    if (![moc save:&e]) {
        [moc rollback];
        fail(@"save_failed", [@"Notes refused the change: " stringByAppendingString:errText(e)]);
    }
}

#pragma mark - Notes, folders, identifiers

static NSString *noteURI(id note) { return [[[note objectID] URIRepresentation] absoluteString]; }

static NSString *deepLink(id note) {
    NSString *ident = strVal(note, @"identifier");
    return ident.length ? [@"notes://showNote?identifier=" stringByAppendingString:ident] : nil;
}

static BOOL looksLikeUUID(NSString *s) { return s.length && [[NSUUID alloc] initWithUUIDString:s] != nil; }

static NSString *entityName(id obj) { return [[(NSManagedObject *)obj entity] name]; }

/// Finds a note by the Notes-app id (`x-coredata://…/ICNote/pN`), by its UUID, or by a notes:// link.
static id findNoteIn(NSManagedObjectContext *moc, NSString *ident) {
    if (![ident isKindOfClass:[NSString class]] || !ident.length) fail(@"missing_id", @"A note id is required.");
    NSString *text = ident;
    if ([text hasPrefix:@"notes://"] || [text hasPrefix:@"applenotes://"]) {
        NSURLComponents *c = [NSURLComponents componentsWithString:text];
        for (NSURLQueryItem *q in c.queryItems) if ([q.name isEqualToString:@"identifier"]) text = q.value;
    }
    id found = nil;
    if ([text hasPrefix:@"x-coredata://"]) {
        NSURL *u = [NSURL URLWithString:text];
        NSManagedObjectID *oid = u ? [moc.persistentStoreCoordinator managedObjectIDForURIRepresentation:u] : nil;
        if (oid) {
            NSError *e = nil;
            @try { found = [moc existingObjectWithID:oid error:&e]; } @catch (NSException *ex) { found = nil; }
        }
    } else if (looksLikeUUID(text)) {
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        r.predicate = [NSPredicate predicateWithFormat:@"identifier ==[c] %@", text];
        r.fetchLimit = 1;
        found = [[moc executeFetchRequest:r error:nil] firstObject];
    }
    if (!found || ![entityName(found) isEqualToString:@"ICNote"]) {
        fail(@"not_found", [NSString stringWithFormat:@"No note with id %@. Use an id from notes_get, notes_fetch, or notes_create.", ident]);
    }
    return found;
}

static id findNote(NSString *ident) { return findNoteIn(store(), ident); }

static BOOL isLocked(id note) { return boolVal(note, @"isPasswordProtected") || boolVal(note, @"passwordProtected"); }

static void requireEditable(id note) {
    if (boolVal(note, @"markedForDeletion")) fail(@"note_deleted", @"That note is deleted.");
    if (isLocked(note)) fail(@"note_locked", @"That note is password protected, so it cannot be changed.");
    if ([note respondsToSelector:SEL_(isEditable)] && !sendB0(note, SEL_(isEditable))) {
        fail(@"note_not_editable", @"Notes says this note cannot be edited (it may be shared read-only or in Recently Deleted).");
    }
    if ([note respondsToSelector:SEL_(isDeletedOrInTrash)] && sendB0(note, SEL_(isDeletedOrInTrash))) {
        fail(@"note_deleted", @"That note is in Recently Deleted.");
    }
}

static void requireReadable(id note) {
    if (isLocked(note)) fail(@"note_locked", @"That note is password protected, so its contents cannot be read.");
}

static NSString *folderPath(id folder) {
    NSMutableArray *parts = [NSMutableArray array];
    id f = folder;
    int guard = 0;
    while (f && guard++ < 12) {
        NSString *t = strVal(f, @"title");
        if (t) [parts insertObject:t atIndex:0];
        f = safeValue(f, @"parent");
    }
    return [parts componentsJoinedByString:@"/"];
}

static NSString *accountName(id folderOrNote) {
    id account = safeValue(folderOrNote, @"account");
    return strVal(account, @"name") ?: @"";
}

static id findFolder(NSManagedObjectContext *moc, NSString *path, NSString *accountNameFilter) {
    NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
    r.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
    NSMutableArray *hits = [NSMutableArray array];
    for (id f in [moc executeFetchRequest:r error:nil] ?: @[]) {
        if (![folderPath(f) isEqualToString:path]) continue;
        if (accountNameFilter.length && ![[accountName(f) lowercaseString] isEqualToString:[accountNameFilter lowercaseString]]) continue;
        [hits addObject:f];
    }
    if (hits.count == 0) fail(@"folder_not_found", [NSString stringWithFormat:@"No folder named %@%@.", path, accountNameFilter.length ? [@" in account " stringByAppendingString:accountNameFilter] : @""]);
    if (hits.count > 1) fail(@"folder_ambiguous", [NSString stringWithFormat:@"More than one folder is named %@. Pass account to choose.", path]);
    return hits[0];
}

#pragma mark - Reading a note's body

static const NSUInteger kStyleTitle = 0, kStyleHeading = 1, kStyleSubheading = 2, kStyleBody = 3, kStyleMono = 4, kStyleBullet = 100, kStyleDash = 101, kStyleNumber = 102, kStyleChecklist = 103;

static NSString *styleName(NSUInteger s) {
    switch (s) {
        case kStyleTitle: return @"title";
        case kStyleHeading: return @"heading";
        case kStyleSubheading: return @"subheading";
        case kStyleBody: return @"body";
        case kStyleMono: return @"monospaced";
        case kStyleBullet: return @"bulleted";
        case kStyleDash: return @"dashed";
        case kStyleNumber: return @"numbered";
        case kStyleChecklist: return @"checklist";
        default: return @"unknown";
    }
}

static NSString *paragraphStyleKey(void) {
    static NSString *key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *p = dlsym(RTLD_DEFAULT, "ICTTAttributeNameParagraphStyle");
        if (p) key = *(NSString *__unsafe_unretained *)p;
    });
    if (!key) fail(@"notes_private_changed", @"NotesShared no longer exports ICTTAttributeNameParagraphStyle.");
    return key;
}

static NSAttributedString *bodyOf(id note) {
    id a = send0(note, SEL_(attributedString));
    return [a isKindOfClass:[NSAttributedString class]] ? a : [[NSAttributedString alloc] initWithString:@""];
}

static NSString *attachmentUTI(id att) {
    if (![att respondsToSelector:SEL_(attachmentUTI)]) return nil;
    id v = ((F0)objc_msgSend)(att, SEL_(attachmentUTI));
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL isHashtagUTI(NSString *u) { return [u hasSuffix:@"inlinetextattachment.hashtag"]; }
static BOOL isLinkUTI(NSString *u) { return [u hasSuffix:@"inlinetextattachment.link"]; }

/// Strips the object-replacement characters that stand for attachments.
static NSString *cleanText(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"￼" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

static NSString *stripHash(NSString *t) {
    NSString *s = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    return s;
}

/// The text the person sees for an inline attachment (a tag, a note link).
static NSString *inlineAlt(id textAttachment) {
    for (NSString *k in @[ @"altText", @"displayText" ]) {
        NSString *v = strVal(textAttachment, k);
        if (v.length) return v;
    }
    return @"";
}

/// The Core Data object behind an inline text attachment (a tag or a note link). The attachment
/// can find it itself in most contexts; where it cannot, it is matched by identifier among the
/// note's own inline attachments.
static id modelInlineAttachment(id textAttachment, id note, NSManagedObjectContext *moc) {
    if ([textAttachment respondsToSelector:SEL_(inlineAttachmentInContext:)]) {
        id m = ((F1)objc_msgSend)(textAttachment, SEL_(inlineAttachmentInContext:), moc);
        if (m) return m;
    }
    NSString *ident = nil;
    if ([textAttachment respondsToSelector:SEL_(attachmentIdentifier)]) {
        id v = ((F0)objc_msgSend)(textAttachment, SEL_(attachmentIdentifier));
        if ([v isKindOfClass:[NSString class]]) ident = v;
    }
    id set = safeValue(note, @"inlineAttachments");
    if (ident && [set respondsToSelector:@selector(allObjects)]) {
        for (id m in [set allObjects]) if ([strVal(m, @"identifier") isEqualToString:ident]) return m;
    }
    return nil;
}

static id modelAttachment(id textAttachment, NSManagedObjectContext *moc) {
    if (![textAttachment respondsToSelector:SEL_(attachmentInContext:)]) return nil;
    return ((F1)objc_msgSend)(textAttachment, SEL_(attachmentInContext:), moc);
}

/// The text of a table, row by row, or nil when the model cannot be read.
static NSArray *tableRows(id attachment) {
    id model = safeValue(attachment, @"tableModel");
    id table = safeValue(model, @"table");
    if (!table || ![table respondsToSelector:SEL_(rowCount)] || ![table respondsToSelector:SEL_(columnCount)] || ![table respondsToSelector:SEL_(stringForColumnIndex:rowIndex:)]) return nil;
    NSUInteger rows = ((UL0)objc_msgSend)(table, SEL_(rowCount));
    NSUInteger cols = ((UL0)objc_msgSend)(table, SEL_(columnCount));
    if (rows > 1000 || cols > 100) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger r = 0; r < rows; r++) {
        NSMutableArray *row = [NSMutableArray array];
        for (NSUInteger c = 0; c < cols; c++) {
            id s = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(table, SEL_(stringForColumnIndex:rowIndex:), c, r);
            NSString *t = [s isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)s string] : ([s isKindOfClass:[NSString class]] ? s : @"");
            [row addObject:t];
        }
        [out addObject:row];
    }
    return out;
}

/// The tag a hashtag attachment shows, without the #.
static NSString *tagText(id textAttachment, id note, NSManagedObjectContext *moc) {
    NSString *alt = inlineAlt(textAttachment);
    if (!alt.length) {
        id model = modelInlineAttachment(textAttachment, note, moc);
        if (model) alt = strVal(model, @"altText") ?: strVal(model, @"displayText") ?: @"";
    }
    return stripHash(alt);
}

/// Everything in the body that is not plain text: tags, note links, tables, other attachments.
/// `moc` is the context the note lives in.
static NSArray *bodyObjects(id note, NSManagedObjectContext *moc, BOOL withTableRows) {
    NSAttributedString *body = bodyOf(note);
    NSMutableArray *out = [NSMutableArray array];
    [body enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, body.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (!value) return;
        NSString *uti = attachmentUTI(value) ?: @"";
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"uti"] = uti;
        d[@"location"] = @(range.location);
        if (isHashtagUTI(uti)) {
            d[@"kind"] = @"tag";
            d[@"tag"] = tagText(value, note, moc);
        } else if (isLinkUTI(uti)) {
            d[@"kind"] = @"note_link";
            id inline_ = modelInlineAttachment(value, note, moc);
            NSString *labelText = inlineAlt(value);
            if (!labelText.length && inline_) labelText = strVal(inline_, @"altText") ?: @"";
            d[@"label"] = labelText;
            id target = safeValue(inline_, @"linkedNote");
            if (target) {
                d[@"targetId"] = nn(noteURI(target));
                d[@"targetIdentifier"] = nn(strVal(target, @"identifier"));
                d[@"targetTitle"] = nn(strVal(target, @"title"));
                d[@"url"] = nn(deepLink(target));
            }
        } else if ([uti isEqualToString:@"com.apple.notes.table"]) {
            d[@"kind"] = @"table";
            if (withTableRows) {
                id att = modelAttachment(value, moc);
                NSArray *rows = att ? tableRows(att) : nil;
                if (rows) { d[@"rows"] = rows; d[@"rowCount"] = @(rows.count); d[@"columnCount"] = @(rows.count ? [rows[0] count] : 0); }
            }
        } else {
            d[@"kind"] = @"attachment";
        }
        [out addObject:d];
    }];
    return out;
}

static NSArray *tagsOf(NSArray *objects) {
    NSMutableArray *tags = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *o in objects) {
        if (![o[@"kind"] isEqualToString:@"tag"]) continue;
        NSString *t = o[@"tag"];
        if (t.length && [seen member:[t lowercaseString]] == nil) { [seen addObject:[t lowercaseString]]; [tags addObject:t]; }
    }
    return tags;
}

/// One block per paragraph, in body order.
static NSArray *blocksOf(id note, NSUInteger limit) {
    NSAttributedString *body = bodyOf(note);
    NSString *s = body.string;
    NSMutableArray *blocks = [NSMutableArray array];
    NSUInteger pos = 0, index = 0;
    NSString *key = paragraphStyleKey();
    while (pos <= s.length && blocks.count < limit) {
        if (pos == s.length && index > 0) break;
        NSUInteger start, end, contentsEnd;
        [s getParagraphStart:&start end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(pos, 0)];
        NSString *text = [s substringWithRange:NSMakeRange(start, contentsEnd - start)];
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        b[@"index"] = @(index);
        b[@"text"] = cleanText(text);
        id style = body.length > start ? [body attribute:key atIndex:start effectiveRange:nil] : nil;
        NSUInteger st = kStyleBody;
        if (style && [style respondsToSelector:SEL_(style)]) st = ((U0)objc_msgSend)(style, SEL_(style));
        NSMutableArray *kinds = [NSMutableArray array];
        if (contentsEnd > start) {
            [body enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(start, contentsEnd - start) options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
                if (!v) return;
                NSString *u = attachmentUTI(v) ?: @"";
                [kinds addObject:isHashtagUTI(u) ? @"tag" : isLinkUTI(u) ? @"note_link" : [u isEqualToString:@"com.apple.notes.table"] ? @"table" : @"attachment"];
            }];
        }
        if (kinds.count) b[@"objects"] = kinds;
        b[@"style"] = styleName(st);
        b[@"styleType"] = @(st);
        if (style && [style respondsToSelector:SEL_(indent)]) b[@"indent"] = @(((UL0)objc_msgSend)(style, SEL_(indent)));
        if (style && [style respondsToSelector:SEL_(isBlockQuote)] && sendB0(style, SEL_(isBlockQuote))) b[@"blockQuote"] = @YES;
        if (st == kStyleChecklist) {
            id todo = safeValue(style, @"todo");
            b[@"done"] = YN(todo && [todo respondsToSelector:SEL_(done)] && sendB0(todo, SEL_(done)));
            id uuid = safeValue(todo, @"uuid");
            if ([uuid isKindOfClass:[NSUUID class]]) b[@"checklistItemId"] = [(NSUUID *)uuid UUIDString];
        }
        [blocks addObject:b];
        index++;
        if (end >= s.length) break;
        pos = end;
    }
    return blocks;
}

static NSDictionary *noteSummary(id note) {
    id folder = safeValue(note, @"folder");
    return @{
        @"id" : nn(noteURI(note)),
        @"identifier" : nn(strVal(note, @"identifier")),
        @"title" : nn(strVal(note, @"title")),
        @"folder" : nn(folder ? folderPath(folder) : nil),
        @"account" : accountName(note),
        @"pinned" : YN(boolVal(note, @"isPinned")),
        @"locked" : YN(isLocked(note)),
        @"modified" : nn(iso(safeValue(note, @"modificationDate"))),
        @"link" : nn(deepLink(note)),
    };
}

#pragma mark - Reading through an independent context

/// Runs `block` on a note re-fetched in a fresh context, so it sees only what was saved.
static id readFresh(id note, id (^block)(id freshNote, NSManagedObjectContext *fresh)) {
    NSManagedObjectID *oid = [note objectID];
    NSManagedObjectContext *f = freshContext();
    return onContext(f, ^id {
        NSError *e = nil;
        id n = [f existingObjectWithID:oid error:&e];
        if (!n) fail(@"verify_failed", [@"The note could not be read back: " stringByAppendingString:errText(e)]);
        return block(n, f);
    });
}

#pragma mark - Actions: reads

static NSDictionary *actionStatus(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        NSMutableArray *missing = [NSMutableArray array];
        NSArray *checks = @[
            @[ @"ICNote", @"attributedString", @0 ], @[ @"ICNote", @"appendAttributedString:error:", @0 ], @[ @"ICNote", @"addHashtagToNoteBody:onlyIfMissing:", @0 ],
            @[ @"ICNote", @"replaceCharactersInRange:withAttributedString:options:error:", @0 ], @[ @"ICNote", @"addTableAttachmentWithText:", @0 ],
            @[ @"ICNote", @"setIsPinned:", @0 ], @[ @"ICNote", @"newNoteWithAttributedString:inFolder:error:", @1 ], @[ @"ICHashtag", @"hashtagWithDisplayText:account:createIfNecessary:", @1 ],
            @[ @"ICInlineAttachment", @"newLinkAttachmentToNote:fromNote:parentAttachment:", @1 ], @[ @"ICInlineTextAttachment", @"textAttachmentWithAttachment:", @1 ],
            @[ @"ICMarkdownRepresentation", @"attributedMarkdownStringFromPlainMarkdown:error:", @1 ], @[ @"ICTTParagraphStyle", @"defaultParagraphStyle", @1 ],
            @[ @"ICTTTodo", @"initWithIdentifier:done:", @0 ], @[ @"ICTTAttachment", @"setAttachmentIdentifier:", @0 ],
        ];
        for (NSArray *c in checks) {
            Class k = NSClassFromString(c[0]);
            if (!k) { [missing addObject:[c[0] stringByAppendingString:@" (class)"]]; continue; }
            SEL s = NSSelectorFromString(c[1]);
            BOOL ok = [c[2] boolValue] ? [k respondsToSelector:s] : [k instancesRespondToSelector:s];
            if (!ok) [missing addObject:[NSString stringWithFormat:@"%@ %@", c[0], c[1]]];
        }
        NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        r.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
        NSUInteger notes = [m countForFetchRequest:r error:nil];
        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        return @{ @"os" : [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion],
                  @"storeOpen" : @YES, @"notes" : @(notes), @"missingSelectors" : missing,
                  @"stores" : @(m.persistentStoreCoordinator.persistentStores.count) };
    });
}

static NSDictionary *actionStructure(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireReadable(note);
        NSArray *objects = bodyObjects(note, m, YES);
        NSArray *blocks = blocksOf(note, 5000);
        NSMutableArray *checklist = [NSMutableArray array];
        for (NSDictionary *b in blocks) if ([b[@"style"] isEqualToString:@"checklist"]) [checklist addObject:@{ @"index" : b[@"index"], @"text" : b[@"text"], @"done" : b[@"done"] ?: @NO, @"id" : nn(b[@"checklistItemId"]) }];
        NSUInteger done = 0;
        for (NSDictionary *c in checklist) if ([c[@"done"] boolValue]) done++;
        NSMutableDictionary *out = [noteSummary(note) mutableCopy];
        out[@"tags"] = tagsOf(objects);
        out[@"checklist"] = @{ @"total" : @(checklist.count), @"done" : @(done), @"items" : checklist };
        out[@"objects"] = objects;
        NSMutableArray *tables = [NSMutableArray array], *links = [NSMutableArray array];
        for (NSDictionary *o in objects) {
            if ([o[@"kind"] isEqualToString:@"table"]) [tables addObject:o];
            if ([o[@"kind"] isEqualToString:@"note_link"]) [links addObject:o];
        }
        out[@"tables"] = tables;
        out[@"links"] = links;
        if ([args[@"blocks"] boolValue]) out[@"blocks"] = blocks;
        out[@"blockCount"] = @(blocks.count);
        return out;
    });
}

static NSDictionary *actionChecklistGet(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireReadable(note);
        NSMutableArray *items = [NSMutableArray array];
        NSUInteger done = 0;
        for (NSDictionary *b in blocksOf(note, 5000)) {
            if (![b[@"style"] isEqualToString:@"checklist"]) continue;
            if ([b[@"done"] boolValue]) done++;
            [items addObject:@{ @"index" : b[@"index"], @"text" : b[@"text"], @"done" : b[@"done"] ?: @NO, @"id" : nn(b[@"checklistItemId"]) }];
        }
        return @{ @"id" : nn(noteURI(note)), @"title" : nn(strVal(note, @"title")), @"total" : @(items.count), @"done" : @(done), @"items" : items };
    });
}

static NSDictionary *actionTableGet(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireReadable(note);
        NSMutableArray *tables = [NSMutableArray array];
        for (NSDictionary *o in bodyObjects(note, m, YES)) if ([o[@"kind"] isEqualToString:@"table"]) [tables addObject:o];
        return @{ @"id" : nn(noteURI(note)), @"tables" : tables };
    });
}

static NSDictionary *actionLinkGet(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        if (isLocked(note)) fail(@"note_locked", @"A password protected note cannot be linked.");
        NSString *link = deepLink(note);
        if (!link) fail(@"no_identifier", @"Notes did not give this note an identifier.");
        NSMutableDictionary *out = [noteSummary(note) mutableCopy];
        out[@"url"] = link;
        return out;
    });
}

static NSDictionary *actionLinkList(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireReadable(note);
        NSMutableArray *links = [NSMutableArray array];
        for (NSDictionary *o in bodyObjects(note, m, NO)) if ([o[@"kind"] isEqualToString:@"note_link"]) [links addObject:o];
        return @{ @"id" : nn(noteURI(note)), @"links" : links };
    });
}

/// Every hashtag in use, with how many notes use it.
static NSArray *tagInventory(NSManagedObjectContext *m) {
    NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICHashtag"];
    r.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary];
    Class inlineClass = NSClassFromString(@"ICInlineAttachment");
    SEL countSel = NSSelectorFromString(@"countOfVisibleInlineAttachmentsForHashtagStandardizedContent:account:");
    for (id h in [m executeFetchRequest:r error:nil] ?: @[]) {
        NSString *display = strVal(h, @"displayText") ?: @"";
        NSString *std = strVal(h, @"standardizedContent") ?: [stripHash(display) lowercaseString];
        if (!display.length) continue;
        NSNumber *count = nil;
        if (inlineClass && [inlineClass respondsToSelector:countSel]) count = @(((UL2)objc_msgSend)(inlineClass, countSel, std, safeValue(h, @"account")));
        NSMutableDictionary *e = byKey[std];
        if (!e) { e = [@{ @"tag" : stripHash(display), @"notes" : @0 } mutableCopy]; byKey[std] = e; }
        if (count) e[@"notes"] = @([e[@"notes"] integerValue] + count.integerValue);
        NSString *acct = strVal(safeValue(h, @"account"), @"name");
        if (acct) { NSMutableArray *a = e[@"accounts"] ?: [NSMutableArray array]; if (![a containsObject:acct]) [a addObject:acct]; e[@"accounts"] = a; }
    }
    return [byKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"tag"] caseInsensitiveCompare:b[@"tag"]]; }];
}

static NSDictionary *actionTagsList(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        if (args[@"id"]) {
            id note = findNote(args[@"id"]);
            requireReadable(note);
            return @{ @"id" : nn(noteURI(note)), @"tags" : tagsOf(bodyObjects(note, m, NO)) };
        }
        if (args[@"folder"]) {
            id folder = findFolder(m, args[@"folder"], args[@"account"]);
            NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
            r.predicate = [NSPredicate predicateWithFormat:@"folder == %@ AND markedForDeletion == NO", folder];
            NSMutableDictionary *map = [NSMutableDictionary dictionary];
            NSMutableArray *unreadable = [NSMutableArray array];
            for (id n in [m executeFetchRequest:r error:nil] ?: @[]) {
                if (isLocked(n)) { [unreadable addObject:nn(noteURI(n))]; continue; }
                for (NSString *t in tagsOf(bodyObjects(n, m, NO))) {
                    NSMutableArray *ids = map[t] ?: [NSMutableArray array];
                    [ids addObject:noteURI(n)];
                    map[t] = ids;
                }
            }
            NSMutableArray *tags = [NSMutableArray array];
            for (NSString *t in [map.allKeys sortedArrayUsingSelector:SEL_(caseInsensitiveCompare:)]) [tags addObject:@{ @"tag" : t, @"noteIds" : map[t] }];
            return @{ @"folder" : folderPath(folder), @"tags" : tags, @"lockedNotesSkipped" : @(unreadable.count) };
        }
        return @{ @"inventory" : tagInventory(m) };
    });
}

#pragma mark - Actions: writes

/// A paragraph separator that keeps the style of the paragraph it ends, or nil when the body
/// already ends with a newline (or is empty).
static NSAttributedString *separatorFor(NSAttributedString *body) {
    if (body.length == 0) return nil;
    if ([body.string hasSuffix:@"\n"]) return nil;
    id style = [body attribute:paragraphStyleKey() atIndex:body.length - 1 effectiveRange:nil];
    return [[NSAttributedString alloc] initWithString:@"\n" attributes:style ? @{ paragraphStyleKey() : style } : @{}];
}

static void appendTo(id note, NSAttributedString *text) {
    SEL s = SEL_(appendAttributedString:error:);
    need(note, s);
    NSError *e = nil;
    if (!((B1E)objc_msgSend)(note, s, text, &e)) fail(@"edit_failed", [@"Notes refused the edit: " stringByAppendingString:errText(e)]);
}

static NSDictionary *writeResult(NSDictionary *base, BOOL verified, NSString *detail) {
    NSMutableDictionary *o = [base mutableCopy];
    o[@"verified"] = YN(verified);
    if (!verified && detail) o[@"verifyDetail"] = detail;
    return o;
}

static id hashtagFor(NSString *tag, id account) {
    Class hc = cls(@"ICHashtag");
    SEL s = SEL_(hashtagWithDisplayText:account:createIfNecessary:);
    need(hc, s);
    id h = ((F2B)objc_msgSend)(hc, s, [@"#" stringByAppendingString:tag], account, YES);
    if (!h) fail(@"tag_failed", [NSString stringWithFormat:@"Notes would not create the tag #%@.", tag]);
    return h;
}

static BOOL hasTag(NSArray *tags, NSString *tag) {
    for (NSString *t in tags) if ([t caseInsensitiveCompare:tag] == NSOrderedSame) return YES;
    return NO;
}

/// Adds a tag to a note's body. Returns whether the tag was added (NO when already present).
static BOOL addTagTo(id note, NSString *tag, NSManagedObjectContext *m) {
    if (hasTag(tagsOf(bodyObjects(note, m, NO)), tag)) return NO;
    id h = hashtagFor(tag, safeValue(note, @"account"));
    SEL s = SEL_(addHashtagToNoteBody:onlyIfMissing:);
    need(note, s);
    ((F1B)objc_msgSend)(note, s, h, YES);
    return YES;
}

/// Removes every inline occurrence of a tag from a note's body. Returns how many were removed.
static NSUInteger removeTagFrom(id note, NSString *tag, NSManagedObjectContext *moc) {
    NSAttributedString *body = bodyOf(note);
    NSMutableArray *ranges = [NSMutableArray array];
    [body enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, body.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (!value || !isHashtagUTI(attachmentUTI(value) ?: @"")) return;
        if ([tagText(value, note, moc) caseInsensitiveCompare:tag] == NSOrderedSame) [ranges addObject:[NSValue valueWithRange:range]];
    }];
    SEL s = SEL_(replaceCharactersInRange:withAttributedString:options:error:);
    need(note, s);
    for (NSValue *v in [ranges reverseObjectEnumerator]) {
        NSError *e = nil;
        if (!((BReplace)objc_msgSend)(note, s, v.rangeValue, [[NSAttributedString alloc] initWithString:@""], 0, &e)) {
            fail(@"edit_failed", [@"Notes refused to remove the tag: " stringByAppendingString:errText(e)]);
        }
    }
    return ranges.count;
}

static NSArray *cleanTagArgs(NSArray *tags) {
    NSMutableArray *out = [NSMutableArray array];
    for (id t in tags) {
        NSString *s = [t isKindOfClass:[NSString class]] ? stripHash(t) : @"";
        if (!s.length || [s rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) fail(@"invalid_tags", [NSString stringWithFormat:@"'%@' is not a valid tag. Tags are single words.", t]);
        if (!hasTag(out, s)) [out addObject:s];
    }
    return out;
}

static NSDictionary *actionTagsChange(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        NSArray *ids = [args[@"ids"] isKindOfClass:[NSArray class]] ? args[@"ids"] : (args[@"id"] ? @[ args[@"id"] ] : @[]);
        if (ids.count == 0) fail(@"missing_id", @"A note id is required.");
        NSArray *tags = [args[@"tags"] isKindOfClass:[NSArray class]] ? cleanTagArgs(args[@"tags"]) : @[];
        NSString *oldTag = args[@"old"] ? cleanTagArgs(@[ args[@"old"] ]).firstObject : nil;
        NSString *newTag = args[@"new"] ? cleanTagArgs(@[ args[@"new"] ]).firstObject : nil;
        NSMutableArray *results = [NSMutableArray array];
        BOOL allVerified = YES;
        for (id ident in ids) {
            id note = findNote(ident);
            requireEditable(note);
            NSArray *before = tagsOf(bodyObjects(note, m, NO));
            NSMutableArray *expectPresent = [NSMutableArray array], *expectAbsent = [NSMutableArray array];
            NSMutableArray *changed = [NSMutableArray array];
            if ([mode isEqualToString:@"add"]) {
                for (NSString *t in tags) { if (addTagTo(note, t, m)) [changed addObject:t]; [expectPresent addObject:t]; }
            } else if ([mode isEqualToString:@"remove"]) {
                for (NSString *t in tags) { if (removeTagFrom(note, t, m) > 0) [changed addObject:t]; [expectAbsent addObject:t]; }
            } else if ([mode isEqualToString:@"replace"]) {
                if (!hasTag(before, oldTag)) { [results addObject:@{ @"id" : nn(noteURI(note)), @"changed" : @NO, @"skipped" : [NSString stringWithFormat:@"The note does not have #%@.", oldTag], @"tags" : before, @"verified" : @YES }]; continue; }
                addTagTo(note, newTag, m);
                [expectPresent addObject:newTag];
                // Remove the old tag only after the new one is saved and read back.
                saveContext(m);
                BOOL newOk = [readFresh(note, ^id(id fn, NSManagedObjectContext *f) { return @(hasTag(tagsOf(bodyObjects(fn, f, NO)), newTag)); }) boolValue];
                if (!newOk) { [results addObject:@{ @"id" : nn(noteURI(note)), @"changed" : @YES, @"verified" : @NO, @"verifyDetail" : @"The new tag did not read back, so the old tag was left in place." }]; allVerified = NO; break; }
                if (![oldTag isEqualToString:newTag] && [oldTag caseInsensitiveCompare:newTag] != NSOrderedSame) { removeTagFrom(note, oldTag, m); [expectAbsent addObject:oldTag]; }
                [changed addObject:newTag];
            } else {
                fail(@"invalid_mode", @"Unknown tag action.");
            }
            saveContext(m);
            NSArray *after = readFresh(note, ^id(id fn, NSManagedObjectContext *f) { return tagsOf(bodyObjects(fn, f, NO)); });
            BOOL ok = YES;
            for (NSString *t in expectPresent) if (!hasTag(after, t)) ok = NO;
            for (NSString *t in expectAbsent) if (hasTag(after, t)) ok = NO;
            if (!ok) allVerified = NO;
            [results addObject:@{ @"id" : nn(noteURI(note)), @"changed" : YN(changed.count > 0), @"changedTags" : changed, @"tags" : after, @"verified" : YN(ok) }];
        }
        return @{ @"results" : results, @"verified" : YN(allVerified) };
    });
}

static NSDictionary *actionPin(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireEditable(note);
        BOOL want = [args[@"pinned"] boolValue];
        BOOL was = boolVal(note, @"isPinned");
        if (args[@"expectedPinned"] && [args[@"expectedPinned"] boolValue] != was) fail(@"stale", [NSString stringWithFormat:@"The note is %@ now, not %@ as expected. Nothing was changed.", was ? @"pinned" : @"not pinned", [args[@"expectedPinned"] boolValue] ? @"pinned" : @"unpinned"]);
        if (was != want) {
            SEL s = SEL_(setIsPinned:);
            need(note, s);
            ((VB)objc_msgSend)(note, s, want);
            saveContext(m);
        }
        BOOL now = [readFresh(note, ^id(id fn, NSManagedObjectContext *f) { return @(boolVal(fn, @"isPinned")); }) boolValue];
        return writeResult(@{ @"id" : nn(noteURI(note)), @"title" : nn(strVal(note, @"title")), @"pinned" : YN(now), @"changed" : YN(was != want) }, now == want, @"The pinned state did not read back as requested.");
    });
}

static id newTodoStyle(BOOL done, NSString **uuidOut) {
    Class sc = cls(@"ICTTParagraphStyle");
    id style = send0(send0(sc, SEL_(defaultParagraphStyle)), SEL_(mutableCopy));
    need(style, SEL_(setStyle:));
    ((VU)objc_msgSend)(style, SEL_(setStyle:), kStyleChecklist);
    Class tc = cls(@"ICTTTodo");
    id todo = send0(tc, SEL_(alloc));
    need(todo, SEL_(initWithIdentifier:done:));
    NSUUID *uuid = [NSUUID UUID];
    todo = ((F1B)objc_msgSend)(todo, SEL_(initWithIdentifier:done:), uuid, done);
    if (!todo) fail(@"notes_private_changed", @"ICTTTodo could not be created.");
    need(style, SEL_(setTodo:));
    ((V1)objc_msgSend)(style, SEL_(setTodo:), todo);
    if (uuidOut) *uuidOut = uuid.UUIDString;
    return style;
}

static NSArray *checklistTexts(NSArray *blocks) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *b in blocks) if ([b[@"style"] isEqualToString:@"checklist"]) [a addObject:b];
    return a;
}

static NSDictionary *actionChecklistAdd(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireEditable(note);
        NSArray *items = args[@"items"];
        NSString *key = paragraphStyleKey();
        NSAttributedString *body = bodyOf(note);
        NSArray *beforeBlocks = blocksOf(note, 5000);
        NSMutableAttributedString *add = [NSMutableAttributedString new];
        NSAttributedString *sep = separatorFor(body);
        if (sep) [add appendAttributedString:sep];
        NSMutableArray *added = [NSMutableArray array];
        for (NSUInteger i = 0; i < items.count; i++) {
            NSString *uuid = nil;
            id style = newTodoStyle([args[@"done"] boolValue], &uuid);
            NSString *text = items[i];
            if (i + 1 < items.count) text = [text stringByAppendingString:@"\n"];
            [add appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{ key : style }]];
            [added addObject:items[i]];
        }
        appendTo(note, add);
        saveContext(m);
        NSDictionary *res = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSArray *blocks = blocksOf(fn, 5000);
            NSArray *cl = checklistTexts(blocks), *clBefore = checklistTexts(beforeBlocks);
            BOOL ok = cl.count == clBefore.count + added.count;
            for (NSUInteger i = 0; ok && i < added.count; i++) ok = [cl[clBefore.count + i][@"text"] isEqualToString:added[i]];
            // The paragraphs that existed before keep their styles.
            for (NSUInteger i = 0; ok && i < beforeBlocks.count && i < blocks.count; i++) {
                if (![blocks[i][@"style"] isEqualToString:beforeBlocks[i][@"style"]]) ok = NO;
            }
            return @{ @"ok" : @(ok), @"items" : cl };
        });
        return writeResult(@{ @"id" : nn(noteURI(note)), @"added" : added, @"checklist" : res[@"items"] }, [res[@"ok"] boolValue], @"The new checklist items, or the styles of the existing paragraphs, did not read back as expected.");
    });
}

static NSDictionary *actionChecklistSet(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireEditable(note);
        BOOL done = [args[@"done"] boolValue];
        NSAttributedString *body = bodyOf(note);
        NSString *s = body.string;
        NSArray *blocks = blocksOf(note, 5000);
        NSArray *cl = checklistTexts(blocks);
        NSDictionary *target = nil;
        if (args[@"index"]) {
            NSInteger n = [args[@"index"] integerValue];
            if (n < 0 || n >= (NSInteger)cl.count) fail(@"invalid_index", [NSString stringWithFormat:@"The note has %lu checklist items; index is zero based.", (unsigned long)cl.count]);
            target = cl[n];
        } else {
            NSMutableArray *hits = [NSMutableArray array];
            for (NSDictionary *b in cl) if ([[b[@"text"] lowercaseString] isEqualToString:[args[@"text"] lowercaseString]]) [hits addObject:b];
            if (hits.count == 0) fail(@"item_not_found", @"No checklist item has that text.");
            if (hits.count > 1) fail(@"item_ambiguous", @"More than one checklist item has that text. Use index.");
            target = hits[0];
        }
        if ([target[@"done"] boolValue] != done) {
            // Find the paragraph range of the target block.
            NSUInteger pos = 0, idx = 0, start = 0, end = 0, contentsEnd = 0;
            while (YES) {
                [s getParagraphStart:&start end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(pos, 0)];
                if (idx == [target[@"index"] unsignedIntegerValue]) break;
                idx++;
                if (end >= s.length) fail(@"item_not_found", @"The checklist item moved.");
                pos = end;
            }
            NSRange range = NSMakeRange(start, contentsEnd - start);
            id old = [body attribute:paragraphStyleKey() atIndex:start effectiveRange:nil];
            id oldTodo = safeValue(old, @"todo");
            NSUUID *uuid = [safeValue(oldTodo, @"uuid") isKindOfClass:[NSUUID class]] ? safeValue(oldTodo, @"uuid") : [NSUUID UUID];
            id style = send0(old, SEL_(mutableCopy));
            Class tc = cls(@"ICTTTodo");
            id todo = send0(tc, SEL_(alloc));
            need(todo, SEL_(initWithIdentifier:done:));
            todo = ((F1B)objc_msgSend)(todo, SEL_(initWithIdentifier:done:), uuid, done);
            need(style, SEL_(setTodo:));
            ((V1)objc_msgSend)(style, SEL_(setTodo:), todo);
            NSMutableAttributedString *replacement = [[body attributedSubstringFromRange:range] mutableCopy];
            [replacement addAttribute:paragraphStyleKey() value:style range:NSMakeRange(0, replacement.length)];
            SEL sel = SEL_(replaceCharactersInRange:withAttributedString:options:error:);
            need(note, sel);
            NSError *e = nil;
            if (!((BReplace)objc_msgSend)(note, sel, range, replacement, 0, &e)) fail(@"edit_failed", [@"Notes refused the edit: " stringByAppendingString:errText(e)]);
            saveContext(m);
        }
        NSDictionary *item = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSArray *now = checklistTexts(blocksOf(fn, 5000));
            NSUInteger i = [args[@"index"] ? args[@"index"] : @([cl indexOfObject:target]) unsignedIntegerValue];
            return i < now.count ? now[i] : @{};
        });
        return writeResult(@{ @"id" : nn(noteURI(note)), @"item" : item, @"changed" : YN([target[@"done"] boolValue] != done) }, item[@"done"] && [item[@"done"] boolValue] == done && [item[@"text"] isEqualToString:target[@"text"]], @"The item did not read back with the requested state.");
    });
}

static NSDictionary *actionTableCreate(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireEditable(note);
        NSArray *rows = args[@"rows"];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSArray *r in rows) [lines addObject:[r componentsJoinedByString:@"\t"]];
        NSArray *tablesBefore = [bodyObjects(note, m, NO) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'table'"]];
        SEL add = SEL_(addTableAttachmentWithText:);
        need(note, add);
        id att = ((F1)objc_msgSend)(note, add, [[NSAttributedString alloc] initWithString:[lines componentsJoinedByString:@"\n"]]);
        if (!att) fail(@"table_failed", @"Notes would not create the table.");
        // The attachment row exists but the body has no marker for it yet; place it at the end.
        NSString *ident = strVal(att, @"identifier");
        Class tt = cls(@"ICTTAttachment");
        id marker = send0(send0(tt, SEL_(alloc)), SEL_(init));
        need(marker, SEL_(setAttachmentIdentifier:));
        need(marker, SEL_(setAttachmentUTI:));
        ((V1)objc_msgSend)(marker, SEL_(setAttachmentIdentifier:), ident);
        ((V1)objc_msgSend)(marker, SEL_(setAttachmentUTI:), @"com.apple.notes.table");
        NSMutableAttributedString *addText = [NSMutableAttributedString new];
        NSAttributedString *sep = separatorFor(bodyOf(note));
        if (sep) [addText appendAttributedString:sep];
        [addText appendAttributedString:[[NSAttributedString alloc] initWithString:@"￼" attributes:@{ NSAttachmentAttributeName : marker }]];
        appendTo(note, addText);
        saveContext(m);
        NSDictionary *res = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSArray *tables = [bodyObjects(fn, f, YES) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'table'"]];
            NSDictionary *last = tables.lastObject;
            BOOL ok = tables.count == tablesBefore.count + 1 && [last[@"rows"] isEqual:rows];
            return @{ @"ok" : @(ok), @"table" : nn(last), @"count" : @(tables.count) };
        });
        return writeResult(@{ @"id" : nn(noteURI(note)), @"table" : res[@"table"], @"tableCount" : res[@"count"] }, [res[@"ok"] boolValue], @"The table did not read back with the same cells.");
    });
}

static NSDictionary *actionLinkInsert(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        id target = findNote(args[@"target"]);
        requireEditable(note);
        if (isLocked(target)) fail(@"note_locked", @"A password protected note cannot be linked.");
        if ([note objectID] == [target objectID] || [noteURI(note) isEqualToString:noteURI(target)]) fail(@"invalid_target", @"A note cannot link to itself.");
        Class ia = cls(@"ICInlineAttachment");
        id inlineAtt = nil;
        SEL s3 = SEL_(newLinkAttachmentToNote:fromNote:parentAttachment:);
        if ([ia respondsToSelector:s3]) {
            inlineAtt = ((F3)objc_msgSend)(ia, s3, target, note, nil);
        } else {
            SEL s4 = SEL_(newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:);
            need(ia, s4);
            inlineAtt = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(ia, s4, [[NSUUID UUID] UUIDString], target, note, nil);
        }
        if (!inlineAtt) fail(@"link_failed", @"Notes would not create the link.");
        NSString *label = args[@"label"];
        if (label.length && [inlineAtt respondsToSelector:SEL_(setAltText:)]) ((V1)objc_msgSend)(inlineAtt, SEL_(setAltText:), label);
        id textAtt = send1(cls(@"ICInlineTextAttachment"), SEL_(textAttachmentWithAttachment:), inlineAtt);
        if (![textAtt isKindOfClass:[NSTextAttachment class]]) fail(@"notes_private_changed", @"NotesShared no longer gives an NSTextAttachment for a note link.");
        NSMutableAttributedString *add = [NSMutableAttributedString new];
        NSAttributedString *sep = separatorFor(bodyOf(note));
        if (sep) [add appendAttributedString:sep];
        [add appendAttributedString:[NSAttributedString attributedStringWithAttachment:textAtt]];
        appendTo(note, add);
        saveContext(m);
        NSString *targetURI = noteURI(target);
        NSDictionary *res = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSArray *links = [bodyObjects(fn, f, NO) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'note_link'"]];
            NSDictionary *hit = nil;
            for (NSDictionary *l in links) if ([l[@"targetId"] isEqualToString:targetURI]) hit = l;
            return @{ @"ok" : @(hit != nil), @"link" : nn(hit) };
        });
        return writeResult(@{ @"id" : nn(noteURI(note)), @"link" : res[@"link"], @"targetUrl" : nn(deepLink(target)) }, [res[@"ok"] boolValue], @"The link to the other note did not read back.");
    });
}

/// Markdown as the styled text Notes stores (headings, checklists, bold), ready to append.
/// The importer's own intermediate form only works as input to creating a note.
static NSAttributedString *styledFromMarkdown(NSString *content) {
    Class rep = cls(@"ICMarkdownRepresentation");
    SEL s = SEL_(attributedStringFromPossibleMarkdown:fallback:);
    need(rep, s);
    id a = ((F2)objc_msgSend)(rep, s, content, [[NSAttributedString alloc] initWithString:content]);
    if (![a isKindOfClass:[NSAttributedString class]]) fail(@"markdown_failed", @"Notes could not read that Markdown.");
    return a;
}

static NSAttributedString *attributedFrom(NSString *content, NSString *format) {
    if ([format isEqualToString:@"markdown"]) {
        Class rep = cls(@"ICMarkdownRepresentation");
        SEL s = SEL_(attributedMarkdownStringFromPlainMarkdown:error:);
        need(rep, s);
        NSError *e = nil;
        id a = ((F1E)objc_msgSend)(rep, s, content, &e);
        if (![a isKindOfClass:[NSAttributedString class]]) fail(@"markdown_failed", [@"Notes could not read that Markdown: " stringByAppendingString:errText(e)]);
        return a;
    }
    return [[NSAttributedString alloc] initWithString:content];
}

static NSDictionary *actionAppend(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id note = findNote(args[@"id"]);
        requireEditable(note);
        NSString *content = args[@"content"];
        NSAttributedString *add = [args[@"format"] isEqualToString:@"markdown"] ? styledFromMarkdown(content) : [[NSAttributedString alloc] initWithString:content];
        NSAttributedString *before = bodyOf(note);
        NSString *beforeText = [before.string copy];
        NSUInteger objectsBefore = bodyObjects(note, m, NO).count;
        NSMutableAttributedString *full = [NSMutableAttributedString new];
        NSAttributedString *sep = separatorFor(before);
        if (sep) [full appendAttributedString:sep];
        [full appendAttributedString:add];
        appendTo(note, full);
        saveContext(m);
        NSString *needle = cleanText(add.string);
        NSDictionary *res = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSString *now = bodyOf(fn).string;
            BOOL kept = [now hasPrefix:beforeText];
            BOOL appended = needle.length == 0 || [[now substringFromIndex:MIN(beforeText.length, now.length)] containsString:needle];
            BOOL objects = bodyObjects(fn, f, NO).count >= objectsBefore;
            return @{ @"ok" : @(kept && appended && objects), @"length" : @(now.length) };
        });
        return writeResult(@{ @"id" : nn(noteURI(note)), @"title" : nn(strVal(note, @"title")), @"appendedCharacters" : @(add.length), @"length" : res[@"length"] }, [res[@"ok"] boolValue], @"The existing text and objects, or the new text, did not read back as expected.");
    });
}

static NSDictionary *actionCreateMarkdown(NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        id folder = nil;
        if (args[@"folder"]) {
            folder = findFolder(m, args[@"folder"], args[@"account"]);
        } else {
            Class ac = cls(@"ICAccount");
            id account = nil;
            if (args[@"account"]) {
                NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICAccount"];
                for (id a in [m executeFetchRequest:r error:nil] ?: @[]) if ([[strVal(a, @"name") lowercaseString] isEqualToString:[args[@"account"] lowercaseString]]) account = a;
                if (!account) fail(@"account_not_found", [NSString stringWithFormat:@"No account named %@.", args[@"account"]]);
            } else {
                account = send1(ac, SEL_(defaultAccountInContext:), m);
            }
            folder = send0(account, SEL_(defaultFolder));
            if (!folder) fail(@"folder_not_found", @"The account has no default folder. Pass folder.");
        }
        if ([folder respondsToSelector:SEL_(isTrashFolder)] && sendB0(folder, SEL_(isTrashFolder))) fail(@"invalid_folder", @"A note cannot be created in Recently Deleted.");
        NSAttributedString *attr = attributedFrom(args[@"markdown"], @"markdown");
        Class nc = cls(@"ICNote");
        SEL s = SEL_(newNoteWithAttributedString:inFolder:error:);
        need(nc, s);
        NSError *e = nil;
        id note = ((F2E)objc_msgSend)(nc, s, attr, folder, &e);
        if (!note) fail(@"create_failed", [@"Notes would not create the note: " stringByAppendingString:errText(e)]);
        saveContext(m);
        NSDictionary *res = readFresh(note, ^id(id fn, NSManagedObjectContext *f) {
            NSString *firstLine = [[bodyOf(fn).string componentsSeparatedByString:@"\n"] firstObject];
            return @{ @"ok" : @(bodyOf(fn).length > 0 && !boolVal(fn, @"markedForDeletion")), @"summary" : noteSummary(fn), @"firstLine" : nn(firstLine), @"blocks" : blocksOf(fn, 200) };
        });
        NSMutableDictionary *out = [res[@"summary"] mutableCopy];
        out[@"blocks"] = res[@"blocks"];
        return writeResult(out, [res[@"ok"] boolValue], @"The new note did not read back.");
    });
}

#pragma mark - Debug actions (self-test only)

#if DEBUG
static NSDictionary *actionDebug(NSString *action, NSDictionary *args) {
    NSManagedObjectContext *m = store();
    return onContext(m, ^id {
        if ([action isEqualToString:@"debug.create_folder"]) {
            id account = send1(cls(@"ICAccount"), SEL_(defaultAccountInContext:), m);
            id folder = send1(cls(@"ICFolder"), SEL_(newFolderInAccount:), account);
            if (!folder) fail(@"create_failed", @"newFolderInAccount: returned nil");
            [folder setValue:args[@"title"] forKey:@"title"];
            saveContext(m);
            return @{ @"title" : nn(strVal(folder, @"title")), @"account" : accountName(folder), @"id" : nn(noteURI(folder)) };
        }
        if ([action isEqualToString:@"debug.create_note"]) {
            id folder = findFolder(m, args[@"folder"], nil);
            Class nc = cls(@"ICNote");
            NSError *e = nil;
            id note = ((F2E)objc_msgSend)(nc, SEL_(newNoteWithString:inFolder:error:), args[@"text"], folder, &e);
            if (!note) fail(@"create_failed", errText(e));
            saveContext(m);
            return noteSummary(note);
        }
        if ([action isEqualToString:@"debug.cleanup"]) {
            // Marks the folder and everything in it deleted, through Notes' own call (never deleteFromLocalDatabase).
            NSString *prefix = args[@"prefix"];
            if (![prefix hasPrefix:@"iMCP test "]) fail(@"refused", @"Cleanup only touches folders named 'iMCP test …'.");
            NSFetchRequest *r = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
            r.predicate = [NSPredicate predicateWithFormat:@"title == %@ AND markedForDeletion == NO", prefix];
            NSUInteger notes = 0, folders = 0;
            for (id f in [m executeFetchRequest:r error:nil] ?: @[]) {
                NSFetchRequest *nr = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
                nr.predicate = [NSPredicate predicateWithFormat:@"folder == %@ AND markedForDeletion == NO", f];
                for (id n in [m executeFetchRequest:nr error:nil] ?: @[]) { send0(n, SEL_(markForDeletion)); notes++; }
                send0(f, SEL_(markForDeletion));
                folders++;
            }
            // The tags the self-test made (all named iMCPtest…), so none stay in Oliver's tag list.
            NSUInteger tags = 0;
            NSFetchRequest *hr = [NSFetchRequest fetchRequestWithEntityName:@"ICHashtag"];
            hr.predicate = [NSPredicate predicateWithFormat:@"markedForDeletion == NO"];
            for (id h in [m executeFetchRequest:hr error:nil] ?: @[]) {
                if ([[stripHash(strVal(h, @"displayText") ?: @"") lowercaseString] hasPrefix:@"imcptest"]) { send0(h, SEL_(markForDeletion)); tags++; }
            }
            saveContext(m);
            NSManagedObjectContext *f = freshContext();
            NSNumber *live = onContext(f, ^id {
                NSFetchRequest *fr = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
                fr.predicate = [NSPredicate predicateWithFormat:@"title == %@ AND markedForDeletion == NO", prefix];
                NSUInteger liveFolders = [f countForFetchRequest:fr error:nil];
                NSFetchRequest *nr = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
                nr.predicate = [NSPredicate predicateWithFormat:@"folder.title == %@ AND markedForDeletion == NO", prefix];
                NSFetchRequest *tr = [NSFetchRequest fetchRequestWithEntityName:@"ICHashtag"];
                tr.predicate = [NSPredicate predicateWithFormat:@"displayText CONTAINS[c] %@ AND markedForDeletion == NO", @"iMCPtest"];
                return @(liveFolders + [f countForFetchRequest:nr error:nil] + [f countForFetchRequest:tr error:nil]);
            });
            return @{ @"notesDeleted" : @(notes), @"foldersDeleted" : @(folders), @"tagsDeleted" : @(tags), @"liveRemaining" : live };
        }
        if ([action isEqualToString:@"debug.fresh_text"]) {
            id note = findNote(args[@"id"]);
            return readFresh(note, ^id(id fn, NSManagedObjectContext *f) { return @{ @"text" : bodyOf(fn).string, @"pinned" : @(boolVal(fn, @"isPinned")) }; });
        }
        fail(@"unknown_action", action);
    });
}
#endif

#pragma mark - Entry point

@interface IMCPNotesSharedBridge : NSObject
+ (NSString *)perform:(NSString *)requestJSON;
@end

@implementation IMCPNotesSharedBridge

+ (NSDictionary *)dispatch:(NSString *)action args:(NSDictionary *)args {
    if ([action isEqualToString:@"status"]) return actionStatus(args);
    if ([action isEqualToString:@"structure"]) return actionStructure(args);
    if ([action isEqualToString:@"tags.list"]) return actionTagsList(args);
    if ([action isEqualToString:@"tags.change"]) return actionTagsChange(args);
    if ([action isEqualToString:@"pin"]) return actionPin(args);
    if ([action isEqualToString:@"checklist.get"]) return actionChecklistGet(args);
    if ([action isEqualToString:@"checklist.add"]) return actionChecklistAdd(args);
    if ([action isEqualToString:@"checklist.set"]) return actionChecklistSet(args);
    if ([action isEqualToString:@"table.get"]) return actionTableGet(args);
    if ([action isEqualToString:@"table.create"]) return actionTableCreate(args);
    if ([action isEqualToString:@"link.get"]) return actionLinkGet(args);
    if ([action isEqualToString:@"link.list"]) return actionLinkList(args);
    if ([action isEqualToString:@"link.insert"]) return actionLinkInsert(args);
    if ([action isEqualToString:@"append"]) return actionAppend(args);
    if ([action isEqualToString:@"create_markdown"]) return actionCreateMarkdown(args);
#if DEBUG
    if ([action hasPrefix:@"debug."]) return actionDebug(action, args);
#endif
    fail(@"unknown_action", [NSString stringWithFormat:@"Unknown private Notes action '%@'.", action]);
}

+ (NSString *)perform:(NSString *)requestJSON {
    NSDictionary *out;
    @autoreleasepool {
        @try {
            NSData *data = [requestJSON dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *req = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![req isKindOfClass:[NSDictionary class]] || ![req[@"action"] isKindOfClass:[NSString class]]) fail(@"invalid_request", @"The request must be a JSON object with an action.");
            NSDictionary *args = [req[@"args"] isKindOfClass:[NSDictionary class]] ? req[@"args"] : @{};
            @synchronized(self) {
                out = @{ @"ok" : @YES, @"result" : [self dispatch:req[@"action"] args:args] };
            }
        } @catch (NSException *ex) {
            if ([ex.name isEqualToString:kFail]) {
                out = @{ @"ok" : @NO, @"error" : @{ @"code" : ex.userInfo[@"code"] ?: @"error", @"message" : ex.reason ?: @"" } };
            } else {
                out = @{ @"ok" : @NO, @"error" : @{ @"code" : @"notes_private_exception",
                    @"message" : [NSString stringWithFormat:@"NotesShared raised %@: %@. Apple may have changed the private API.", ex.name, ex.reason ?: @""] } };
            }
        }
    }
    NSData *json = [NSJSONSerialization isValidJSONObject:out] ? [NSJSONSerialization dataWithJSONObject:out options:0 error:nil] : nil;
    if (!json) json = [@"{\"ok\":false,\"error\":{\"code\":\"encode_failed\",\"message\":\"The result could not be encoded.\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

@end
