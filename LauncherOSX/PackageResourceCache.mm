//
//  PackageResourceCache.m
//  SDKLauncher-iOS
//
//  Created by Shane Meyer on 3/8/13.
// Modified by Daniel Weck
//  Copyright (c) 2012-2013 The Readium Foundation.
//

#import "PackageResourceCache.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import "RDPackageResource.h"

static NSString *m_basePath = nil;
static NSData *m_key = nil;

@interface PackageResourceCache()

- (NSString *)absolutePathForRelativePath:(NSString *)relativePath;
- (NSData *)sha1:(NSData *)data;

+ (void)trim: (int)maxFilesToKeep;

@end


@implementation PackageResourceCache


//
// Returns the cache path for the given package-relative path.
//
- (NSString *)absolutePathForRelativePath:(NSString *)relativePath {
	NSData *data = [relativePath dataUsingEncoding:NSUTF8StringEncoding];
	NSString *fileName = hexStringFromData([self sha1:data]);
	NSString *ext = relativePath.pathExtension;

	if (ext != nil && ext.length > 0) {
		// Preserve the file extension since the consumer of this resource might care.
		fileName = [fileName stringByAppendingPathExtension:ext];
	}

	return [m_basePath stringByAppendingPathComponent:fileName];
}


//
// Adds the given resource to the cache as well as encrypts it.
//
- (void)addResource:(RDPackageResource *)resource {
	if (resource == nil) {
		NSLog(@"The resource is nil!");
		return;
	}

	NSString *relativePath = resource.relativePath;

	if (relativePath == nil || relativePath.length == 0) {
		NSLog(@"The relative path is missing!");
		return;
	}

    if (m_debugAssetStream)
    {
        NSLog(@"ADD RES: %@", relativePath);

        if (!m_skipCrypt)
        {
            NSLog(@"ENCRYPT");
        }

    }
    
	[PackageResourceCache trim: 3];

	NSString *path = [self absolutePathForRelativePath:relativePath];
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:path error:nil];
	[fm createDirectoryAtPath:m_basePath withIntermediateDirectories:YES attributes:nil
		error:nil];

	NSOutputStream *stream = [NSOutputStream outputStreamToFileAtPath:path append:NO];
	[stream open];

	size_t bufferSize = kSDKLauncherPackageResourceBufferSize + kCCBlockSizeAES128;
	UInt8 buffer[bufferSize];

	while (YES) {
		NSData *chunk = [resource createNextChunkByReading];

		if (chunk == nil) {
			break;
		}

        if (m_skipCrypt)
        {
            [stream write:(const uint8_t*)[chunk bytes] maxLength:[chunk length]];
        }
        else
        {
            size_t numBytesEncrypted = 0;

            CCCryptorStatus cryptStatus = CCCrypt(
                    kCCEncrypt,
                    kCCAlgorithmAES128,
                    kCCOptionPKCS7Padding,
                    m_key.bytes,
                    m_key.length,
                    NULL,
                    chunk.bytes,
                    chunk.length,
                    buffer,
                    bufferSize,
                    &numBytesEncrypted);

            if (cryptStatus == kCCSuccess) {
                [stream write:buffer maxLength:numBytesEncrypted];
            }
            else {
                NSLog(@"Encryption failed!");
            }
        }

        [chunk release];
	}

	[stream close];
}


//
// Returns the content length of the resource at the given relative path.  Since the content
// is encrypted, we need to do some math as well as decrypt the final chunk to discover the
// true content length.
//
- (int)contentLengthAtRelativePath:(NSString *)relativePath {
	int contentLength = 0;

	if (relativePath == nil || relativePath.length == 0) {
		NSLog(@"The relative path is missing!");
		return 0;
	}

	NSString *path = [self absolutePathForRelativePath:relativePath];
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];

	if (attributes != nil) {
		int fileSize = attributes.fileSize;

		if (fileSize == 0) {
			return 0;
		}

        if (m_skipCrypt)
        {
            return fileSize;
        }

        if (m_debugAssetStream)
        {
            NSLog(@"DECRYPT for content length");
        }

		int bufferSize = kSDKLauncherPackageResourceBufferSize + kCCBlockSizeAES128;
		int chunkCount = (fileSize - 1) / bufferSize;
		contentLength = chunkCount * kSDKLauncherPackageResourceBufferSize;

		@autoreleasepool {
			NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
            [handle seekToFileOffset:chunkCount * bufferSize];
			NSData *data = [handle readDataToEndOfFile];

			if (data == nil || data.length == 0) {
				NSLog(@"Could not read the last chunk of data!");
				contentLength = 0;
			}
			else {
                UInt8 buffer[bufferSize];
                size_t numBytesDecrypted = 0;

                CCCryptorStatus cryptStatus = CCCrypt(
                        kCCDecrypt,
                        kCCAlgorithmAES128,
                        kCCOptionPKCS7Padding,
                        m_key.bytes,
                        m_key.length,
                        NULL,
                        data.bytes,
                        data.length,
                        buffer,
                        bufferSize,
                        &numBytesDecrypted);

                if (cryptStatus == kCCSuccess) {
                    contentLength += numBytesDecrypted;
                }
                else {
                    NSLog(@"Decryption failed!");
                    contentLength = 0;
                }
			}
		}
	}

	return contentLength;
}


//- (NSData *)dataAtRelativePath:(NSString *)relativePath {
//	NSRange range = NSMakeRange(0, [self contentLengthAtRelativePath:relativePath]);
//	return [self dataAtRelativePath:relativePath range:range];
//}


//
// Returns a range of data from the resource at the given relative path.  It's slightly
// involved because data is encrypted in chunks.  A typical example might involve decrypting
// the first chunk of data, pulling out some of its bytes, decrypting the middle chunks of
// data, then decrypting the final chunk and pulling out some of its bytes.
//
- (NSData *)dataAtRelativePath:(NSString *)relativePath range:(NSRange)range {
	if (range.length == 0) {
		return [NSData data];
	}

	int contentLength = [self contentLengthAtRelativePath:relativePath];

	if (NSMaxRange(range) > contentLength) {
		NSLog(@"The requested data range is out of bounds!");
		return nil;
	}

	NSMutableData *md = [NSMutableData dataWithCapacity:range.length];
	NSString *path = [self absolutePathForRelativePath:relativePath];
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];

	if (attributes != nil) {
		int chunkIndexFirst = range.location / kSDKLauncherPackageResourceBufferSize;

		int chunkIndexLast = (NSMaxRange(range) - 1) / kSDKLauncherPackageResourceBufferSize;

		int bufferSize = kSDKLauncherPackageResourceBufferSize + kCCBlockSizeAES128;

		int fileSize = attributes.fileSize;

        if (m_skipCrypt)
        {
            NSAssert(fileSize == contentLength, @"mismatch file size / content length");
        }

		@autoreleasepool {

			// Decrypt and append the appropriate amount of data from the first chunk.

			NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];

            int offset = chunkIndexFirst * bufferSize;
			[handle seekToFileOffset: m_skipCrypt ? range.location : offset];

			int bytesToRead = m_skipCrypt ? range.length : MIN(bufferSize, fileSize - offset);
			NSData *dataFirst = [handle readDataOfLength:bytesToRead];

			if (dataFirst == nil || dataFirst.length == 0) {
				NSLog(@"Could not read the first chunk of data!");
				return nil;
			}
            if (m_skipCrypt)
            {
                [md appendData:dataFirst];
            }
            else
            {
                if (m_debugAssetStream)
                {
                    NSLog(@"DECRYPT");
                }

                UInt8 buffer[bufferSize];
                size_t numBytesDecrypted = 0;

                CCCryptorStatus cryptStatus = CCCrypt(
                    kCCDecrypt,
                    kCCAlgorithmAES128,
                    kCCOptionPKCS7Padding,
                    m_key.bytes,
                    m_key.length,
                    NULL,
                    dataFirst.bytes,
                    dataFirst.length,
                    buffer,
                    bufferSize,
                    &numBytesDecrypted);

                if (cryptStatus == kCCSuccess) {
                    dataFirst = [NSData dataWithBytes:buffer length:numBytesDecrypted];
                }
                else {
                    NSLog(@"Decryption failed!");
                    return nil;
                }

                int i0 = range.location % kSDKLauncherPackageResourceBufferSize;
                int i1 = MIN(i0 + range.length, dataFirst.length);
                [md appendData:[dataFirst subdataWithRange:NSMakeRange(i0, i1 - i0)]];

                // Decrypt and append data from the middle chunks.

                for (int i = chunkIndexFirst + 1; i < chunkIndexLast; i++) {
                    NSData *dataMid = [handle readDataOfLength:bufferSize];

                    if (dataMid == nil || dataMid.length == 0) {
                        NSLog(@"Could not read a middle chunk of data!");
                        return nil;
                    }

                    cryptStatus = CCCrypt(
                        kCCDecrypt,
                        kCCAlgorithmAES128,
                        kCCOptionPKCS7Padding,
                        m_key.bytes,
                        m_key.length,
                        NULL,
                        dataMid.bytes,
                        dataMid.length,
                        buffer,
                        bufferSize,
                        &numBytesDecrypted);

                    if (cryptStatus == kCCSuccess) {
                        [md appendBytes:buffer length:numBytesDecrypted];
                    }
                    else {
                        NSLog(@"Decryption failed!");
                        return nil;
                    }
                }

                // Decrypt and append the appropriate amount of data from the last chunk.

                if (chunkIndexFirst == chunkIndexLast) {
                    // There's only one chunk of data.
                }
                else {
                    bytesToRead = MIN(bufferSize, fileSize - chunkIndexLast * bufferSize);
                    NSData *dataLast = [handle readDataOfLength:bytesToRead];

                    if (dataLast == nil || dataLast.length == 0) {
                        NSLog(@"Could not read the last chunk of data!");
                        return nil;
                    }

                    cryptStatus = CCCrypt(
                        kCCDecrypt,
                        kCCAlgorithmAES128,
                        kCCOptionPKCS7Padding,
                        m_key.bytes,
                        m_key.length,
                        NULL,
                        dataLast.bytes,
                        dataLast.length,
                        buffer,
                        bufferSize,
                        &numBytesDecrypted);

                    if (cryptStatus == kCCSuccess) {
                        dataLast = [NSData dataWithBytes:buffer length:
                            MIN(numBytesDecrypted, range.length - md.length)];
                        [md appendData:dataLast];
                    }
                    else {
                        NSLog(@"Decryption failed!");
                        return nil;
                    }
                }
            }
		}
	}

	if (md.length != range.length) {
		NSLog(@"The lengths don't match!");
		return nil;
	}

	return md;
}

+ (void)initialize {
	m_basePath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
		NSUserDomainMask, YES) objectAtIndex:0];
	m_basePath = [m_basePath stringByAppendingPathComponent:@"PackageResources"];
	m_basePath = [m_basePath retain];


    NSString *uuid = GetMACAddressDisplayString();
    //NSString *uuid = [self serialNumber];

    //m_key = [uuid dataUsingEncoding:NSUnicodeStringEncoding allowLossyConversion:NO];

    //NSMutableData* data = [NSMutableData dataWithLength: kCCKeySizeAES128];

    NSUInteger numberOfBytes = [uuid lengthOfBytesUsingEncoding:NSUnicodeStringEncoding];
    void *buffer = malloc(numberOfBytes);
    NSUInteger usedLength = 0;
    NSRange range = NSMakeRange(0, [uuid length]);
    BOOL result = [uuid getBytes:buffer maxLength:numberOfBytes usedLength:&usedLength encoding:NSUnicodeStringEncoding options:0 range:range remainingRange:NULL];
    m_key = [[NSData alloc] initWithBytes:buffer length:kCCKeySizeAES128]; //sizeof(buffer) numberOfBytes
    free(buffer);

    NSAssert(m_key.length == kCCKeySizeAES128, @"m_key invalid size");

    //uuid_t bytes;
    //[[UIDevice currentDevice].identifierForVendor getUUIDBytes:bytes];
	//m_key = [[NSData alloc] initWithBytes:bytes length:sizeof(bytes)];

    if (true || m_skipCrypt)
    {
        //flush cache
        [PackageResourceCache trim: 0];
    }
}


- (NSData *)sha1:(NSData *)data {
	NSData *hash = nil;

	if (data != nil) {
		UInt8 hashBytes[CC_SHA1_DIGEST_LENGTH];

		CC_SHA1_CTX ctx;
		CC_SHA1_Init(&ctx);
		CC_SHA1_Update(&ctx, data.bytes, data.length);
		CC_SHA1_Final(hashBytes, &ctx);

		hash = [NSData dataWithBytes:hashBytes length:CC_SHA1_DIGEST_LENGTH];
	}

	return hash;
}


+ (PackageResourceCache *)shared {
	static PackageResourceCache *shared = nil;

	if (shared == nil) {
		shared = [[PackageResourceCache alloc] init];
	}

	return shared;
}


//
// Removes old files from the cache, preserving the ones most recently added.
//
+ (void)trim:(int)maxFilesToKeep {
	NSMutableArray *pairs = [NSMutableArray array];
	NSFileManager *fm = [NSFileManager defaultManager];

	for (NSString *fileName in [fm contentsOfDirectoryAtPath:m_basePath error:nil]) {
		NSString *path = [m_basePath stringByAppendingPathComponent:fileName];
		NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];

		if (attributes != nil) {
			NSDate *date = attributes.fileCreationDate;

			if (date != nil) {
				[pairs addObject:@[ path, date ]];
			}
		}
	}

	[pairs sortUsingComparator:^NSComparisonResult(NSArray *pair0, NSArray *pair1) {
		NSDate *date0 = pair0.lastObject;
		NSDate *date1 = pair1.lastObject;
		return [date0 compare:date1];
	}];

	// It's unlikely that there will be very many media resources needed at the same time by
	// a package.  For that reason, and since media resources tend to be large (taking up space
	// on the device), we can keep the max files pretty small.

	while (pairs.count > maxFilesToKeep) {
		NSArray *pair = [pairs objectAtIndex:0];
		NSString *path = [pair objectAtIndex:0];
		[fm removeItemAtPath:path error:nil];
		[pairs removeObjectAtIndex:0];
	}
}


@end
