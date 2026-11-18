// The only file in iMCP that touches Apple's private ReminderKit framework.
//
// ReminderKit is not public API. Apple can change it in any macOS update, so this file:
//   - loads the framework lazily with dlopen, only when a private Reminders tool is first used;
//   - resolves every class by name at runtime (nothing links against the framework);
//   - checks every selector with respondsToSelector: before calling it, and fails with a
//     "reminderkit_changed" error that names the missing selector;
//   - catches every Objective-C exception, so none ever reaches Swift;
//   - never opens or writes the Reminders database. Writes go through REMSaveRequest, which asks
//     remindd to save, the same path Reminders.app uses.
//
// The interface is one class method taking and returning JSON text:
//   +[IMCPReminderKitBridge perform:]  {"action": "...", "args": {...}}
//   ->  {"ok": true, "result": {...}}  or  {"ok": false, "error": {"code": "...", "message": "..."}}
// Swift looks the class up by name, so the app target needs no bridging header.
//
// Behavior follows the documented behavior of viticci/remctl (MIT). No remctl code is used.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#if DEBUG
#import <EventKit/EventKit.h>
#endif

// Selector declarations only, so calls type-check. Each call site guards with `need`.
@interface NSObject (IMCPReminderKit)
- (id)fetchPrimaryActiveCloudKitAccountWithError:(NSError **)error;
- (NSArray *)fetchAccountsWithError:(NSError **)error;
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchTemplateWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchCustomSmartListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchReminderIncludingMarkedForDeleteWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListIncludingMarkedForDeleteWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionsWithListObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithReminderID:(id)reminderID error:(NSError **)error;
- (id)fetchRemindersWithParentReminderIDs:(id)ids error:(NSError **)error;
- (instancetype)initWithStore:(id)store;
- (id)updateAccount:(id)a;
- (id)updateList:(id)a;
- (id)updateReminder:(id)a;
- (id)updateSmartList:(id)a;
- (id)updateTemplate:(id)a;
- (id)updateListSection:(id)a;
- (id)addReminderWithTitle:(NSString *)t toListChangeItem:(id)l;
- (id)addReminderWithTitle:(NSString *)t toReminderSubtaskContextChangeItem:(id)c;
- (id)addListWithName:(NSString *)n toAccountChangeItem:(id)a listObjectID:(id)o;
- (id)addGroupWithName:(NSString *)n toAccountGroupContextChangeItem:(id)c groupObjectID:(id)o;
- (id)addListSectionWithDisplayName:(NSString *)n toListSectionContextChangeItem:(id)c;
- (id)addCustomSmartListWithName:(NSString *)n toAccountChangeItem:(id)a smartListObjectID:(id)o;
- (id)addTemplateWithName:(NSString *)n configuration:(id)c toAccountChangeItem:(id)a;
- (id)addListUsingTemplate:(id)t toAccountChangeItem:(id)a;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
- (id)remObjectID;
- (id)capabilities;
- (BOOL)supportsCustomSmartLists;
- (BOOL)supportsTemplates;
- (void)addListChangeItem:(id)l;
- (void)addSmartListChangeItem:(id)l;
- (id)groupContext;
- (id)templatesContext;
- (id)sublistContext;
- (NSArray *)fetchGroupsWithError:(NSError **)error;
- (NSArray *)fetchListsWithError:(NSError **)error;
- (NSArray *)fetchListsAndSublistsWithError:(NSError **)error;
- (NSArray *)fetchCustomSmartListsWithError:(NSError **)error;
- (NSArray *)fetchTemplatesWithError:(NSError **)error;
- (NSArray *)fetchRemindersWithError:(NSError **)error;
- (void)setParentOwnerID:(id)i;
- (id)parentOwnerID;
- (id)sectionsContextChangeItem;
- (id)appearanceContext;
- (void)setBadgeEmblem:(NSString *)e;
- (void)setBadge:(id)b;
- (void)setName:(NSString *)n;
- (void)setDisplayName:(NSString *)n;
- (void)setFilterData:(NSData *)d;
- (void)setSmartListType:(NSString *)t;
- (id)hashtagContext;
- (id)mutableHashtags;
- (NSArray *)hashtags;
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
- (void)removeHashtag:(id)h;
- (void)removeAllHashtags;
- (id)flaggedContext;
- (NSInteger)flagged;
- (void)setFlagged:(NSInteger)f;
- (id)urgentAlarmContext;
- (BOOL)isUrgentStateEnabledForCurrentUser;
- (void)setIsUrgentStateEnabledForCurrentUser:(BOOL)b;
- (id)subtaskContext;
- (void)addReminderChangeItem:(id)r;
- (void)removeFromParentReminder;
- (id)attachmentContext;
- (NSArray *)urlAttachments;
- (id)addURLAttachmentWithURL:(NSURL *)u;
- (void)setShouldUpdateSectionsOrdering:(BOOL)u;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)m;
- (void)setUnsavedSectionIDsOrdering:(NSArray *)o;
- (instancetype)initWithMemberIdentifier:(NSUUID *)m groupIdentifier:(NSUUID *)g isObsolete:(BOOL)o modifiedOn:(NSDate *)d;
- (instancetype)initWithMemberships:(NSArray *)m;
- (instancetype)initWithEmoji:(NSString *)e;
- (instancetype)initWithSourceListID:(id)i shouldSaveCompleted:(BOOL)s;
- (void)removeFromParentWithAccountChangeItem:(id)a;
- (void)removeFromParent;
- (void)removeFromParentAccount;
- (void)removeFromList;
- (void)undeleteReminderWithID:(id)i usingUndo:(id)u;
- (NSURL *)urlRepresentation;
- (NSUUID *)uuid;
- (NSString *)name;
- (NSString *)emblem;
- (NSString *)emoji;
- (id)badge;
- (id)parentReminder;
- (id)list;
+ (id)objectIDWithUUID:(NSUUID *)uuid;
@end

#pragma mark - Errors

static NSString *const kFail = @"IMCPRKFail";

__attribute__((noreturn)) static void fail(NSString *code, NSString *message) {
    @throw [NSException exceptionWithName:kFail reason:message userInfo:@{ @"code" : code }];
}

static NSString *errText(NSError *e) {
    if (!e) return @"no NSError";
    return [NSString stringWithFormat:@"%@ %ld: %@", e.domain, (long)e.code, e.localizedDescription];
}

/// Fails with a message that names the selector Apple removed or renamed.
static void need(id obj, SEL sel) {
    if (!obj) fail(@"reminderkit_changed", [NSString stringWithFormat:@"Expected an object for %@ but got nil", NSStringFromSelector(sel)]);
    if (![obj respondsToSelector:sel]) {
        fail(@"reminderkit_changed",
            [NSString stringWithFormat:@"ReminderKit no longer provides -[%@ %@]. Apple probably changed it in this macOS update.",
                NSStringFromClass([obj class]), NSStringFromSelector(sel)]);
    }
}

#define NEED(obj, sel) need((obj), @selector(sel))

#pragma mark - Loading

static Class cls(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) fail(@"reminderkit_changed", [NSString stringWithFormat:@"ReminderKit class %@ is missing", name]);
    return c;
}

static id gStore;

static id theStore(void) {
    if (gStore) return gStore;
    static dispatch_once_t once;
    static BOOL loaded;
    dispatch_once(&once, ^{
        void *h1 = dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW);
        void *h2 = dlopen("/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal", RTLD_NOW);
        loaded = (h1 != NULL);
        (void)h2;
    });
    if (!loaded) fail(@"reminderkit_unavailable", @"ReminderKit could not be loaded on this Mac.");
    gStore = [cls(@"REMStore") new];
    if (!gStore) fail(@"reminderkit_unavailable", @"REMStore could not be created.");
    return gStore;
}

static id newSave(void) {
    id s = [[cls(@"REMSaveRequest") alloc] initWithStore:theStore()];
    if (!s) fail(@"reminderkit_changed", @"REMSaveRequest could not be created.");
    return s;
}

static void commit(id save) {
    NEED(save, saveSynchronouslyWithError:);
    NSError *e = nil;
    if (![save saveSynchronouslyWithError:&e]) fail(@"save_failed", [@"Reminders refused the change: " stringByAppendingString:errText(e)]);
}

#pragma mark - Lookup helpers

static NSArray *accounts(void) {
    id store = theStore();
    NEED(store, fetchAccountsWithError:);
    NSError *e = nil;
    NSArray *a = [store fetchAccountsWithError:&e];
    if (!a) fail(@"store_unavailable", [@"Reminders data could not be read (is Reminders access granted?): " stringByAppendingString:errText(e)]);
    return a;
}

static id primaryAccount(void) {
    id store = theStore();
    NEED(store, fetchPrimaryActiveCloudKitAccountWithError:);
    NSError *e = nil;
    id a = [store fetchPrimaryActiveCloudKitAccountWithError:&e];
    if (!a) fail(@"no_icloud_account", [@"No active iCloud Reminders account: " stringByAppendingString:errText(e)]);
    return a;
}

static NSString *uuidString(id objectID) {
    if (!objectID) return nil;
    NEED(objectID, uuid);
    return [[objectID uuid] UUIDString];
}

static NSString *idOf(id obj) {
    NEED(obj, remObjectID);
    return uuidString([obj remObjectID]);
}

static id safeValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *ex) { return nil; }
}

static BOOL isGroup(id list) {
    id v = safeValue(list, @"isGroup");
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}

static NSString *nameOf(id obj) {
    for (NSString *k in @[ @"name", @"displayName", @"titleAsString", @"title" ]) {
        id v = safeValue(obj, k);
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return @"";
}

static id objectIDFor(NSString *className, NSString *uuidText) {
    NSUUID *u = uuidText.length ? [[NSUUID alloc] initWithUUIDString:uuidText] : nil;
    if (!u) fail(@"invalid_id", [NSString stringWithFormat:@"'%@' is not a valid identifier.", uuidText ?: @""]);
    Class c = cls(className);
    if (![c respondsToSelector:@selector(objectIDWithUUID:)]) fail(@"reminderkit_changed", [className stringByAppendingString:@" has no +objectIDWithUUID:"]);
    return [c objectIDWithUUID:u];
}

static id fetchReminder(NSString *uuidText) {
    id store = theStore();
    NEED(store, fetchReminderWithObjectID:error:);
    NSError *e = nil;
    id r = [store fetchReminderWithObjectID:objectIDFor(@"REMReminder", uuidText) error:&e];
    if (!r) fail(@"not_found", [NSString stringWithFormat:@"No reminder with id %@ (%@).", uuidText, e ? errText(e) : @"not found"]);
    return r;
}

/// Every list and group in every account, groups last.
static NSArray *allListsAndGroups(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (id account in accounts()) {
        NSArray *lists = nil;
        NSError *e = nil;
        if ([account respondsToSelector:@selector(fetchListsAndSublistsWithError:)]) lists = [account fetchListsAndSublistsWithError:&e];
        if (!lists && [account respondsToSelector:@selector(fetchListsWithError:)]) lists = [account fetchListsWithError:&e];
        if (lists) [out addObjectsFromArray:lists];
        id gctx = [account respondsToSelector:@selector(groupContext)] ? [account groupContext] : nil;
        if (gctx && [gctx respondsToSelector:@selector(fetchGroupsWithError:)]) {
            for (id g in [gctx fetchGroupsWithError:&e] ?: @[]) {
                BOOL known = NO;
                for (id x in out) if ([idOf(x) isEqual:idOf(g)]) { known = YES; break; }
                if (!known) [out addObject:g];
            }
        }
    }
    return out;
}

static id findContainer(NSDictionary *args, NSString *idKey, NSString *nameKey, BOOL wantGroup, NSString *noun) {
    NSString *wantID = args[idKey];
    NSString *wantName = args[nameKey];
    if (![wantID isKindOfClass:[NSString class]] && ![wantName isKindOfClass:[NSString class]]) {
        fail(@"invalid_arguments", [NSString stringWithFormat:@"Pass %@ (name) or %@ (identifier).", nameKey, idKey]);
    }
    NSMutableArray *matches = [NSMutableArray array];
    for (id l in allListsAndGroups()) {
        if (isGroup(l) != wantGroup) continue;
        if ([wantID isKindOfClass:[NSString class]]) {
            if ([[idOf(l) lowercaseString] isEqualToString:[wantID lowercaseString]]) return l;
            continue;
        }
        if ([nameOf(l) isEqualToString:wantName]) [matches addObject:l];
    }
    if ([wantID isKindOfClass:[NSString class]]) fail(@"not_found", [NSString stringWithFormat:@"No %@ with id %@.", noun, wantID]);
    if (matches.count == 0) {
        for (id l in allListsAndGroups()) {
            if (isGroup(l) == wantGroup && [nameOf(l) caseInsensitiveCompare:wantName] == NSOrderedSame) [matches addObject:l];
        }
    }
    if (matches.count == 0) fail(@"not_found", [NSString stringWithFormat:@"No %@ named '%@'.", noun, wantName]);
    if (matches.count > 1) {
        NSMutableArray *ids = [NSMutableArray array];
        for (id m in matches) [ids addObject:idOf(m)];
        fail(@"ambiguous", [NSString stringWithFormat:@"%lu %@s are named '%@'. Pass %@ with one of: %@", (unsigned long)matches.count, noun, wantName, idKey, [ids componentsJoinedByString:@", "]]);
    }
    return matches[0];
}

static id findList(NSDictionary *args) { return findContainer(args, @"list_id", @"list", NO, @"list"); }

#pragma mark - Reading

static NSArray *tagNames(id reminder) {
    id ctx = [reminder respondsToSelector:@selector(hashtagContext)] ? [reminder hashtagContext] : nil;
    NSMutableArray *names = [NSMutableArray array];
    for (id h in [ctx respondsToSelector:@selector(hashtags)] ? ([ctx hashtags] ?: @[]) : @[]) {
        NSString *n = safeValue(h, @"name");
        if (n.length) [names addObject:n];
    }
    return [names sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

static NSArray *linkURLs(id reminder) {
    id ctx = [reminder respondsToSelector:@selector(attachmentContext)] ? [reminder attachmentContext] : nil;
    NSMutableArray *urls = [NSMutableArray array];
    for (id a in [ctx respondsToSelector:@selector(urlAttachments)] ? ([ctx urlAttachments] ?: @[]) : @[]) {
        id u = safeValue(a, @"url");
        NSString *s = [u isKindOfClass:[NSURL class]] ? [u absoluteString] : ([u isKindOfClass:[NSString class]] ? u : nil);
        if (s) [urls addObject:s];
    }
    return urls;
}

static BOOL isFlagged(id reminder) {
    id ctx = [reminder respondsToSelector:@selector(flaggedContext)] ? [reminder flaggedContext] : nil;
    return [ctx respondsToSelector:@selector(flagged)] ? [ctx flagged] != 0 : NO;
}

static BOOL isUrgent(id reminder) {
    id ctx = [reminder respondsToSelector:@selector(urgentAlarmContext)] ? [reminder urgentAlarmContext] : nil;
    return [ctx respondsToSelector:@selector(isUrgentStateEnabledForCurrentUser)] ? [ctx isUrgentStateEnabledForCurrentUser] : NO;
}

static NSString *parentIDOf(id reminder) {
    id pid = safeValue(reminder, @"parentReminderID");
    if (pid) return uuidString(pid);
    id p = [reminder respondsToSelector:@selector(parentReminder)] ? [reminder parentReminder] : nil;
    return p ? idOf(p) : nil;
}

static NSString *listIDOfReminder(id reminder) {
    id lid = safeValue(reminder, @"listID");
    if (lid) return uuidString(lid);
    id l = [reminder respondsToSelector:@selector(list)] ? [reminder list] : nil;
    return l ? idOf(l) : nil;
}

static NSDictionary *sectionOf(id reminder) {
    id store = theStore();
    Class dv = NSClassFromString(@"REMListSectionsDataView");
    if (!dv) return nil;
    id view = [[dv alloc] initWithStore:store];
    if (![view respondsToSelector:@selector(fetchListSectionWithReminderID:error:)]) return nil;
    NSError *e = nil;
    id s = [view fetchListSectionWithReminderID:[reminder remObjectID] error:&e];
    if (!s) return nil;
    return @{ @"id" : idOf(s) ?: [NSNull null], @"name" : nameOf(s) };
}

static NSDictionary *reminderSummary(id r) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = idOf(r);
    d[@"title"] = nameOf(r);
    d[@"listId"] = listIDOfReminder(r) ?: [NSNull null];
    d[@"tags"] = tagNames(r);
    d[@"links"] = linkURLs(r);
    d[@"flagged"] = @(isFlagged(r));
    d[@"urgent"] = @(isUrgent(r));
    NSString *p = parentIDOf(r);
    d[@"parentId"] = p ?: [NSNull null];
    NSDictionary *s = sectionOf(r);
    d[@"section"] = s ?: [NSNull null];
    return d;
}

static NSArray *sectionsOfList(id list) {
    id store = theStore();
    NEED(store, fetchListSectionsWithListObjectID:error:);
    NSError *e = nil;
    NSArray *s = [store fetchListSectionsWithListObjectID:[list remObjectID] error:&e];
    if (!s) fail(@"read_failed", [@"Sections could not be read: " stringByAppendingString:errText(e)]);
    NSMutableArray *out = [NSMutableArray array];
    for (id sec in s) [out addObject:@{ @"id" : idOf(sec), @"name" : nameOf(sec) }];
    return out;
}

static id findSection(id list, NSDictionary *args, NSString *label) {
    NSString *sid = args[@"section_id"];
    NSString *sname = args[@"section"];
    id store = theStore();
    NEED(store, fetchListSectionsWithListObjectID:error:);
    NSError *e = nil;
    NSArray *all = [store fetchListSectionsWithListObjectID:[list remObjectID] error:&e] ?: @[];
    NSMutableArray *matches = [NSMutableArray array];
    for (id s in all) {
        if ([sid isKindOfClass:[NSString class]]) {
            if ([[idOf(s) lowercaseString] isEqualToString:[sid lowercaseString]]) return s;
        } else if ([sname isKindOfClass:[NSString class]] && [nameOf(s) caseInsensitiveCompare:sname] == NSOrderedSame) {
            [matches addObject:s];
        }
    }
    if ([sid isKindOfClass:[NSString class]]) fail(@"not_found", [NSString stringWithFormat:@"No section with id %@ in that list.", sid]);
    if (![sname isKindOfClass:[NSString class]]) fail(@"invalid_arguments", [NSString stringWithFormat:@"Pass %@ (name) or %@_id.", label, label]);
    if (matches.count == 0) fail(@"not_found", [NSString stringWithFormat:@"No section named '%@' in that list.", sname]);
    if (matches.count > 1) {
        NSMutableArray *ids = [NSMutableArray array];
        for (id m in matches) [ids addObject:idOf(m)];
        fail(@"ambiguous", [NSString stringWithFormat:@"%lu sections are named '%@'. Pass section_id with one of: %@", (unsigned long)matches.count, sname, [ids componentsJoinedByString:@", "]]);
    }
    return matches[0];
}

static NSDictionary *badgeInfo(id list) {
    id b = safeValue(list, @"badgeEmblem");
    if (!b) b = safeValue(list, @"badge");
    NSString *emblem = nil, *emoji = nil;
    if ([b isKindOfClass:[NSString class]]) {
        // Reminders stores an emoji badge as JSON text, {"Emoji" : "x"}; anything else is an emblem name.
        id parsed = [(NSString *)b hasPrefix:@"{"] ? [NSJSONSerialization JSONObjectWithData:[b dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]] && [parsed[@"Emoji"] isKindOfClass:[NSString class]]) emoji = parsed[@"Emoji"];
        else emblem = b;
    } else if (b) {
        id e1 = safeValue(b, @"emblem"), e2 = safeValue(b, @"emoji");
        if ([e1 isKindOfClass:[NSString class]]) emblem = e1;
        if ([e2 isKindOfClass:[NSString class]]) emoji = e2;
    }
    return @{ @"icon" : emblem ?: [NSNull null], @"emoji" : emoji ?: [NSNull null] };
}

static NSDictionary *listSummary(id l) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = idOf(l);
    d[@"name"] = nameOf(l);
    d[@"badge"] = badgeInfo(l);
    id pl = safeValue(l, @"parentListID");
    d[@"groupId"] = pl ? uuidString(pl) : [NSNull null];
    id pinned = safeValue(l, @"isPinned");
    d[@"pinned"] = @((BOOL)([pinned respondsToSelector:@selector(boolValue)] && [pinned boolValue]));
    return d;
}

static NSArray *childLists(id group) {
    id sub = [group respondsToSelector:@selector(sublistContext)] ? [group sublistContext] : nil;
    NSMutableArray *out = [NSMutableArray array];
    if (sub && [sub respondsToSelector:@selector(fetchListsWithError:)]) {
        NSError *e = nil;
        for (id c in [sub fetchListsWithError:&e] ?: @[]) [out addObject:@{ @"id" : idOf(c), @"name" : nameOf(c) }];
    }
    return out;
}

static NSDictionary *groupSummary(id g) {
    return @{ @"id" : idOf(g), @"name" : nameOf(g), @"lists" : childLists(g) };
}

static id decodeJSONData(id data) {
    if (![data isKindOfClass:[NSData class]]) return [NSNull null];
    id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return o ?: [NSNull null];
}

static NSDictionary *smartSummary(id s) {
    id pinned = safeValue(s, @"isPinned");
    return @{
        @"id" : idOf(s),
        @"name" : nameOf(s),
        @"filter" : decodeJSONData(safeValue(s, @"filterData")),
        @"badge" : badgeInfo(s),
        @"pinned" : @((BOOL)([pinned respondsToSelector:@selector(boolValue)] && [pinned boolValue])),
    };
}

static NSArray *customSmartLists(void) {
    id account = primaryAccount();
    NEED(account, fetchCustomSmartListsWithError:);
    NSError *e = nil;
    NSArray *a = [account fetchCustomSmartListsWithError:&e];
    if (!a) fail(@"read_failed", [@"Smart lists could not be read: " stringByAppendingString:errText(e)]);
    return a;
}

static NSArray *templates(void) {
    id account = primaryAccount();
    id ctx = [account respondsToSelector:@selector(templatesContext)] ? [account templatesContext] : nil;
    NEED(ctx, fetchTemplatesWithError:);
    NSError *e = nil;
    NSArray *a = [ctx fetchTemplatesWithError:&e];
    if (!a) fail(@"read_failed", [@"Templates could not be read: " stringByAppendingString:errText(e)]);
    return a;
}

#pragma mark - Reminder metadata actions

static NSString *cleanTag(NSString *raw) {
    NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([t hasPrefix:@"#"]) t = [t substringFromIndex:1];
    return t;
}

static NSSet *lowerSet(NSArray *a) {
    NSMutableSet *s = [NSMutableSet set];
    for (NSString *x in a) [s addObject:[x lowercaseString]];
    return s;
}

static NSDictionary *actionTags(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    NSArray *want = args[@"tags"] ?: @[];
    id reminder = fetchReminder(args[@"id"]);
    NSArray *before = tagNames(reminder);
    NSSet *beforeSet = lowerSet(before);
    NSMutableArray *wantClean = [NSMutableArray array];
    for (NSString *t in want) [wantClean addObject:cleanTag(t)];
    NSSet *wantSet = lowerSet(wantClean);

    id save = newSave();
    id change = [save updateReminder:reminder];
    id ctx = [change hashtagContext];
    NEED(ctx, addHashtagWithType:name:);
    NEED(ctx, hashtags);
    NEED(ctx, removeHashtag:);
    NEED(ctx, removeAllHashtags);
    if ([mode isEqualToString:@"clear"]) {
        [ctx removeAllHashtags];
    } else {
        if ([mode isEqualToString:@"add"] || [mode isEqualToString:@"set"]) {
            NSMutableSet *added = [NSMutableSet set];
            for (NSString *t in wantClean) {
                NSString *key = [t lowercaseString];
                if ([beforeSet containsObject:key] || [added containsObject:key]) continue;
                [added addObject:key];
                [ctx addHashtagWithType:1 name:t];
            }
        }
        if ([mode isEqualToString:@"set"] || [mode isEqualToString:@"remove"]) {
            for (id h in [ctx hashtags] ?: @[]) {
                NSString *n = safeValue(h, @"name");
                BOOL listed = [wantSet containsObject:[n lowercaseString]];
                if (([mode isEqualToString:@"remove"] && listed) || ([mode isEqualToString:@"set"] && !listed)) [ctx removeHashtag:h];
            }
        }
    }
    commit(save);

    NSArray *after = tagNames(fetchReminder(args[@"id"]));
    NSSet *afterSet = lowerSet(after);
    BOOL verified;
    if ([mode isEqualToString:@"clear"]) verified = afterSet.count == 0;
    else if ([mode isEqualToString:@"set"]) verified = [afterSet isEqualToSet:wantSet];
    else if ([mode isEqualToString:@"add"]) verified = [wantSet isSubsetOfSet:afterSet];
    else {
        NSMutableSet *left = [wantSet mutableCopy];
        [left intersectSet:afterSet];
        verified = left.count == 0;
    }
    return @{ @"id" : args[@"id"], @"tagsBefore" : before, @"tags" : after, @"verified" : @(verified) };
}

static NSDictionary *actionLinkAdd(NSDictionary *args) {
    NSString *urlText = args[@"url"];
    NSURL *url = [NSURL URLWithString:urlText];
    if (!url) fail(@"invalid_arguments", @"url is not a valid URL.");
    id reminder = fetchReminder(args[@"id"]);
    NSArray *before = linkURLs(reminder);
    id save = newSave();
    id change = [save updateReminder:reminder];
    id ctx = [change attachmentContext];
    NEED(ctx, addURLAttachmentWithURL:);
    [ctx addURLAttachmentWithURL:url];
    commit(save);
    NSArray *after = linkURLs(fetchReminder(args[@"id"]));
    BOOL verified = NO;
    for (NSString *u in after) if ([u isEqualToString:url.absoluteString]) verified = YES;
    return @{ @"id" : args[@"id"], @"linksBefore" : before, @"links" : after, @"verified" : @(verified) };
}

static NSDictionary *actionFlags(NSDictionary *args) {
    id reminder = fetchReminder(args[@"id"]);
    id save = newSave();
    id change = [save updateReminder:reminder];
    NSNumber *flagged = args[@"flagged"], *urgent = args[@"urgent"];
    if ([flagged isKindOfClass:[NSNumber class]]) {
        id ctx = [change flaggedContext];
        NEED(ctx, setFlagged:);
        [ctx setFlagged:[flagged boolValue] ? 1 : 0];
    }
    if ([urgent isKindOfClass:[NSNumber class]]) {
        id ctx = [change urgentAlarmContext];
        NEED(ctx, setIsUrgentStateEnabledForCurrentUser:);
        [ctx setIsUrgentStateEnabledForCurrentUser:[urgent boolValue]];
    }
    commit(save);
    id after = fetchReminder(args[@"id"]);
    BOOL ok = YES;
    if ([flagged isKindOfClass:[NSNumber class]]) ok = ok && (isFlagged(after) == [flagged boolValue]);
    if ([urgent isKindOfClass:[NSNumber class]]) ok = ok && (isUrgent(after) == [urgent boolValue]);
    return @{ @"id" : args[@"id"], @"flagged" : @(isFlagged(after)), @"urgent" : @(isUrgent(after)), @"verified" : @(ok) };
}

#pragma mark - Sections

static NSDictionary *actionSections(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    id store = theStore();
    if ([mode isEqualToString:@"assign"]) {
        id reminder = fetchReminder(args[@"id"]);
        NSString *listID = listIDOfReminder(reminder);
        if (!listID) fail(@"read_failed", @"The reminder's list could not be determined.");
        id list = [store fetchListWithObjectID:objectIDFor(@"REMList", listID) error:nil];
        if (!list) fail(@"not_found", @"The reminder's list could not be fetched.");
        id target = findSection(list, args, @"section");
        id save = newSave();
        id lc = [save updateList:list];
        id sctx = [lc sectionsContextChangeItem];
        NEED(sctx, setUnsavedMembershipsOfRemindersInSections:);
        NEED(sctx, setShouldUpdateSectionsOrdering:);
        NSUUID *member = [[reminder remObjectID] uuid];
        NSUUID *group = [[target remObjectID] uuid];
        id m = [[cls(@"REMMembership") alloc] initWithMemberIdentifier:member groupIdentifier:group isObsolete:NO modifiedOn:[NSDate date]];
        id ms = [[cls(@"REMMemberships") alloc] initWithMemberships:@[ m ]];
        [sctx setUnsavedMembershipsOfRemindersInSections:ms];
        [sctx setShouldUpdateSectionsOrdering:NO];
        commit(save);
        NSDictionary *after = sectionOf(fetchReminder(args[@"id"]));
        BOOL verified = [after[@"id"] isEqual:idOf(target)];
        return @{ @"id" : args[@"id"], @"section" : after ?: [NSNull null], @"verified" : @(verified) };
    }

    id list = findList(args);
    if ([mode isEqualToString:@"list"]) {
        return @{ @"list" : @{ @"id" : idOf(list), @"name" : nameOf(list) }, @"sections" : sectionsOfList(list) };
    }
    if ([mode isEqualToString:@"create"]) {
        NSString *name = args[@"name"];
        for (NSDictionary *s in sectionsOfList(list)) {
            if ([s[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) fail(@"duplicate", [NSString stringWithFormat:@"A section named '%@' already exists in that list.", name]);
        }
        id save = newSave();
        id lc = [save updateList:list];
        id sctx = [lc sectionsContextChangeItem];
        NEED(sctx, setUnsavedSectionIDsOrdering:);
        id sc = [save addListSectionWithDisplayName:name toListSectionContextChangeItem:sctx];
        if (!sc) fail(@"reminderkit_changed", @"addListSectionWithDisplayName returned nil");
        id newID = [sc remObjectID];
        NSMutableArray *order = [NSMutableArray array];
        for (id s in [store fetchListSectionsWithListObjectID:[list remObjectID] error:nil] ?: @[]) [order addObject:[s remObjectID]];
        [order addObject:newID];
        [sctx setUnsavedSectionIDsOrdering:order];
        [sctx setShouldUpdateSectionsOrdering:YES];
        commit(save);
        NSString *newUUID = uuidString(newID);
        BOOL verified = NO;
        for (NSDictionary *s in sectionsOfList(findList(@{ @"list_id" : idOf(list) }))) if ([s[@"id"] isEqual:newUUID]) verified = YES;
        return @{ @"sectionId" : newUUID, @"name" : name, @"verified" : @(verified) };
    }
    id section = findSection(list, args, @"section");
    NSString *sid = idOf(section);
    if ([mode isEqualToString:@"rename"]) {
        NSString *name = args[@"name"];
        id save = newSave();
        id sc = [save updateListSection:section];
        NEED(sc, setDisplayName:);
        [sc setDisplayName:name];
        commit(save);
        BOOL verified = NO;
        for (NSDictionary *s in sectionsOfList(list)) if ([s[@"id"] isEqual:sid] && [s[@"name"] isEqual:name]) verified = YES;
        return @{ @"sectionId" : sid, @"name" : name, @"verified" : @(verified) };
    }
    if ([mode isEqualToString:@"delete"]) {
        id save = newSave();
        id sc = [save updateListSection:section];
        NEED(sc, removeFromList);
        [sc removeFromList];
        commit(save);
        BOOL gone = YES;
        for (NSDictionary *s in sectionsOfList(list)) if ([s[@"id"] isEqual:sid]) gone = NO;
        return @{ @"sectionId" : sid, @"deleted" : @(gone), @"verified" : @(gone) };
    }
    fail(@"invalid_arguments", @"Unknown sections mode.");
    return nil;
}

#pragma mark - Subtasks

static BOOL hasSubtasks(id reminder) {
    id store = theStore();
    if (![store respondsToSelector:@selector(fetchRemindersWithParentReminderIDs:error:)]) return NO;
    id r = [store fetchRemindersWithParentReminderIDs:@[ [reminder remObjectID] ] error:nil];
    return [r respondsToSelector:@selector(count)] && [r count] > 0;
}

static NSDictionary *actionSubtasks(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    id store = theStore();
    if ([mode isEqualToString:@"create"]) {
        id parent = fetchReminder(args[@"parent_id"]);
        if (parentIDOf(parent)) fail(@"invalid_target", @"The parent is itself a subtask. Reminders allows one level of subtasks.");
        id save = newSave();
        id pc = [save updateReminder:parent];
        id ctx = [pc subtaskContext];
        NEED(ctx, addReminderChangeItem:);
        id sub = [save addReminderWithTitle:args[@"title"] toReminderSubtaskContextChangeItem:ctx];
        if (!sub) fail(@"reminderkit_changed", @"addReminderWithTitle returned nil");
        NSString *newID = uuidString([sub remObjectID]);
        commit(save);
        id after = fetchReminder(newID);
        BOOL verified = [parentIDOf(after) isEqualToString:[idOf(parent) uppercaseString]] || [[parentIDOf(after) lowercaseString] isEqualToString:[idOf(parent) lowercaseString]];
        return @{ @"id" : newID, @"parentId" : idOf(parent), @"title" : args[@"title"], @"verified" : @(verified) };
    }
    if ([mode isEqualToString:@"list"]) {
        id parent = fetchReminder(args[@"parent_id"]);
        NSMutableArray *out = [NSMutableArray array];
        id subs = [store fetchRemindersWithParentReminderIDs:@[ [parent remObjectID] ] error:nil];
        for (id s in ([subs isKindOfClass:[NSDictionary class]] ? [subs allValues] : subs) ?: @[]) {
            if ([s isKindOfClass:[NSArray class]]) { for (id x in s) [out addObject:@{ @"id" : idOf(x), @"title" : nameOf(x) }]; }
            else [out addObject:@{ @"id" : idOf(s), @"title" : nameOf(s) }];
        }
        return @{ @"parentId" : idOf(parent), @"subtasks" : out };
    }
    // move
    id child = fetchReminder(args[@"id"]);
    BOOL topLevel = [args[@"top_level"] boolValue];
    if (hasSubtasks(child)) fail(@"invalid_target", @"That reminder has subtasks of its own, and Reminders allows one level.");
    id save = newSave();
    id cc = [save updateReminder:child];
    if (topLevel) {
        if (!parentIDOf(child)) return @{ @"id" : args[@"id"], @"parentId" : [NSNull null], @"verified" : @YES, @"note" : @"The reminder was already top level." };
        NEED(cc, removeFromParentReminder);
        NSString *lid = listIDOfReminder(child);
        id list = [store fetchListWithObjectID:objectIDFor(@"REMList", lid) error:nil];
        if (!list) fail(@"not_found", @"The reminder's list could not be fetched.");
        id lc = [save updateList:list];
        NEED(lc, addReminderChangeItem:);
        [cc removeFromParentReminder];
        [lc addReminderChangeItem:cc];
    } else {
        id parent = fetchReminder(args[@"parent_id"]);
        if ([idOf(parent) caseInsensitiveCompare:idOf(child)] == NSOrderedSame) fail(@"invalid_target", @"A reminder cannot be its own parent.");
        if (parentIDOf(parent)) fail(@"invalid_target", @"The parent is itself a subtask.");
        if (![listIDOfReminder(parent) isEqualToString:listIDOfReminder(child)]) fail(@"invalid_target", @"The parent must be in the same list.");
        id pc = [save updateReminder:parent];
        id ctx = [pc subtaskContext];
        NEED(ctx, addReminderChangeItem:);
        [ctx addReminderChangeItem:cc];
    }
    commit(save);
    id after = fetchReminder(args[@"id"]);
    NSString *p = parentIDOf(after);
    BOOL verified = topLevel ? (p == nil) : (p && [p caseInsensitiveCompare:args[@"parent_id"]] == NSOrderedSame);
    return @{ @"id" : args[@"id"], @"parentId" : p ?: [NSNull null], @"verified" : @(verified) };
}

#pragma mark - Appearance

static NSDictionary *actionAppearance(NSDictionary *args) {
    id list = findList(args);
    NSString *icon = args[@"icon"], *emoji = args[@"emoji"];
    id save = newSave();
    id lc = [save updateList:list];
    id ap = [lc appearanceContext];
    if (icon) {
        NEED(ap, setBadgeEmblem:);
        [ap setBadgeEmblem:icon];
    } else {
        NEED(ap, setBadge:);
        id badge = [[cls(@"REMListBadge") alloc] initWithEmoji:emoji];
        if (!badge) fail(@"invalid_arguments", @"Reminders did not accept that emoji.");
        [ap setBadge:badge];
    }
    commit(save);
    id after = [theStore() fetchListWithObjectID:[list remObjectID] error:nil];
    NSDictionary *b = badgeInfo(after);
    BOOL verified = icon ? [b[@"icon"] isEqual:icon] : [b[@"emoji"] isEqual:emoji];
    return @{ @"list" : @{ @"id" : idOf(list), @"name" : nameOf(list) }, @"badge" : b, @"verified" : @(verified) };
}

#pragma mark - Groups

static NSDictionary *actionGroups(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    id store = theStore();
    if ([mode isEqualToString:@"list"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id l in allListsAndGroups()) if (isGroup(l)) [out addObject:groupSummary(l)];
        return @{ @"groups" : out };
    }
    id account = primaryAccount();
    if ([mode isEqualToString:@"create"]) {
        NSString *name = args[@"name"];
        for (id l in allListsAndGroups()) if (isGroup(l) && [nameOf(l) caseInsensitiveCompare:name] == NSOrderedSame) fail(@"duplicate", [NSString stringWithFormat:@"A group named '%@' already exists.", name]);
        NSMutableArray *members = [NSMutableArray array];
        for (NSString *ln in args[@"add_lists"] ?: @[]) [members addObject:findList(@{ @"list" : ln })];
        id save = newSave();
        id ac = [save updateAccount:account];
        NEED(ac, groupContext);
        id gctx = [ac groupContext];
        id g = [save addGroupWithName:name toAccountGroupContextChangeItem:gctx groupObjectID:nil];
        if (!g) fail(@"reminderkit_changed", @"addGroupWithName returned nil");
        [g setParentOwnerID:[account remObjectID]];
        NSString *gid = uuidString([g remObjectID]);
        id sub = [g sublistContext];
        for (id m in members) {
            id mc = [save updateList:m];
            [mc removeFromParentWithAccountChangeItem:ac];
            NEED(sub, addListChangeItem:);
            [sub addListChangeItem:mc];
        }
        commit(save);
        id after = findContainer(@{ @"list_id" : gid }, @"list_id", @"list", YES, @"group");
        NSArray *kids = childLists(after);
        BOOL verified = (kids.count == members.count);
        return @{ @"group" : groupSummary(after), @"verified" : @(verified) };
    }
    id group = findContainer(args, @"group_id", @"group", YES, @"group");
    if ([mode isEqualToString:@"rename"]) {
        NSString *name = args[@"name"];
        id save = newSave();
        id gc = [save updateList:group];
        NEED(gc, setName:);
        [gc setName:name];
        commit(save);
        id after = [store fetchListWithObjectID:[group remObjectID] error:nil];
        return @{ @"group" : groupSummary(after ?: group), @"verified" : @([nameOf(after) isEqual:name]) };
    }
    if ([mode isEqualToString:@"add_list"] || [mode isEqualToString:@"remove_list"]) {
        id list = findList(args);
        id save = newSave();
        id ac = [save updateAccount:account];
        id lc = [save updateList:list];
        [lc removeFromParentWithAccountChangeItem:ac];
        if ([mode isEqualToString:@"add_list"]) {
            id gc = [save updateList:group];
            id sub = [gc sublistContext];
            NEED(sub, addListChangeItem:);
            [sub addListChangeItem:lc];
        } else {
            [ac addListChangeItem:lc];
        }
        commit(save);
        BOOL inGroup = NO;
        for (NSDictionary *c in childLists([store fetchListWithObjectID:[group remObjectID] error:nil] ?: group)) if ([c[@"id"] isEqual:idOf(list)]) inGroup = YES;
        BOOL verified = [mode isEqualToString:@"add_list"] ? inGroup : !inGroup;
        return @{ @"group" : groupSummary([store fetchListWithObjectID:[group remObjectID] error:nil] ?: group), @"verified" : @(verified) };
    }
    if ([mode isEqualToString:@"delete"]) {
        id save = newSave();
        id ac = [save updateAccount:account];
        for (id child in [[group sublistContext] fetchListsWithError:nil] ?: @[]) {
            id cc = [save updateList:child];
            [cc removeFromParentWithAccountChangeItem:ac];
            [ac addListChangeItem:cc];
        }
        id gc = [save updateList:group];
        [gc removeFromParentWithAccountChangeItem:ac];
        commit(save);
        BOOL gone = YES;
        for (id l in allListsAndGroups()) if ([idOf(l) isEqual:idOf(group)]) gone = NO;
        return @{ @"deleted" : @(gone), @"verified" : @(gone), @"note" : @"Child lists were moved to the top level." };
    }
    fail(@"invalid_arguments", @"Unknown groups mode.");
    return nil;
}

#pragma mark - Smart lists

static NSDictionary *actionSmartLists(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    if ([mode isEqualToString:@"list"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id s in customSmartLists()) [out addObject:smartSummary(s)];
        return @{ @"smartLists" : out };
    }
    id account = primaryAccount();
    if ([mode isEqualToString:@"create"]) {
        NSString *name = args[@"name"];
        for (id s in customSmartLists()) if ([nameOf(s) caseInsensitiveCompare:name] == NSOrderedSame) fail(@"duplicate", [NSString stringWithFormat:@"A smart list named '%@' already exists.", name]);
        id caps = [account capabilities];
        if (![caps respondsToSelector:@selector(supportsCustomSmartLists)] || ![caps supportsCustomSmartLists]) fail(@"unsupported", @"The active account does not support custom smart lists.");
        NSData *filter = [NSJSONSerialization dataWithJSONObject:args[@"filter"] options:0 error:nil];
        if (!filter) fail(@"invalid_arguments", @"filter is not valid JSON.");
        id save = newSave();
        id ac = [save updateAccount:account];
        id sl = [save addCustomSmartListWithName:name toAccountChangeItem:ac smartListObjectID:nil];
        if (!sl) fail(@"reminderkit_changed", @"addCustomSmartListWithName returned nil");
        [sl setParentOwnerID:[account remObjectID]];
        [ac addSmartListChangeItem:sl];
        @try {
            [sl setValue:@(20220430) forKey:@"minimumSupportedVersion"];
            [sl setValue:@(20220430) forKey:@"effectiveMinimumSupportedVersion"];
        } @catch (NSException *ex) { /* optional metadata */ }
        NEED(sl, setSmartListType:);
        NEED(sl, setFilterData:);
        [sl setSmartListType:@"com.apple.reminders.smartlist.custom"];
        [sl setFilterData:filter];
        NSString *sid = uuidString([sl remObjectID]);
        commit(save);
        BOOL found = NO;
        id got = nil;
        for (id s in customSmartLists()) if ([idOf(s) isEqual:sid]) { found = YES; got = s; }
        BOOL verified = found && [decodeJSONData(safeValue(got, @"filterData")) isEqual:args[@"filter"]];
        return @{ @"smartList" : found ? smartSummary(got) : [NSNull null], @"verified" : @(verified) };
    }
    if ([mode isEqualToString:@"delete"]) {
        id target = nil;
        NSMutableArray *matches = [NSMutableArray array];
        for (id s in customSmartLists()) {
            if (args[@"smart_list_id"]) { if ([idOf(s) caseInsensitiveCompare:args[@"smart_list_id"]] == NSOrderedSame) target = s; }
            else if ([nameOf(s) isEqualToString:args[@"smart_list"]]) [matches addObject:s];
        }
        if (!target && matches.count == 1) target = matches[0];
        if (matches.count > 1) fail(@"ambiguous", @"More than one smart list has that name. Pass smart_list_id.");
        if (!target) fail(@"not_found", @"No custom smart list matches. Built-in smart lists are never deleted.");
        NSString *sid = idOf(target);
        id save = newSave();
        id ac = [save updateAccount:account];
        id sc = [save updateSmartList:target];
        NEED(sc, removeFromParentWithAccountChangeItem:);
        [sc removeFromParentWithAccountChangeItem:ac];
        commit(save);
        BOOL gone = YES;
        for (id s in customSmartLists()) if ([idOf(s) isEqual:sid]) gone = NO;
        return @{ @"deletedId" : sid, @"verified" : @(gone) };
    }
    fail(@"invalid_arguments", @"Unknown smart_lists mode.");
    return nil;
}

#pragma mark - Templates

static NSDictionary *templateSummary(id t) {
    return @{ @"id" : idOf(t), @"name" : nameOf(t), @"badge" : badgeInfo(t) };
}

static NSDictionary *actionTemplates(NSDictionary *args) {
    NSString *mode = args[@"mode"];
    id store = theStore();
    if ([mode isEqualToString:@"list"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id t in templates()) [out addObject:templateSummary(t)];
        return @{ @"templates" : out };
    }
    id account = primaryAccount();
    id caps = [account capabilities];
    if ([caps respondsToSelector:@selector(supportsTemplates)] && ![caps supportsTemplates]) fail(@"unsupported", @"The active account does not support templates.");
    if ([mode isEqualToString:@"create"]) {
        NSString *name = args[@"name"];
        for (id t in templates()) if ([nameOf(t) caseInsensitiveCompare:name] == NSOrderedSame) fail(@"duplicate", [NSString stringWithFormat:@"A template named '%@' already exists.", name]);
        id list = findList(args);
        id save = newSave();
        id ac = [save updateAccount:account];
        id cfg = [[cls(@"REMTemplateConfiguration") alloc] initWithSourceListID:[list remObjectID] shouldSaveCompleted:[args[@"include_completed"] boolValue]];
        id t = [save addTemplateWithName:name configuration:cfg toAccountChangeItem:ac];
        if (!t) fail(@"reminderkit_changed", @"addTemplateWithName returned nil");
        NSString *tid = uuidString([t remObjectID]);
        commit(save);
        id got = nil;
        for (id x in templates()) if ([idOf(x) isEqual:tid]) got = x;
        return @{ @"template" : got ? templateSummary(got) : [NSNull null], @"verified" : @(got != nil) };
    }
    id target = nil;
    NSMutableArray *matches = [NSMutableArray array];
    for (id t in templates()) {
        if (args[@"template_id"]) { if ([idOf(t) caseInsensitiveCompare:args[@"template_id"]] == NSOrderedSame) target = t; }
        else if ([nameOf(t) caseInsensitiveCompare:args[@"template"]] == NSOrderedSame) [matches addObject:t];
    }
    if (!target && matches.count == 1) target = matches[0];
    if (matches.count > 1) fail(@"ambiguous", @"More than one template has that name. Pass template_id.");
    if (!target) fail(@"not_found", @"No template matches.");
    if ([mode isEqualToString:@"apply"]) {
        NSMutableSet *before = [NSMutableSet set];
        for (id l in allListsAndGroups()) [before addObject:idOf(l)];
        id save = newSave();
        id ac = [save updateAccount:account];
        NEED(save, addListUsingTemplate:toAccountChangeItem:);
        id nl = [save addListUsingTemplate:target toAccountChangeItem:ac];
        if (!nl) fail(@"reminderkit_changed", @"addListUsingTemplate returned nil");
        commit(save);
        NSMutableArray *created = [NSMutableArray array];
        for (id l in allListsAndGroups()) if (![before containsObject:idOf(l)]) [created addObject:listSummary(l)];
        return @{ @"createdLists" : created, @"verified" : @((BOOL)(created.count == 1)) };
    }
    if ([mode isEqualToString:@"delete"]) {
        NSString *tid = idOf(target);
        id save = newSave();
        id tc = [save updateTemplate:target];
        NEED(tc, removeFromParentAccount);
        [tc removeFromParentAccount];
        commit(save);
        BOOL gone = YES;
        for (id t in templates()) if ([idOf(t) isEqual:tid]) gone = NO;
        (void)store;
        return @{ @"deletedId" : tid, @"verified" : @(gone) };
    }
    fail(@"invalid_arguments", @"Unknown templates mode.");
    return nil;
}

#pragma mark - Restore

static NSDictionary *actionRestore(NSDictionary *args) {
    id store = theStore();
    NEED(store, fetchReminderIncludingMarkedForDeleteWithObjectID:error:);
    NSError *e = nil;
    id oid = objectIDFor(@"REMReminder", args[@"id"]);
    id r = [store fetchReminderIncludingMarkedForDeleteWithObjectID:oid error:&e];
    if (!r) fail(@"not_found", @"No deleted reminder with that id is still recoverable.");
    // A deleted reminder no longer says which list it came from, so the caller names the list
    // unless ReminderKit still knows it.
    id list = nil;
    if (args[@"list"] || args[@"list_id"]) list = findList(args);
    else {
        NSString *lid = listIDOfReminder(r);
        if (!lid) fail(@"list_required", @"ReminderKit no longer records which list that reminder came from. Pass list or list_id to say where to restore it.");
        list = [store fetchListWithObjectID:objectIDFor(@"REMList", lid) error:nil];
    }
    if (!list) fail(@"not_found", @"The list to restore into could not be fetched.");
    id save = newSave();
    id lc = [save updateList:list];
    NEED(lc, undeleteReminderWithID:usingUndo:);
    [lc undeleteReminderWithID:oid usingUndo:nil];
    commit(save);
    NSError *e2 = nil;
    id after = [store fetchReminderWithObjectID:oid error:&e2];
    return @{ @"id" : args[@"id"], @"restored" : @(after != nil), @"verified" : @(after != nil), @"reminder" : after ? reminderSummary(after) : [NSNull null] };
}

#pragma mark - Status

static NSDictionary *actionStatus(NSDictionary *args) {
    theStore();
    NSDictionary *classes = @{
        @"store" : @"REMStore", @"saveRequest" : @"REMSaveRequest", @"hashtags" : @"REMReminderHashtagContextChangeItem",
        @"flags" : @"REMReminderFlaggedContextChangeItem", @"urgent" : @"REMReminderUrgentAlarmContextChangeItem",
        @"links" : @"REMReminderAttachmentContextChangeItem", @"subtasks" : @"REMReminderSubtaskContextChangeItem",
        @"sections" : @"REMListSectionContextChangeItem", @"appearance" : @"REMListAppearanceContextChangeItem",
        @"badge" : @"REMListBadge", @"smartLists" : @"REMSmartListChangeItem", @"templates" : @"REMTemplateConfiguration",
    };
    NSMutableDictionary *present = [NSMutableDictionary dictionary];
    for (NSString *k in classes) present[k] = @(NSClassFromString(classes[k]) != nil);
    return @{ @"loaded" : @YES, @"os" : [NSProcessInfo processInfo].operatingSystemVersionString, @"classes" : present };
}

#pragma mark - DEBUG helpers for the self-test only

#if DEBUG
static NSDictionary *actionDebug(NSString *action, NSDictionary *args) {
    id store = theStore();
    if ([action isEqualToString:@"debug.accounts"] || [action isEqualToString:@"debug.eventkit_has_reminder"]) goto skipAccount;
    skipAccount:;
    id account = [action isEqualToString:@"debug.accounts"] ? nil : primaryAccount();
    if ([action isEqualToString:@"debug.create_list"]) {
        id save = newSave();
        id ac = [save updateAccount:account];
        id change = [save addListWithName:args[@"name"] toAccountChangeItem:ac listObjectID:nil];
        [change setParentOwnerID:[account remObjectID]];
        [ac addListChangeItem:change];
        commit(save);
        return @{ @"id" : uuidString([change remObjectID]) };
    }
    if ([action isEqualToString:@"debug.create_reminder"]) {
        id list = [store fetchListWithObjectID:objectIDFor(@"REMList", args[@"list_id"]) error:nil];
        id save = newSave();
        id lc = [save updateList:list];
        id rc = [save addReminderWithTitle:args[@"title"] toListChangeItem:lc];
        NSString *rid = uuidString([rc remObjectID]);
        commit(save);
        return @{ @"id" : rid };
    }
    if ([action isEqualToString:@"debug.delete_reminder"]) {
        // Delete the way iMCP's own reminders_delete does: through EventKit, which sends it to Recently Deleted.
        EKEventStore *es = [EKEventStore new];
        EKReminder *item = (EKReminder *)[es calendarItemWithIdentifier:args[@"id"]];
        if (!item) fail(@"not_found", @"EventKit does not know that reminder.");
        NSError *e = nil;
        if (![es removeReminder:item commit:YES error:&e]) fail(@"delete_failed", errText(e));
        return @{};
    }
    if ([action isEqualToString:@"debug.delete_list"]) {
        id l = [store fetchListWithObjectID:objectIDFor(@"REMList", args[@"list_id"]) error:nil];
        if (!l) return @{ @"gone" : @YES };
        id save = newSave();
        id ac = [save updateAccount:account];
        id c = [save updateList:l];
        [c removeFromParentWithAccountChangeItem:ac];
        commit(save);
        return @{ @"gone" : @YES };
    }
    if ([action isEqualToString:@"debug.leftovers"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id l in allListsAndGroups()) if ([nameOf(l) hasPrefix:@"iMCP test"]) [out addObject:@{ @"kind" : isGroup(l) ? @"group" : @"list", @"name" : nameOf(l), @"id" : idOf(l) }];
        for (id l in customSmartLists()) if ([nameOf(l) hasPrefix:@"iMCP test"]) [out addObject:@{ @"kind" : @"smart", @"name" : nameOf(l), @"id" : idOf(l) }];
        for (id l in templates()) if ([nameOf(l) hasPrefix:@"iMCP test"]) [out addObject:@{ @"kind" : @"template", @"name" : nameOf(l), @"id" : idOf(l) }];
        return @{ @"leftovers" : out };
    }
    if ([action isEqualToString:@"debug.accounts"]) {
        NSMutableArray *out = [NSMutableArray array];
        NSError *e = nil;
        NSArray *all = [store fetchAccountsWithError:&e];
        for (id a in all ?: @[]) [out addObject:@{ @"id" : idOf(a), @"type" : [NSString stringWithFormat:@"%@", safeValue(a, @"type") ?: @"?"], @"name" : nameOf(a), @"inactive" : [NSString stringWithFormat:@"%@", safeValue(a, @"inactive") ?: @"?"] }];
        NSError *e2 = nil;
        id prim = [store fetchPrimaryActiveCloudKitAccountWithError:&e2];
        return @{ @"auth" : @([EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder]), @"accounts" : out, @"accountsErr" : e ? errText(e) : [NSNull null], @"primary" : prim ? idOf(prim) : [NSNull null], @"primaryErr" : e2 ? errText(e2) : [NSNull null] };
    }
    if ([action isEqualToString:@"debug.describe_deleted"]) {
        id r = [store fetchReminderIncludingMarkedForDeleteWithObjectID:objectIDFor(@"REMReminder", args[@"id"]) error:nil];
        id st = safeValue(r, @"storage");
        return @{ @"found" : @(r != nil), @"class" : r ? NSStringFromClass([r class]) : @"", @"desc" : [r description] ?: @"", @"listID" : [NSString stringWithFormat:@"%@", safeValue(st, @"listID")], @"listKey" : [NSString stringWithFormat:@"%@", safeValue(r, @"listID")], @"list" : [NSString stringWithFormat:@"%@", safeValue(r, @"list")] };
    }
    if ([action isEqualToString:@"debug.eventkit_has_reminder"]) {
        EKEventStore *es = [EKEventStore new];
        EKCalendarItem *item = [es calendarItemWithIdentifier:args[@"id"]];
        return @{ @"found" : @(item != nil), @"title" : item.title ?: [NSNull null] };
    }
    fail(@"unknown_action", action);
    return nil;
}
#endif

#pragma mark - Entry point

@interface IMCPReminderKitBridge : NSObject
+ (NSString *)perform:(NSString *)requestJSON;
@end

@implementation IMCPReminderKitBridge

+ (NSDictionary *)dispatch:(NSString *)action args:(NSDictionary *)args {
    if ([action isEqualToString:@"status"]) return actionStatus(args);
    if ([action isEqualToString:@"reminder.info"]) return reminderSummary(fetchReminder(args[@"id"]));
    if ([action isEqualToString:@"tags"]) return actionTags(args);
    if ([action isEqualToString:@"tags.list"]) {
        id list = findList(args);
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        NEED(list, fetchRemindersWithError:);
        for (id r in [list fetchRemindersWithError:nil] ?: @[]) for (NSString *t in tagNames(r)) counts[t] = @([counts[t] integerValue] + 1);
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *k in [counts.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) [out addObject:@{ @"tag" : k, @"reminders" : counts[k] }];
        return @{ @"list" : @{ @"id" : idOf(list), @"name" : nameOf(list) }, @"tags" : out };
    }
    if ([action isEqualToString:@"link.add"]) return actionLinkAdd(args);
    if ([action isEqualToString:@"flags"]) return actionFlags(args);
    if ([action isEqualToString:@"sections"]) return actionSections(args);
    if ([action isEqualToString:@"subtasks"]) return actionSubtasks(args);
    if ([action isEqualToString:@"appearance"]) return actionAppearance(args);
    if ([action isEqualToString:@"groups"]) return actionGroups(args);
    if ([action isEqualToString:@"smart_lists"]) return actionSmartLists(args);
    if ([action isEqualToString:@"templates"]) return actionTemplates(args);
    if ([action isEqualToString:@"restore"]) return actionRestore(args);
#if DEBUG
    if ([action hasPrefix:@"debug."]) return actionDebug(action, args);
#endif
    fail(@"unknown_action", [NSString stringWithFormat:@"Unknown private Reminders action '%@'.", action]);
    return nil;
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
                out = @{ @"ok" : @NO, @"error" : @{ @"code" : @"reminderkit_exception",
                    @"message" : [NSString stringWithFormat:@"ReminderKit raised %@: %@. Apple may have changed the private API.", ex.name, ex.reason ?: @""] } };
            }
        }
    }
    NSData *json = [NSJSONSerialization isValidJSONObject:out] ? [NSJSONSerialization dataWithJSONObject:out options:0 error:nil] : nil;
    if (!json) json = [@"{\"ok\":false,\"error\":{\"code\":\"encode_failed\",\"message\":\"The result could not be encoded.\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

@end
