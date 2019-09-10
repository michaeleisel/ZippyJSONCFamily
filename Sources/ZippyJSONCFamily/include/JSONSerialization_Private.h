//Copyright (c) 2018 Michael Eisel. All rights reserved.

//#import "rapidjson/document.h"

#import <Foundation/Foundation.h>
#import "JSONSerialization.h"

CF_EXTERN_C_BEGIN

typedef CF_ENUM(size_t, JNTDecodingErrorType) {
    JNTDecodingErrorTypeNone,
    JNTDecodingErrorTypeKeyDoesNotExist,
    JNTDecodingErrorTypeValueDoesNotExist,
    JNTDecodingErrorTypeNumberDoesNotFit,
    JNTDecodingErrorTypeWrongType,
    JNTDecodingErrorTypeJSONParsingFailed,
    JNTDecodingErrorTypeWentPastEndOfArray
};


#ifdef __cplusplus
typedef simdjson::ParsedJson::iterator* IteratorPointer;
#else
struct IteratorDummy {
};
typedef struct IteratorDummy *IteratorPointer;
#endif

typedef struct {
    const char *description;
    JNTDecodingErrorType type;
    IteratorPointer value;
    const char *key;
} JNTDecodingError;

BOOL JNTDocumentContains(IteratorPointer iterator, const char *key);
BOOL JNTDocumentDecodeNil(IteratorPointer documentPtr);
void JNTReleaseDocument();
IteratorPointer JNTDocumentFromJSON(const void *data, NSInteger length, bool convertCase, const char * *retryReason, bool fullPrecisionFloatParsing);
void JNTDocumentNextArrayElement(IteratorPointer iterator, bool *isAtEnd);
void JNTUpdateFloatingPointStrings(const char *posInfString, const char *negInfString, const char *nanString);
bool JNTAcquireThreadLock();
void JNTReleaseThreadLock();
bool JNTDocumentValueIsArray(IteratorPointer iterator);
IteratorPointer JNTDocumentEnterStructureAndReturnCopy(IteratorPointer iterator);
bool JNTDocumentValueIsDictionary(IteratorPointer iterator);
NSArray <NSString *> *JNTDocumentAllKeys(IteratorPointer iterator);
NSArray <id> *JNTDocumentCodingPath(IteratorPointer iterator);
void JNTDocumentForAllKeyValuePairs(IteratorPointer iterator, void (^callback)(const char *key, IteratorPointer iterator));
void JNTConvertSnakeToCamel(IteratorPointer iterator);
IteratorPointer JNTEmptyDictionaryIterator();

IteratorPointer JNTDocumentFetchValue(IteratorPointer value, const char *key);

double JNTDocumentDecode__Double(IteratorPointer value);
float JNTDocumentDecode__Float(IteratorPointer value);
NSDate *JNTDocumentDecode__Date(IteratorPointer value);
void *JNTDocumentDecode__Data(IteratorPointer value, int32_t *outLength);
void JNTRunTests();
NSDecimalNumber *JNTDocumentDecode__Decimal(IteratorPointer value);

NSInteger JNTDocumentGetArrayCount(IteratorPointer value);

@interface JNTCodingPath : NSObject

- (instancetype)initWithStringValue:(NSString *)stringValue intValue:(NSInteger)intValue;

@property (strong, nonatomic) NSString *stringValue;
@property (nonatomic) NSInteger intValue;

@end

JNTDecodingError *JNTError();

#define DECODE_KEYED_HEADER(A, B, C, D) DECODE_KEYED_HEADER_NAMED(A, B, C, D, A)

#define DECODE_KEYED_HEADER_NAMED(A, B, C, D, E) \
A JNTDocumentDecodeKeyed__##E(IteratorPointer value, const char *key);

#define DECODE_HEADER(A, B, C, D) DECODE_HEADER_NAMED(A, B, C, D, A)

#define DECODE_HEADER_NAMED(A, B, C, D, E) \
A JNTDocumentDecode__##E(IteratorPointer value);

#define ENUMERATE(F) \
F##_NAMED(bool, bool, Bool, Bool, Bool); \
F(int8_t, int64_t, Int64, Int64); \
F(uint8_t, int64_t, Int64, Int64); \
F(int16_t, int64_t, Int64, Int64); \
F(uint16_t, int64_t, Int64, Int64); \
F(int32_t, int64_t, Int64, Int64); \
F(uint32_t, int64_t, Int64, Int64); \
F(int64_t, int64_t, Int64, Int64); \
F(uint64_t, uint64_t, UInt64, UInt64); \
F##_NAMED(const char *, const char *, String, String, String); \
F##_NAMED(NSInteger, int64_t, Int64, Int64, Int); \
F##_NAMED(NSUInteger, uint64_t, UInt64, UInt64, UInt);

ENUMERATE(DECODE_HEADER);
// ENUMERATE(DECODE_KEYED_HEADER);
//BOOL JNTDocumentContains(Document document, const char *key);
//BOOL JNTDocumentContains(void * document, const char *key);

CF_EXTERN_C_END
