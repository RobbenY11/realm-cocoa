////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMTestCase.h"

#import "RLMRealmConfiguration_Private.h"

@interface NotificationTests : RLMTestCase
@property (nonatomic, strong) RLMNotificationToken *token;
@property (nonatomic) bool called;
@end

@implementation NotificationTests
- (void)setUp {
    @autoreleasepool {
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            for (int i = 0; i < 10; ++i)
                [IntObject createInDefaultRealmWithValue:@[@(i)]];
        }];
    }

    _token = [self.query addNotificationBlock:^(RLMResults *results, NSError *error) {
        XCTAssertNotNil(results);
        XCTAssertNil(error);
        self.called = true;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }];
    CFRunLoopRun();
}

- (void)tearDown {
    [_token stop];
    [super tearDown];
}

- (RLMResults *)query {
    return [IntObject objectsWhere:@"intCol > 0 AND intCol < 5"];
}

- (void)runAndWaitForNotification:(void (^)(RLMRealm *))block {
    _called = false;
    [self waitForNotification:RLMRealmDidChangeNotification realm:RLMRealm.defaultRealm block:^{
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            block(realm);
        }];
    }];
}

- (void)expectNotification:(void (^)(RLMRealm *))block {
    [self runAndWaitForNotification:block];
    XCTAssertTrue(_called);
}

- (void)expectNoNotification:(void (^)(RLMRealm *))block {
    [self runAndWaitForNotification:block];
    XCTAssertFalse(_called);
}

- (void)testInsertObjectMatchingQuery {
    [self expectNotification:^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@3]];
    }];
}

- (void)testInsertObjectNotMatchingQuery {
    [self expectNoNotification:^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@10]];
    }];
}

- (void)testModifyObjectMatchingQuery {
    [self expectNotification:^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@4 forKey:@"intCol"];
    }];
}

- (void)testModifyObjectToNoLongerMatchQuery {
    [self expectNotification:^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@5 forKey:@"intCol"];
    }];
}

- (void)testModifyObjectNotMatchingQuery {
    [self expectNoNotification:^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@6 forKey:@"intCol"];
    }];
}

- (void)testModifyObjectToMatchQuery {
    [self expectNotification:^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@4 forKey:@"intCol"];
    }];
}

- (void)testDeleteObjectMatchingQuery {
    [self expectNotification:^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
    }];
}

- (void)testDeleteObjectNotMatchingQuery {
    [self expectNoNotification:^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 5"]];
    }];
    [self expectNoNotification:^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    }];
}

- (void)testNonMatchingObjectMovedToIndexOfMatchingRowAndMadeMatching {
    [self expectNotification:^(RLMRealm *realm) {
        // Make the last object match the query
        [[[IntObject allObjectsInRealm:realm] lastObject] setIntCol:3];
        // Move the now-matching object over a previously matching object
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
    }];
}
@end

@interface SortedNotificationTests : NotificationTests
@end
@implementation SortedNotificationTests
- (RLMResults *)query {
    return [[IntObject objectsWhere:@"intCol > 0 AND intCol < 5"] sortedResultsUsingProperty:@"intCol" ascending:NO];
}

- (void)testMoveMatchingObjectDueToDeletionOfNonMatchingObject {
    [self expectNoNotification:^(RLMRealm *realm) {
        // Make a matching object be the last row
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol >= 5"]];
        // Delete a non-last, non-match row so that a matched row is moved
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    }];
}

- (void)testMultipleMovesOfSingleRow {
    [self expectNotification:^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject allObjectsInRealm:realm]];
        [IntObject createInRealm:realm withValue:@[@10]];
        [IntObject createInRealm:realm withValue:@[@10]];
        [IntObject createInRealm:realm withValue:@[@3]];
    }];

    [self expectNoNotification:^(RLMRealm *realm) {
        RLMResults *objects = [IntObject allObjectsInRealm:realm];
        [realm deleteObject:objects[1]];
        [realm deleteObject:objects[0]];
    }];
}
@end

@protocol ChangesetTestCase
- (RLMResults *)query;
- (void)prepare;
@end

#if !TARGET_OS_WATCH && !TARGET_OS_TV && !TARGET_OS_IPHONE
@interface NSIndexPath (UITableView)
@property (nonatomic, readonly) NSInteger row;
@end

@implementation NSIndexPath (UITableView)
- (NSInteger)row {
    return [self indexAtPosition:1];
}
@end
#endif

static RLMCollectionChange *getChange(RLMTestCase<ChangesetTestCase> *self, void (^block)(RLMRealm *)) {
    [self prepare];

    __block bool first = true;
    RLMResults *query = [self query];
    __block RLMCollectionChange *changes;
    id token = [query addNotificationBlockWithChanges:^(RLMResults *results,
                                                        RLMCollectionChange *c,
                                                        NSError *error) {
        XCTAssertNotNil(results);
        XCTAssertNil(error);
        changes = c;
        XCTAssertTrue(first || changes);
        first = false;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }];
    CFRunLoopRun();

    [self waitForNotification:RLMRealmDidChangeNotification realm:RLMRealm.defaultRealm block:^{
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            block(realm);
        }];
    }];

    [token stop];
    token = nil;

    return changes;
}

static void ExpectChange(id self, NSArray *deletions, NSArray *insertions, NSArray *modifications, void (^block)(RLMRealm *)) {
    RLMCollectionChange *changes = getChange(self, block);
    XCTAssertNotNil(changes);
    if (!changes) {
        return;
    }

    XCTAssertEqualObjects(deletions, [changes.deletions valueForKey:@"row"]);
    XCTAssertEqualObjects(insertions, [changes.insertions valueForKey:@"row"]);
    XCTAssertEqualObjects(modifications, [changes.modifications valueForKey:@"row"]);
}

#define ExpectNoChange(self, block) XCTAssertNil(getChange((self), (block)))

@interface ChangesetTests : RLMTestCase <ChangesetTestCase>
@end

@implementation ChangesetTests
 - (void)prepare {
    @autoreleasepool {
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            [realm deleteAllObjects];
            for (int i = 0; i < 10; ++i) {
                IntObject *io = [IntObject createInDefaultRealmWithValue:@[@(i)]];
                [ArrayPropertyObject createInDefaultRealmWithValue:@[@"", @[], @[io]]];
            }
        }];
    }
 }

- (RLMResults *)query {
    return [IntObject objectsWhere:@"intCol > 0 AND intCol < 5"];
}

- (void)testDeleteMultiple {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 4"]];
    });
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 4"]];
    });
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 5"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });

    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 1"]];
    });
    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 3"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
    });
    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 3"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
    });

    ExpectChange(self, @[@3], @[@0], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 4"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol < 1"]];
    });
}

- (void)testDeleteNewlyInsertedRowMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@3]];
        [realm deleteObject:[IntObject allObjectsInRealm:realm].lastObject];
    });
}

- (void)testInsertObjectMatchingQuery {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@3]];
    });
}

- (void)testInsertObjectNotMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@5]];
    });
}

- (void)testInsertBothMatchingAndNonMatching {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@5]];
        [IntObject createInRealm:realm withValue:@[@3]];
    });
}

- (void)testInsertMultipleMatching {
    ExpectChange(self, @[], @[@4, @5], @[], ^(RLMRealm *realm) {
        [IntObject createInRealm:realm withValue:@[@5]];
        [IntObject createInRealm:realm withValue:@[@3]];
        [IntObject createInRealm:realm withValue:@[@5]];
        [IntObject createInRealm:realm withValue:@[@2]];
    });
}

- (void)testModifyObjectMatchingQuery {
    ExpectChange(self, @[], @[], @[@2], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@4 forKey:@"intCol"];
    });
}

- (void)testModifyObjectToNoLongerMatchQuery {
    ExpectChange(self, @[@2], @[], @[], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@5 forKey:@"intCol"];
    });
}

- (void)testModifyObjectNotMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@6 forKey:@"intCol"];
    });
}

- (void)testModifyObjectToMatchQuery {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@4 forKey:@"intCol"];
    });
}

- (void)testDeleteObjectMatchingQuery {
    ExpectChange(self, @[@0], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 1"]];
    });
    ExpectChange(self, @[@3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
    });
}

- (void)testDeleteNonMatchingBeforeMatches {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });
}

- (void)testDeleteNonMatchingAfterMatches {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 5"]];
    });
}

- (void)testMoveMatchingObjectDueToDeletionOfNonMatchingObject {
    ExpectChange(self, @[@3], @[@0], @[], ^(RLMRealm *realm) {
        // Make a matching object be the last row
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol >= 5"]];
        // Delete a non-last, non-match row so that a matched row is moved
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });
}

- (void)testNonMatchingObjectMovedToIndexOfMatchingRowAndMadeMatching {
    ExpectChange(self, @[@1], @[@1], @[], ^(RLMRealm *realm) {
        // Make the last object match the query
        [[[IntObject allObjectsInRealm:realm] lastObject] setIntCol:3];
        // Move the now-matching object over a previously matching object
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
    });
}

@end

@interface LinkViewChangesetTests : RLMTestCase <ChangesetTestCase>
@end

@implementation LinkViewChangesetTests
- (void)prepare {
    @autoreleasepool {
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm transactionWithBlock:^{
            [realm deleteAllObjects];
            for (int i = 0; i < 10; ++i) {
                [IntObject createInDefaultRealmWithValue:@[@(i)]];
            }
            [ArrayPropertyObject createInDefaultRealmWithValue:@[@"", @[], [IntObject allObjectsInRealm:realm]]];
        }];
    }
}

- (RLMResults *)query {
    return [[[ArrayPropertyObject.allObjects firstObject] intArray]
            objectsWhere:@"intCol > 0 AND intCol < 5"];
}

- (void)testDeleteMultiple {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 4"]];
    });
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 5"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });

    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 1"]];
    });
    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 3"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
    });
    ExpectChange(self, @[@1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 3"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
    });

    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol > 4"]];
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol < 1"]];
    });
}

- (void)testModifyObjectMatchingQuery {
    ExpectChange(self, @[], @[], @[@2], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@4 forKey:@"intCol"];
    });
}

- (void)testModifyObjectToNoLongerMatchQuery {
    ExpectChange(self, @[@2], @[], @[], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 3"] setValue:@5 forKey:@"intCol"];
    });
}

- (void)testModifyObjectNotMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@6 forKey:@"intCol"];
    });
}

- (void)testModifyObjectToMatchQuery {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        [[IntObject objectsInRealm:realm where:@"intCol = 5"] setValue:@4 forKey:@"intCol"];
    });
}

- (void)testDeleteObjectMatchingQuery {
    ExpectChange(self, @[@0], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 1"]];
    });
    ExpectChange(self, @[@3], @[], @[], ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 4"]];
    });
}

- (void)testDeleteNonMatchingBeforeMatches {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });
}

- (void)testDeleteNonMatchingAfterMatches {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 5"]];
    });
}

- (void)testMoveMatchingObjectDueToDeletionOfNonMatchingObject {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        // Make a matching object be the last row
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol >= 5"]];
        // Delete a non-last, non-match row so that a matched row is moved
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 0"]];
    });
}

- (void)testNonMatchingObjectMovedToIndexOfMatchingRowAndMadeMatching {
    ExpectChange(self, @[@1], @[@3], @[], ^(RLMRealm *realm) {
        // Make the last object match the query
        [[[IntObject allObjectsInRealm:realm] lastObject] setIntCol:3];
        // Move the now-matching object over a previously matching object
        [realm deleteObjects:[IntObject objectsInRealm:realm where:@"intCol = 2"]];
    });
}

- (void)testDeleteNewlyInsertedRowMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array addObject:[IntObject createInRealm:realm withValue:@[@3]]];
        [realm deleteObject:[IntObject allObjectsInRealm:realm].lastObject];
    });
}

- (void)testInsertObjectMatchingQuery {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array addObject:[IntObject createInRealm:realm withValue:@[@3]]];
    });
}

- (void)testInsertObjectNotMatchingQuery {
    ExpectNoChange(self, ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array addObject:[IntObject createInRealm:realm withValue:@[@5]]];
    });
}

- (void)testInsertBothMatchingAndNonMatching {
    ExpectChange(self, @[], @[@4], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array addObject:[IntObject createInRealm:realm withValue:@[@5]]];
        [array addObject:[IntObject createInRealm:realm withValue:@[@3]]];
    });
}

- (void)testInsertMultipleMatching {
    ExpectChange(self, @[], @[@4, @5], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array addObject:[IntObject createInRealm:realm withValue:@[@5]]];
        [array addObject:[IntObject createInRealm:realm withValue:@[@3]]];
        [array addObject:[IntObject createInRealm:realm withValue:@[@5]]];
        [array addObject:[IntObject createInRealm:realm withValue:@[@2]]];
    });
}

- (void)testInsertAtIndex {
    ExpectChange(self, @[], @[@0], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        IntObject *io = [IntObject createInRealm:realm withValue:@[@3]];
        [array insertObject:io atIndex:0];
    });

    ExpectChange(self, @[], @[@0], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        IntObject *io = [IntObject createInRealm:realm withValue:@[@3]];
        [array insertObject:io atIndex:1];
    });

    ExpectChange(self, @[], @[@1], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        IntObject *io = [IntObject createInRealm:realm withValue:@[@3]];
        [array insertObject:io atIndex:2];
    });

    ExpectNoChange(self, ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        IntObject *io = [IntObject createInRealm:realm withValue:@[@5]];
        [array insertObject:io atIndex:2];
    });
}

- (void)testExchangeObjects {
    // adjacent swap: one move, since second is redundant
//    ExpectChange(self, @[@1, @0], @[], @[], ^(RLMRealm *realm) {
//        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
//        [array exchangeObjectAtIndex:1 withObjectAtIndex:2];
//    });

    // non-adjacent: two moves needed
//    ExpectChange(self, @[@0, @2], ^(RLMRealm *realm) {
//        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
//        [array exchangeObjectAtIndex:1 withObjectAtIndex:3];
//    });
}

- (void)testRemoveFromArray {
    ExpectChange(self, @[@0], @[], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array removeObjectAtIndex:1];
    });

    ExpectNoChange(self, ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array removeObjectAtIndex:0];
    });
}

- (void)testClearArray {
    ExpectChange(self, @[@0, @1, @2, @3], @[], @[], ^(RLMRealm *realm) {
        RLMArray *array = [[[ArrayPropertyObject allObjectsInRealm:realm] firstObject] intArray];
        [array removeAllObjects];
    });
}

- (void)testDeleteArray {
    ExpectChange(self, @[@0, @1, @2, @3], @[], @[], ^(RLMRealm *realm) {
                      [realm deleteObjects:[ArrayPropertyObject allObjectsInRealm:realm]];
    });
}
@end