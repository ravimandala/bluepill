//  Copyright 2016 LinkedIn Corporation
//  Licensed under the BSD 2-Clause License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://opensource.org/licenses/BSD-2-Clause
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.

#import "BPPacker.h"
#import "bp/src/BPUtils.h"

@implementation BPPacker

+ (NSMutableArray<BPXCTestFile *> *)packTests:(NSArray<BPXCTestFile *> *)xcTestFiles
                                configuration:(BPConfiguration *)config
                                     andError:(NSError **)errPtr {
    if (!config.testTimeEstimatesJsonFile) {
        [BPUtils printInfo:INFO withString:@"Could not find Test Time Estimates Json file. Using test counts for packing."];
        return [self packTestsByCount:xcTestFiles configuration:config andError:errPtr];
    } else {
        [BPUtils printInfo:INFO withString:@"Found Test Time Estimates Json file. Using the same for packing."];
        return [self packTestsByTime:xcTestFiles configuration:config andError:errPtr];
    }
}

+ (NSMutableArray<BPXCTestFile *> *)packTestsByCount:(NSArray<BPXCTestFile *> *)xcTestFiles
                                       configuration:(BPConfiguration *)config
                                            andError:(NSError **)errPtr {
    [BPUtils printInfo:INFO withString:@"Packing test bundles based on test counts."];
    NSArray *testCasesToRun = config.testCasesToRun;
    NSArray *noSplit = config.noSplit;
    NSUInteger numBundles = [config.numSims integerValue];
    NSArray *sortedXCTestFiles = [xcTestFiles sortedArrayUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
        NSUInteger numTests1 = [(BPXCTestFile *)obj1 numTests];
        NSUInteger numTests2 = [(BPXCTestFile *)obj2 numTests];
        return numTests2 - numTests1;
    }];
    if (sortedXCTestFiles.count == 0) {
        BP_SET_ERROR(errPtr, @"Found no XCTest files.\n"
                     "Perhaps you forgot to 'build-for-testing'? (Cmd + Shift + U) in Xcode.");
        return NULL;
    }
    NSMutableDictionary *testsToRunByTestFilePath = [[NSMutableDictionary alloc] init];
    NSUInteger totalTests = 0;
    for (BPXCTestFile *xctFile in sortedXCTestFiles) {
        if (![noSplit containsObject:[xctFile name]]) {
            NSMutableSet *bundleTestsToRun = [[NSMutableSet alloc] initWithArray:[xctFile allTestCases]];
            if (testCasesToRun) {
                [bundleTestsToRun intersectSet:[[NSSet alloc] initWithArray:testCasesToRun]];
            }
            if (config.testCasesToSkip) {
                [bundleTestsToRun minusSet:[[NSSet alloc] initWithArray:config.testCasesToSkip]];
            }
            if (bundleTestsToRun.count > 0) {
                testsToRunByTestFilePath[xctFile.testBundlePath] = bundleTestsToRun;
                totalTests += bundleTestsToRun.count;
            }
        }
    }
    
    NSUInteger testsPerGroup = MAX(1, totalTests / numBundles);
    NSMutableArray<BPXCTestFile *> *bundles = [[NSMutableArray alloc] init];
    for (BPXCTestFile *xctFile in sortedXCTestFiles) {
        NSArray *bundleTestsToRun = [[testsToRunByTestFilePath[xctFile.testBundlePath] allObjects] sortedArrayUsingSelector:@selector(compare:)];
        NSUInteger bundleTestsToRunCount = [bundleTestsToRun count];
        // if the xctfile is in nosplit list, don't pack it
        if ([noSplit containsObject:[xctFile name]] || (bundleTestsToRunCount <= testsPerGroup && bundleTestsToRunCount > 0)) {
            // just pack the whole xctest file and move on
            // testsToRun doesn't work reliably, switch to use testsToSkip
            // add testsToSkip from Bluepill runner's config
            BPXCTestFile *bundle = [xctFile copy];
            bundle.skipTestIdentifiers = config.testCasesToSkip;

            // Always insert no splited tests to the front.
            [bundles insertObject:bundle atIndex:0];
            continue;
        }
        // We don't want to pack tests from different xctest bundles so we just split
        // the current test bundle in chunks and pack those.
        NSArray *allTestCases = [[xctFile allTestCases] sortedArrayUsingSelector:@selector(compare:)];
        NSUInteger packed = 0;
        while (packed < bundleTestsToRun.count) {
            NSRange range;
            range.location = packed;
            range.length = min(testsPerGroup, bundleTestsToRun.count - packed);
            NSMutableArray *testsToSkip = [NSMutableArray arrayWithArray:allTestCases];
            [testsToSkip removeObjectsInArray:[bundleTestsToRun subarrayWithRange:range]];
            [testsToSkip addObjectsFromArray:xctFile.skipTestIdentifiers];
            [testsToSkip sortUsingSelector:@selector(compare:)];
            BPXCTestFile *bundle = [xctFile copy];
            bundle.skipTestIdentifiers = testsToSkip;
            [bundles addObject:bundle];
            packed += range.length;
        }
        assert(packed == [bundleTestsToRun count]);
    }
    return bundles;
}

+ (NSMutableArray<BPXCTestFile *> *)packTestsByTime:(NSArray<BPXCTestFile *> *)xcTestFiles
                                      configuration:(BPConfiguration *)config
                                           andError:(NSError **)errPtr {
    [BPUtils printInfo:INFO withString:@"Packing based on individual test execution times in file path: %@", config.testTimeEstimatesJsonFile];
    if (xcTestFiles.count == 0) {
        BP_SET_ERROR(errPtr, @"Found no XCTest files.\n"
                     "Perhaps you forgot to 'build-for-testing'? (Cmd + Shift + U) in Xcode.");
        return NULL;
    }

    // load the config file
    NSError *error;
    NSDictionary *testTimes = [self loadConfigFile:config.testTimeEstimatesJsonFile withError:&error];
    if (!testTimes) {
        BP_SET_ERROR(errPtr, @"Could not load configuration from '%@'\n%@", optarg, [error localizedDescription]);
        return NULL;
    }

    NSMutableDictionary *estimatedTimesByTestFilePath = [[NSMutableDictionary alloc] init];
    NSArray *testCasesToRun = config.testCasesToRun;

    double totalTime = 0.0;
    for (BPXCTestFile *xctFile in xcTestFiles) {
        NSMutableSet *bundleTestsToRun = [[NSMutableSet alloc] initWithArray:[xctFile allTestCases]];
        if (testCasesToRun) {
            [bundleTestsToRun intersectSet:[[NSSet alloc] initWithArray:testCasesToRun]];
        }
        if (config.testCasesToSkip && [config.testCasesToSkip count] > 0) {
            [bundleTestsToRun minusSet:[[NSSet alloc] initWithArray:config.testCasesToSkip]];
        }
        if (bundleTestsToRun.count > 0) {
            double testBundleExecutionTime = 0.0;
            for (NSString *test in bundleTestsToRun) {
                if ([testTimes objectForKey:test]) {
                    testBundleExecutionTime += [[testTimes objectForKey:test] doubleValue];
                } else {
                    [BPUtils printInfo:DEBUGINFO withString:@"Estimated test execution time not found for %@. Settling for a default.", test];
                    testBundleExecutionTime += 1.0;
                }
            }
            estimatedTimesByTestFilePath[xctFile.testBundlePath] = [NSNumber numberWithDouble:testBundleExecutionTime];
            totalTime += testBundleExecutionTime;
        }
    }
    assert([estimatedTimesByTestFilePath count] == [xcTestFiles count]);

    NSMutableArray<BPXCTestFile *> *bundles = [[NSMutableArray alloc] init];
    for (BPXCTestFile *xctFile in xcTestFiles) {
        NSNumber *estimatedBundleExecutionTime = estimatedTimesByTestFilePath[xctFile.testBundlePath];
        BPXCTestFile *bundle = [xctFile copy];
        bundle.skipTestIdentifiers = config.testCasesToSkip;
        [bundles addObject:bundle];
        [bundle setEstimatedExecutionTime:estimatedBundleExecutionTime];
    }
    // Sort bundles by execution times
    NSMutableArray *sortedBundles = [NSMutableArray arrayWithArray:[bundles sortedArrayUsingComparator:^NSComparisonResult(id _Nonnull obj1, id _Nonnull obj2) {
        NSNumber *estimatedTime1 = [(BPXCTestFile *)obj1 estimatedExecutionTime];
        NSNumber *estimatedTime2 = [(BPXCTestFile *)obj2 estimatedExecutionTime];
        return [estimatedTime2 doubleValue] - [estimatedTime1 doubleValue];
    }]];
    return sortedBundles;
}

+ (NSDictionary *)loadConfigFile:(NSString *)file withError:(NSError **)errPtr{
    NSData *data = [NSData dataWithContentsOfFile:file
                                          options:NSDataReadingMappedIfSafe
                                            error:errPtr];
    if (!data) return nil;

    return [NSJSONSerialization JSONObjectWithData:data
                                           options:kNilOptions
                                             error:errPtr];
}
@end
