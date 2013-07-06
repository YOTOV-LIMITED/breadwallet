//
//  ZNWallet.m
//  ZincWallet
//
//  Created by Aaron Voisine on 5/12/13.
//  Copyright (c) 2013 zinc. All rights reserved.
//

#import "ZNWallet.h"
#import "ZNTransaction.h"
#import "ZNKey.h"
#import "ZNElectrumSequence.h"
#import "NSData+Hash.h"
#import "NSMutableData+Bitcoin.h"
#import "NSString+Base58.h"
#import "AFNetworking.h"
#import <Security/Security.h>

#define BASE_URL    @"https://blockchain.info"
#define UNSPENT_URL BASE_URL "/unspent?active="
#define ADDRESS_URL BASE_URL "/multiaddr?active="
#define PUSHTX_PATH @"/pushtx"

#define ADDRESSES_PER_QUERY 100 // maximum number of addresses to request in a single query

#define SCRIPT_SUFFIX @"88ac" // OP_EQUALVERIFY OP_CHECKSIG

#define FUNDED_ADDRESSES_KEY       @"FUNDED_ADDRESSES"
#define SPENT_ADDRESSES_KEY        @"SPENT_ADDRESSES"
#define RECEIVE_ADDRESSES_KEY      @"RECEIVE_ADDRESSES"
#define ADDRESS_BALANCES_KEY       @"ADDRESS_BALANCES"
#define ADDRESS_TX_COUNT_KEY       @"ADDRESS_TX_COUNT"
#define UNSPENT_OUTPUTS_KEY        @"UNSPENT_OUTPUTS"
#define TRANSACTIONS_KEY           @"TRANSACTIONS"
#define UNCONFIRMED_KEY            @"UNCONFIRMED"
#define LATEST_BLOCK_HEIGHT_KEY    @"LATEST_BLOCK_HEIGHT"
#define LATEST_BLOCK_TIMESTAMP_KEY @"LATEST_BLOCK_TIMESTAMP"
#define LAST_SYNC_TIME_KEY         @"LAST_SYNC_TIME"
#define SEED_KEY                   @"seed"

#define REFERENCE_BLOCK_HEIGHT 243295
#define REFERENCE_BLOCK_TIME   1372190977.0

#define SEC_ATTR_SERVICE @"cc.zinc.zincwallet"

@interface ZNWallet ()

@property (nonatomic, strong) NSUserDefaults *defs;
@property (nonatomic, strong) NSMutableArray *addresses, *changeAddresses;
@property (nonatomic, strong) NSMutableArray *spentAddresses, *fundedAddresses, *receiveAddresses;
@property (nonatomic, strong) NSMutableDictionary *unspentOutputs;
@property (nonatomic, strong) NSMutableDictionary *spentOutputs;
@property (nonatomic, strong) NSMutableDictionary *addressBalances;
@property (nonatomic, strong) NSMutableDictionary *addressTxCount;
@property (nonatomic, strong) NSMutableDictionary *transactions;
@property (nonatomic, strong) NSMutableDictionary *unconfirmed;
@property (nonatomic, strong) NSMutableSet *outdatedAddresses;
@property (nonatomic, strong) ZNElectrumSequence *sequence;
@property (nonatomic, strong) NSData *mpk;

@end

@implementation ZNWallet

+ (ZNWallet *)sharedInstance
{
    static ZNWallet *singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        singleton = [ZNWallet new];
    });

    return singleton;
}

- (instancetype)init
{
    if (! (self = [super init])) return nil;
    
    self.defs = [NSUserDefaults standardUserDefaults];
    
    //XXX we should be using core data for this...
    self.addresses = [NSMutableArray array];
    self.changeAddresses = [NSMutableArray array];
    self.outdatedAddresses = [NSMutableSet set];
    self.fundedAddresses = [NSMutableArray arrayWithArray:[_defs arrayForKey:FUNDED_ADDRESSES_KEY]];
    self.spentAddresses = [NSMutableArray arrayWithArray:[_defs arrayForKey:SPENT_ADDRESSES_KEY]];
    self.receiveAddresses = [NSMutableArray arrayWithArray:[_defs arrayForKey:RECEIVE_ADDRESSES_KEY]];
    self.transactions = [NSMutableDictionary dictionaryWithDictionary:[_defs dictionaryForKey:TRANSACTIONS_KEY]];
    self.unconfirmed = [NSMutableDictionary dictionaryWithDictionary:[_defs dictionaryForKey:UNCONFIRMED_KEY]];
    self.addressBalances = [NSMutableDictionary dictionaryWithDictionary:[_defs dictionaryForKey:ADDRESS_BALANCES_KEY]];
    self.addressTxCount = [NSMutableDictionary dictionaryWithDictionary:[_defs dictionaryForKey:ADDRESS_TX_COUNT_KEY]];
    self.unspentOutputs = [NSMutableDictionary dictionaryWithDictionary:[_defs dictionaryForKey:UNSPENT_OUTPUTS_KEY]];
    
    self.sequence = [ZNElectrumSequence new];
    
    self.format = [NSNumberFormatter new];
    self.format.lenient = YES;
    self.format.numberStyle = NSNumberFormatterCurrencyStyle;
    self.format.minimumFractionDigits = 0;
    //self.format.currencySymbol = @"m"BTC@" ";
    //self.format.maximumFractionDigits = 5;
    //self.format.maximum = @21000000000.0;
    self.format.currencySymbol = BTC" ";
    self.format.maximumFractionDigits = 8;
    self.format.maximum = @21000000.0;
    
    return self;
}

- (instancetype)initWithSeedPhrase:(NSString *)phrase
{
    if (! (self = [self init])) return nil;
    
    self.seedPhrase = phrase;
    
    return self;
}

- (instancetype)initWithSeed:(NSData *)seed
{
    if (! (self = [self init])) return nil;
    
    self.seed = seed;
    
    return self;
}

- (NSData *)seed
{
    return [self getKeychainObjectForKey:SEED_KEY];
}

- (void)setSeed:(NSData *)seed
{
    if (! [self.seed isEqual:seed]) {        
        [self setKeychainObject:seed forKey:SEED_KEY];
        
        // flush cached addresses and tx outputs
        [_defs removeObjectForKey:FUNDED_ADDRESSES_KEY];
        [_defs removeObjectForKey:SPENT_ADDRESSES_KEY];
        [_defs removeObjectForKey:RECEIVE_ADDRESSES_KEY];
        [_defs removeObjectForKey:ADDRESS_BALANCES_KEY];
        [_defs removeObjectForKey:ADDRESS_TX_COUNT_KEY];
        [_defs removeObjectForKey:UNSPENT_OUTPUTS_KEY];
        [_defs removeObjectForKey:TRANSACTIONS_KEY];
        [_defs removeObjectForKey:UNCONFIRMED_KEY];
        [_defs removeObjectForKey:LAST_SYNC_TIME_KEY];
        [_defs synchronize];
    }
}

- (NSString *)seedPhrase
{
    NSData *seed = [NSData dataWithHex:[[NSString alloc] initWithData:self.seed encoding:NSUTF8StringEncoding]];

    return [self encodePhrase:seed];
}

- (void)setSeedPhrase:(NSString *)seedPhrase
{
    // Electurm uses a hex representation of the decoded seed instead of the seed itself
    self.seed = [[[self decodePhrase:seedPhrase] toHex] dataUsingEncoding:NSUTF8StringEncoding];
}

//# Note about US patent no 5892470: Here each word does not represent a given digit.
//# Instead, the digit represented by a word is variable, it depends on the previous word.
//
//def mn_encode( message ):
//    out = []
//    for i in range(len(message)/8):
//        word = message[8*i:8*i + 8]
//        x = int(word, 16)
//        w1 = (x % n)
//        w2 = ((x/n) + w1) % n
//        w3 = ((x/n/n) + w2) % n
//        out += [ words[w1], words[w2], words[w3] ]
//    return out
//
- (NSString *)encodePhrase:(NSData *)d
{
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:d.length*3/4];
    NSArray *words = [NSArray arrayWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"ElectrumSeedWords"
                      ofType:@"plist"]];
    uint32_t n = words.count;
    
    for (int i = 0; i*sizeof(uint32_t) < d.length; i++) {
        uint32_t x = CFSwapInt32BigToHost(*((uint32_t *)d.bytes + i));
        uint32_t w1 = x % n;
        uint32_t w2 = ((x/n) + w1) % n;
        uint32_t w3 = ((x/n/n) + w2) % n;
        
        [list addObject:words[w1]];
        [list addObject:words[w2]];
        [list addObject:words[w3]];
    }
    
    words = nil;
    
    return [list componentsJoinedByString:@" "];
}

//def mn_decode( wlist ):
//    out = ''
//    for i in range(len(wlist)/3):
//        word1, word2, word3 = wlist[3*i:3*i + 3]
//        w1 =  words.index(word1)
//        w2 = (words.index(word2)) % n
//        w3 = (words.index(word3)) % n
//        x = w1 + n*((w2 - w1) % n) + n*n*((w3 - w2) % n)
//        out += '%08x'%x
//    return out
//
- (NSData *)decodePhrase:(NSString *)phrase
{
    NSArray *list = [phrase componentsSeparatedByString:@" "];
    NSArray *words = [NSArray arrayWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"ElectrumSeedWords"
                      ofType:@"plist"]];
    NSMutableData *d = [NSMutableData dataWithCapacity:list.count*4/3];
    int32_t n = words.count;
    
    if (list.count != 12) {
        NSLog(@"phrase should be 12 words, found %d instead", list.count);
        return nil;
    }
    
    for (NSUInteger i = 0; i < list.count; i += 3) {
        int32_t w1 = [words indexOfObject:list[i]], w2 = [words indexOfObject:list[i + 1]],
        w3 = [words indexOfObject:list[i + 2]];
        
        if (w1 == NSNotFound || w2 == NSNotFound || w3 == NSNotFound) {
            NSLog(@"phrase contained unknown word: %@", list[i + (w1 == NSNotFound ? 0 : w2 == NSNotFound ? 1 : 2)]);
            return nil;
        }
        
        // python's modulo behaves differently than C when dealing with negative numbers
        // the equivalent of python's (n % M) in C is (((n % M) + M) % M)
        int32_t x = w1 + n*((((w2 - w1) % n) + n) % n) + n*n*((((w3 - w2) % n) + n) % n);
        
        x = CFSwapInt32HostToBig(x);
        
        [d appendBytes:&x length:sizeof(x)];
    }
    
    words = nil;
    
    return d;
}

- (void)generateRandomSeed
{
    NSMutableData *seed = [NSMutableData dataWithLength:ELECTRUM_SEED_LENGTH];
    
    SecRandomCopyBytes(kSecRandomDefault, seed.length, seed.mutableBytes);
    
    // Electurm uses a hex representation of the seed value instead of the seed itself
    self.seed = [[seed toHex] dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSData *)mpk
{
    if (! _mpk) {
        _mpk = [self.sequence masterPublicKeyFromSeed:self.seed];
    }
    
    return _mpk;
}

// if any of an unconfimred transaction's inputs show up as unspent, or show up in another transaction, that means the
// tx failed to confirm and needs to be removed from the pending unconfirmed tx list
- (void)cleanUnconfirmed
{
    //XXX should we remove unconfirmed transactions after 2 days?
    
    if (! self.unconfirmed.count) return;

    NSMutableSet *spent = [NSMutableSet set];
    
    [self.transactions enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [obj[@"inputs"] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            NSDictionary *o = obj[@"prev_out"];
            [spent addObject:[NSString stringWithFormat:@"%@:%@", o[@"tx_index"], o[@"n"]]];
        }];
    }];
    
    [self.unconfirmed
    removeObjectsForKeys:[self.unconfirmed keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
        // index of any inputs of the unconfirmed tx that are also in unspentOutputs
        NSUInteger i =
            [obj[@"inputs"] indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
                NSDictionary *o = obj[@"prev_out"];
                NSString *key1 = [o[@"hash"] stringByAppendingString:[o[@"n"] description]];
                NSString *key2 = [NSString stringWithFormat:@"%@:%@", o[@"tx_index"], o[@"n"]];
            
                return (self.unspentOutputs[key1] != nil || [spent containsObject:key2]) ? (*stop = YES) : NO;
            }];
                
        return (i == NSNotFound) ? NO : YES;
    }].allObjects];
    
    [_defs setObject:self.unconfirmed forKey:UNCONFIRMED_KEY];
}

#pragma mark - synchronization

- (void)synchronize
{
    if (_synchronizing) return;
    
    _synchronizing = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncStartedNotification object:self];
    
    [self synchronizeWithGapLimit:ELECTURM_GAP_LIMIT forChange:NO completion:^(NSError *error) {
        if (error) {
            _synchronizing = NO;
            [_defs synchronize];

            [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFailedNotification object:self
             userInfo:@{@"error":error}];
            return;
        }
        
        [self synchronizeWithGapLimit:ELECTURM_GAP_LIMIT_FOR_CHANGE forChange:YES completion:^(NSError *error) {
            if (error) {
                _synchronizing = NO;
                [_defs synchronize];

                [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFailedNotification object:self
                 userInfo:@{@"error":error}];
                return;
            }

            // check funded and spent addresses for new transactions
            [self queryAddresses:[self.fundedAddresses arrayByAddingObjectsFromArray:self.spentAddresses]
            completion:^(NSError *error) {
                if (error) {
                    _synchronizing = NO;
                    [_defs synchronize];

                    [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFailedNotification object:self
                     userInfo:@{@"error":error}];
                    return;
                }

                [self queryUnspentOutputs:self.outdatedAddresses.allObjects completion:^(NSError *error) {
                    if (error) {
                        _synchronizing = NO;
                        [_defs synchronize];

                        [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFailedNotification
                         object:self userInfo:@{@"error":error}];
                        return;
                    }
                    
                    _synchronizing = NO;
                    
                    [self cleanUnconfirmed];
                    
                    [_defs setDouble:[NSDate timeIntervalSinceReferenceDate] forKey:LAST_SYNC_TIME_KEY];
                    [_defs synchronize];

                    [[NSNotificationCenter defaultCenter] postNotificationName:walletSyncFinishedNotification
                     object:self];

                    if (self.outdatedAddresses.count) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:walletBalanceNotification
                         object:self];
                    }
                }];
            }];
        }];
    }];
}

- (void)synchronizeWithGapLimit:(NSUInteger)gapLimit forChange:(BOOL)forChange
completion:(void (^)(NSError *error))completion
{    
    NSUInteger i = 0;
    NSMutableArray *newAddresses = [NSMutableArray array];
    
    while (newAddresses.count < gapLimit) {
        NSString *a = [(ZNKey *)[ZNKey keyWithPublicKey:[self.sequence publicKey:i++ forChange:forChange
                       masterPublicKey:self.mpk]] address];

        if (! a) {
            NSLog(@"error generating keys");
            if (completion) completion(NO);
            return;
        }
        
        if (! forChange && self.addresses.count < i) {
            [self.addresses addObject:a];
        }

        if (forChange && self.changeAddresses.count < i) {
            [self.changeAddresses addObject:a];
        }
        
        if (! [self.spentAddresses containsObject:a] && ! [self.fundedAddresses containsObject:a]) {
            [newAddresses addObject:a];
        }
    }
    
    [self queryAddresses:newAddresses completion:^(NSError *error) {
        [newAddresses removeObjectsAtIndexes:[newAddresses
        indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [self.spentAddresses containsObject:obj] || [self.fundedAddresses containsObject:obj];
        }]];
        
        if (newAddresses.count < gapLimit) {
            [self synchronizeWithGapLimit:gapLimit forChange:forChange completion:completion];
        }
        else if (self.outdatedAddresses.count) {
            [self queryUnspentOutputs:self.outdatedAddresses.allObjects completion:completion];
        }
        else if (completion) completion(error);
    }];    
}

// query blockchain for the given addresses
- (void)queryAddresses:(NSArray *)addresses completion:(void (^)(NSError *error))completion
{
    if (! addresses.count) {
        if (completion) completion(nil);
        return;
    }
    
    if (addresses.count > ADDRESSES_PER_QUERY) {
        [self queryAddresses:[addresses subarrayWithRange:NSMakeRange(0, ADDRESSES_PER_QUERY)]
        completion:^(NSError *error) {
            if (error) {
                if (completion) completion(error);
                return;
            }
            
            [self queryAddresses:[addresses
             subarrayWithRange:NSMakeRange(ADDRESSES_PER_QUERY, addresses.count - ADDRESSES_PER_QUERY)]
             completion:completion];
        }];
        return;
    }

    //XXXX need to remove any self.transactions with 0 confirms that fail to show up here

    NSURL *url = [NSURL URLWithString:[ADDRESS_URL stringByAppendingString:[[addresses componentsJoinedByString:@"|"]
                  stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
    
    [[AFJSONRequestOperation JSONRequestOperationWithRequest:[NSURLRequest requestWithURL:url]
    success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        [JSON[@"addresses"] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            NSString *address = obj[@"address"];
            
            if (! address) return;

            [self.fundedAddresses removeObject:address];
            [self.spentAddresses removeObject:address];
            [self.receiveAddresses removeObject:address];
            
            if ([obj[@"n_tx"] unsignedLongLongValue] > 0) {
                if ([obj[@"n_tx"] unsignedIntegerValue] != [self.addressTxCount[address] unsignedIntegerValue]) {
                    [self.outdatedAddresses addObject:address];
                }
            
                self.addressBalances[address] = obj[@"final_balance"];
                self.addressTxCount[address] = obj[@"n_tx"];

                if ([obj[@"final_balance"] unsignedLongLongValue] > 0) {
                    [self.fundedAddresses addObject:address];
                }
                else [self.spentAddresses addObject:address];
            }
            else [self.receiveAddresses addObject:address];
        }];
        
        [JSON[@"txs"] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            //XXX we shouldn't be saving json without sanitizing it... security risk
            if (obj[@"hash"]) self.transactions[obj[@"hash"]] = obj;
        }];
        
        NSInteger height = [JSON[@"info"][@"latest_block"][@"height"] integerValue];
        NSTimeInterval time = [JSON[@"info"][@"latest_block"][@"time"] doubleValue];
        
        [self.unconfirmed removeObjectsForKeys:self.transactions.allKeys];
        
        [_defs setObject:self.fundedAddresses forKey:FUNDED_ADDRESSES_KEY];
        [_defs setObject:self.spentAddresses forKey:SPENT_ADDRESSES_KEY];
        [_defs setObject:self.receiveAddresses forKey:RECEIVE_ADDRESSES_KEY];
        [_defs setObject:self.addressBalances forKey:ADDRESS_BALANCES_KEY];
        [_defs setObject:self.addressTxCount forKey:ADDRESS_TX_COUNT_KEY];
        [_defs setObject:self.transactions forKey:TRANSACTIONS_KEY];
        [_defs setObject:self.unconfirmed forKey:UNCONFIRMED_KEY];
        if (height) [_defs setInteger:height forKey:LATEST_BLOCK_HEIGHT_KEY];
        if (time > 1.0) [_defs setDouble:time forKey:LATEST_BLOCK_TIMESTAMP_KEY];
        
        if (self.outdatedAddresses.count) {
            [[NSNotificationCenter defaultCenter] postNotificationName:walletBalanceNotification object:self];
        }
        
        if (completion) completion(nil);
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
        NSLog(@"%@", error.localizedDescription);
        
        if (completion) completion(error);
    }] start];
}

// query blockchain for unspent outputs of the given addresses
- (void)queryUnspentOutputs:(NSArray *)addresses completion:(void (^)(NSError *error))completion
{
    if (! addresses.count) {
        if (completion) completion(nil);
        return;
    }
    
    if (addresses.count > ADDRESSES_PER_QUERY) {
        [self queryUnspentOutputs:[addresses subarrayWithRange:NSMakeRange(0, ADDRESSES_PER_QUERY)]
        completion:^(NSError *error) {
            if (error) {
                if (completion) completion(error);
                return;
            }
            
            [self queryUnspentOutputs:[addresses
             subarrayWithRange:NSMakeRange(ADDRESSES_PER_QUERY, addresses.count - ADDRESSES_PER_QUERY)]
             completion:completion];
        }];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:[UNSPENT_URL stringByAppendingString:[[addresses componentsJoinedByString:@"|"]
                  stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
    
    __block AFJSONRequestOperation *requestOp =
        [AFJSONRequestOperation JSONRequestOperationWithRequest:[NSURLRequest requestWithURL:url]
        success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
            if (! [requestOp.responseString.lowercaseString hasPrefix:@"no free outputs"] &&
                JSON[@"unspent_outputs"] == nil) {
                if (completion) {
                    completion([NSError errorWithDomain:@"ZincWallet" code:500 userInfo:@{
                                NSLocalizedDescriptionKey:@"Unexpeted server response from blockchain.info"}]);
                }
                return;
            }

            [self.unspentOutputs
            removeObjectsForKeys:[self.unspentOutputs keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
                NSString *s = obj[@"script"];
                
                if (! [s hasSuffix:SCRIPT_SUFFIX] || s.length < SCRIPT_SUFFIX.length + 40) return YES;
                
                NSString *hash160 = [s substringWithRange:NSMakeRange(s.length - SCRIPT_SUFFIX.length - 40, 40)];
                NSString *address = [[@"00" stringByAppendingString:hash160] hexToBase58check];
                
                return (! address || [addresses containsObject:address]) ? YES : NO;
            }].allObjects];

            [self.outdatedAddresses minusSet:[NSSet setWithArray:addresses]];
            
            [JSON[@"unspent_outputs"] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                NSString *key = [obj[@"tx_hash"] stringByAppendingString:[obj[@"tx_output_n"] description]];

                //XXX we shouldn't be storing json without sanitizing it... security risk
                if (key) self.unspentOutputs[key] = obj;
            }];
            
            [_defs setObject:self.unspentOutputs forKey:UNSPENT_OUTPUTS_KEY];

            if (completion) completion(nil);
        } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
            if ([requestOp.responseString.lowercaseString hasPrefix:@"no free outputs"]) {
                [self.unspentOutputs
                removeObjectsForKeys:[self.unspentOutputs keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
                    NSString *s = obj[@"script"];
                    
                    if (! [s hasSuffix:SCRIPT_SUFFIX] || s.length < SCRIPT_SUFFIX.length + 40) return YES;
                    
                    NSString *hash160 = [s substringWithRange:NSMakeRange(s.length - SCRIPT_SUFFIX.length - 40, 40)];
                    NSString *address = [[@"00" stringByAppendingString:hash160] hexToBase58check];
                    
                    return (! address || [addresses containsObject:address]) ? YES : NO;
                }].allObjects];
            
                [self.outdatedAddresses minusSet:[NSSet setWithArray:addresses]];
                
                [_defs setObject:self.unspentOutputs forKey:UNSPENT_OUTPUTS_KEY];
            
                if (completion) completion(nil);
                return;
            }
        
            NSLog(@"%@", error.localizedDescription);
            if (completion) completion(error);
        }];
    
    [requestOp start];
}

- (NSTimeInterval)timeSinceLastSync
{
    return [NSDate timeIntervalSinceReferenceDate] - [_defs doubleForKey:LAST_SYNC_TIME_KEY];
}

#pragma mark - wallet info

- (uint64_t)balance
{
    // the outputs of unconfirmed transactions will show up in the unspent outputs list even with 0 confirmations
    __block uint64_t balance = 0;
    
    [self.addressBalances enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        balance += [obj unsignedLongLongValue];
    }];
    
    return balance;
}

- (NSString *)receiveAddress
{
    if (! self.receiveAddresses.count || ! self.addresses.count) {
        NSUInteger i = 0;
        NSString *a = nil;
        
        while (! a || [self.spentAddresses containsObject:a] || [self.fundedAddresses containsObject:a]) {
            a = [(ZNKey *)[ZNKey keyWithPublicKey:[self.sequence publicKey:i++ forChange:NO masterPublicKey:self.mpk]]
                 address];
            
            if (! a) return nil;
            
            if (self.addresses.count < i) [self.addresses addObject:a];
        }
        
        if (! [self.receiveAddresses containsObject:a]) [self.receiveAddresses addObject:a];
    }
    
    return [self.addresses firstObjectCommonWithArray:self.receiveAddresses];
}

- (NSString *)changeAddress
{
    if (! self.receiveAddresses.count || ! self.changeAddresses.count) {
        NSUInteger i = 0;
        NSString *a = nil;
        
        while (! a || [self.spentAddresses containsObject:a] || [self.fundedAddresses containsObject:a]) {
            a = [(ZNKey *)[ZNKey keyWithPublicKey:[self.sequence publicKey:i++ forChange:YES masterPublicKey:self.mpk]]
                 address];
            
            if (! a) return nil;
            
            if (self.changeAddresses.count < i) [self.changeAddresses addObject:a];
        }
        
        if (! [self.receiveAddresses containsObject:a]) [self.receiveAddresses addObject:a];
    }
    
    return [self.changeAddresses firstObjectCommonWithArray:self.receiveAddresses];
}

- (NSArray *)recentTransactions
{
    NSMutableArray *r = [NSMutableArray arrayWithCapacity:self.unconfirmed.count + self.transactions.count];
    
    // sort in descending order by timestamp (using block_height doesn't work for unconfirmed, or multiple tx per block)
    [r addObjectsFromArray:[self.unconfirmed.allValues sortedArrayWithOptions:0
    usingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [@([obj2[@"time"] doubleValue]) compare:@([obj1[@"time"] doubleValue])];
    }]];

    [r addObjectsFromArray:[self.transactions.allValues sortedArrayWithOptions:0
    usingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [@([obj2[@"time"] doubleValue]) compare:@([obj1[@"time"] doubleValue])];
    }]];
    
    return r;
}

- (NSUInteger)estimatedCurrentBlockHeight
{
    NSTimeInterval time = [_defs doubleForKey:LATEST_BLOCK_TIMESTAMP_KEY];
    NSUInteger height = [_defs integerForKey:LATEST_BLOCK_HEIGHT_KEY];
    
    if (! height || time < 1.0) { // use hard coded reference block
        height = REFERENCE_BLOCK_HEIGHT;
        time = REFERENCE_BLOCK_TIME;
    }
    
    // average one block every 600 seconds
    return height + ([NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970 - time)/600;
}

- (BOOL)containsAddress:(NSString *)address
{
    return [self.spentAddresses containsObject:address] || [self.fundedAddresses containsObject:address] ||
    [self.receiveAddresses containsObject:address];
}

- (NSString *)stringForAmount:(uint64_t)amount
{
    return [self.format stringFromNumber:@(amount/pow(10, self.format.maximumFractionDigits))];
}

- (uint64_t)amountForString:(NSString *)string
{
    return [[self.format numberFromString:string] doubleValue]*pow(10, self.format.maximumFractionDigits);
}

#pragma mark - ZNTransaction helpers

//XXX as block space becomes harder to come by, we can calculate the median of the lowest fee-per-kb that made it into
// the previous 100 blocks
- (ZNTransaction *)transactionFor:(uint64_t)amount to:(NSString *)address withFee:(BOOL)fee
{
    __block uint64_t balance = 0, standardFee = 0;
    uint64_t minChange = fee ? TX_MIN_OUTPUT_AMOUNT : TX_FREE_MIN_OUTPUT;
    ZNTransaction *tx = [ZNTransaction new];

    [tx addOutputAddress:address amount:amount];

    //XXX we should optimize for free transactions (watch out for performance issues, nothing O(n^2) please)
    // this is a nieve implementation to just get it functional, sorts unspent outputs by oldest first
    NSArray *keys =
        [self.unspentOutputs keysSortedByValueUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            return [obj1[@"tx_index"] compare:obj2[@"tx_index"]];
        }];
    
    [keys enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSDictionary *o = self.unspentOutputs[obj];
        
        // tx_hash is already in little endian
        [tx addInputHash:[NSData dataWithHex:o[@"tx_hash"]] index:[o[@"tx_output_n"] unsignedIntegerValue]
         script:[NSData dataWithHex:o[@"script"]] ];
            
        balance += [o[@"value"] unsignedLongLongValue];

        // assume we will be adding a change output (additional 34 bytes)
        if (fee) standardFee = ((tx.size + 34 + 999)/1000)*TX_FEE_PER_KB;
            
        if (balance == amount + standardFee || balance >= amount + standardFee + minChange) *stop = YES;
    }];
    
    if (balance < amount + standardFee) { // insufficent funds
        NSLog(@"Insufficient funds. Balance:%llu is less than transaction amount:%llu", balance, amount + standardFee);
        return nil;
    }
    
    //XXX we should randomly swap order of outputs so the change address isn't publicy known
    if (balance - (amount + standardFee) >= TX_MIN_OUTPUT_AMOUNT) {
        [tx addOutputAddress:self.changeAddress amount:balance - (amount + standardFee)];
    }
    
    return tx;
}

// returns the estimated time in seconds until the transaction will be processed without a fee
//XXX this is based on the default satoshi client settings, but on the real network it's way off. in testing, a 0.01btc
// transaction with a 90 day time until free was confirmed in under an hour by Eligius pool.
- (NSTimeInterval)timeUntilFree:(ZNTransaction *)transaction
{
    NSMutableArray *amounts = [NSMutableArray array], *heights = [NSMutableArray array];
    NSUInteger currentHeight = [_defs integerForKey:LATEST_BLOCK_HEIGHT_KEY];
    
    if (! currentHeight) return DBL_MAX;
    
    [transaction.inputAddresses enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSString *hash = [transaction.inputHashes[idx] toHex];
        NSString *n = [transaction.inputIndexes[idx] description];
        NSDictionary *o = self.unspentOutputs[[hash stringByAppendingString:n]];

        if (o) {
            [amounts addObject:o[@"value"]];
            [heights addObject:@(currentHeight - [o[@"confirmations"] unsignedIntegerValue])];
        }
        else *stop = YES;
    }];

    NSUInteger height = [transaction blockHeightUntilFreeForAmounts:amounts withBlockHeights:heights];
    
    if (height == NSNotFound) return DBL_MAX;
    
    currentHeight = [self estimatedCurrentBlockHeight];
    
    return height > currentHeight + 1 ? (height - currentHeight)*600 : 0;
}

- (uint64_t)transactionFee:(ZNTransaction *)transaction
{
    __block uint64_t balance = 0, amount = 0;

    [transaction.inputAddresses enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSString *hash = [transaction.inputHashes[idx] toHex];
        NSString *n = [transaction.inputIndexes[idx] description];
        NSDictionary *o = self.unspentOutputs[[hash stringByAppendingString:n]];
        
        if (! o) {
            balance = UINT64_MAX;
            *stop = YES;
        }
        else balance += [o[@"value"] unsignedLongLongValue];
    }];

    if (balance == UINT64_MAX) return UINT64_MAX;
    
    [transaction.outputAmounts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        amount += [obj unsignedLongLongValue];
    }];
    
    return balance - amount;
}

- (BOOL)signTransaction:(ZNTransaction *)transaction
{
    NSMutableSet *keyIndexes = [NSMutableSet set], *changeKeyIndexes = [NSMutableSet set];

    [transaction.inputAddresses enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([self.addresses indexOfObject:obj] == NSNotFound) {
            if ([self.changeAddresses indexOfObject:obj] == NSNotFound) {
                NSLog(@"[%s %s] line %d: missing key", object_getClassName(self), sel_getName(_cmd), __LINE__);
                *stop = YES;
            }
            else [changeKeyIndexes addObject:@([self.changeAddresses indexOfObject:obj])];
        }
        else [keyIndexes addObject:@([self.addresses indexOfObject:obj])];
    }];
    
    NSMutableArray *pkeys = [NSMutableArray arrayWithCapacity:keyIndexes.count + changeKeyIndexes.count];
    NSData *seed = self.seed;
    
    [pkeys addObjectsFromArray:[self.sequence privateKeys:keyIndexes.allObjects forChange:NO fromSeed:seed]];
    [pkeys addObjectsFromArray:[self.sequence privateKeys:changeKeyIndexes.allObjects forChange:YES fromSeed:seed]];
    
    [transaction signWithPrivateKeys:pkeys];
    
    seed = nil;
    pkeys = nil;
    
    return [transaction isSigned];
}

- (void)publishTransaction:(ZNTransaction *)transaction completion:(void (^)(NSError *error))completion
{
    if (! [transaction isSigned]) {
        if (completion) {
            completion([NSError errorWithDomain:@"ZincWallet" code:401
                        userInfo:@{NSLocalizedDescriptionKey:@"bitcoin transaction not signed"}]);
        }
        return;
    }
    
    AFHTTPClient *client = [AFHTTPClient clientWithBaseURL:[NSURL URLWithString:BASE_URL]];
    
    [client postPath:PUSHTX_PATH parameters:@{@"tx":[transaction toHex]}
    success:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSMutableSet *updated = [NSMutableSet set];
        NSMutableDictionary *tx = [NSMutableDictionary dictionary];
        
        tx[@"hash"] = [transaction.hash toHex];
        tx[@"time"] = @([NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970);
        tx[@"inputs"] = [NSMutableArray array];
        tx[@"out"] = [NSMutableArray array];
        
        //XXX successful response is "Transaction submitted", maybe we should check for that 
        NSLog(@"responseObject: %@", responseObject);
        NSLog(@"response:\n%@", operation.responseString);

        [transaction.inputAddresses enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            NSString *hash = [transaction.inputHashes[idx] toHex];
            NSString *n = [transaction.inputIndexes[idx] description];
            NSDictionary *o = self.unspentOutputs[[hash stringByAppendingString:n]];
            
            if (o) {
                self.addressBalances[obj] =
                    @([self.addressBalances[obj] unsignedLongLongValue] - [o[@"value"] unsignedLongLongValue]);

                [updated addObject:obj];
                [self.unspentOutputs removeObjectForKey:[hash stringByAppendingString:n]];
                
                //XXX for now we don't need to store spent outputs because blockchain.info will not list them as unspent
                // while there is an unconfirmed tx that spends them. This may change once we have multiple apis for
                // publishing, and a transaction may not show up on blockchain.info immediately.
                [tx[@"inputs"] addObject:@{@"prev_out":@{@"hash":o[@"tx_hash"], @"tx_index":o[@"tx_index"],
                                           @"n":o[@"tx_output_n"], @"value":o[@"value"], @"addr":obj}}];
            }
        }];
        
        [transaction.outputAddresses enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [tx[@"out"] addObject:@{@"n":@(idx), @"value":transaction.outputAmounts[idx], @"addr":obj}];
        }];
        
        [updated enumerateObjectsUsingBlock:^(id obj, BOOL *stop) {
            self.addressTxCount[obj] = @([self.addressTxCount[obj] unsignedIntegerValue] + 1);
        }];
        
        self.unconfirmed[tx[@"hash"]] = tx;
        
        [_defs setObject:self.unspentOutputs forKey:UNSPENT_OUTPUTS_KEY];
        [_defs setObject:self.addressBalances forKey:ADDRESS_BALANCES_KEY];
        [_defs setObject:self.addressTxCount forKey:ADDRESS_TX_COUNT_KEY];
        [_defs setObject:self.unconfirmed forKey:UNCONFIRMED_KEY];
        [_defs synchronize];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:walletBalanceNotification object:self];
        
        if (completion) completion(nil);
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (completion) completion(error);
    }];

    //XXX also publish transactions directly to coinbase and bitpay servers for faster POS experience
}

#pragma mark - keychain services

- (BOOL)setKeychainObject:(id)obj forKey:(NSString *)key
{
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                            (__bridge id)kSecAttrAccount:key,
                            (__bridge id)kSecReturnData:(__bridge id)kCFBooleanTrue};
    
    NSDictionary *item = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                           (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                           (__bridge id)kSecAttrAccount:key,
                           (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                           (__bridge id)kSecValueData:[NSKeyedArchiver archivedDataWithRootObject:obj]};
    
    SecItemDelete((__bridge CFDictionaryRef)query);
    
    if (SecItemAdd((__bridge CFDictionaryRef)item, NULL) != noErr) {
        NSLog(@"SecItemAdd error");
        return NO;
    }

    return YES;
}

- (id)getKeychainObjectForKey:(NSString *)key
{
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                            (__bridge id)kSecAttrAccount:key,
                            (__bridge id)kSecReturnData:(__bridge id)kCFBooleanTrue};
    CFDataRef result = nil;
    
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result) != noErr) {
        NSLog(@"SecItemCopyMatching error");
        return nil;
    }

    return [NSKeyedUnarchiver unarchiveObjectWithData:(__bridge_transfer NSData*)result];
}

@end